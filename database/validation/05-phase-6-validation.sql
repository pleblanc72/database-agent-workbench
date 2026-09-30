SET NOCOUNT ON;

PRINT 'Northstar Reservations - Phase 6 validation';

IF OBJECT_ID(N'reporting.ExportGuestStayHistory', N'P') IS NULL
    THROW 59001, 'reporting.ExportGuestStayHistory is missing.', 1;
IF OBJECT_ID(N'reporting.GuestStayHistoryArchive', N'U') IS NULL
    THROW 59002, 'reporting.GuestStayHistoryArchive is missing.', 1;

DECLARE @ArchiveRows bigint =
(
    SELECT SUM(partitionStats.row_count)
    FROM sys.dm_db_partition_stats AS partitionStats
    WHERE partitionStats.object_id = OBJECT_ID(N'reporting.GuestStayHistoryArchive')
        AND partitionStats.index_id IN (0, 1)
);

IF COALESCE(@ArchiveRows, 0) < 1800000
    THROW 59003, 'The calibrated profile requires at least 1,800,000 historical archive rows.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_exec_requests AS request
    JOIN sys.dm_exec_sessions AS sessionInfo
        ON sessionInfo.session_id = request.session_id
    WHERE request.database_id = DB_ID()
        AND sessionInfo.program_name = 'Northstar Reporting Export'
)
    THROW 59004, 'Start Guest Stay History Export before running Phase 6 validation.', 1;

SELECT
    sessionInfo.program_name AS ApplicationName,
    COUNT(*) AS ActiveSessionCount,
    MAX(DATEDIFF(second, request.start_time, SYSUTCDATETIME())) AS LongestRequestSeconds
FROM sys.dm_exec_requests AS request
JOIN sys.dm_exec_sessions AS sessionInfo
    ON sessionInfo.session_id = request.session_id
WHERE request.database_id = DB_ID()
    AND sessionInfo.program_name = 'Northstar Reporting Export'
GROUP BY sessionInfo.program_name;

CREATE TABLE #StorageSamples
(
    SampleNumber int NOT NULL PRIMARY KEY,
    SampleTime datetime2(3) NOT NULL,
    ReadIops decimal(12,2) NOT NULL,
    AverageReadLatencyMilliseconds decimal(12,2) NULL,
    PageIoLatchWaitMillisecondsPerSecond decimal(12,2) NOT NULL
);

DECLARE @SampleNumber int = 1;
DECLARE @SampleSeconds int = 15;
DECLARE @PreviousReads bigint;
DECLARE @PreviousReadStallMilliseconds bigint;
DECLARE @PreviousPageIoLatchWaitMilliseconds bigint;

SELECT
    @PreviousReads = SUM(fileStats.num_of_reads),
    @PreviousReadStallMilliseconds = SUM(fileStats.io_stall_read_ms)
FROM sys.dm_io_virtual_file_stats(DB_ID(), NULL) AS fileStats
JOIN sys.database_files AS databaseFile
    ON databaseFile.file_id = fileStats.file_id
WHERE databaseFile.type_desc = 'ROWS';

SELECT
    @PreviousPageIoLatchWaitMilliseconds = COALESCE(SUM(waitStats.wait_time_ms), 0)
FROM sys.dm_db_wait_stats AS waitStats
WHERE waitStats.wait_type LIKE 'PAGEIOLATCH[_]%';

WHILE @SampleNumber <= 8
BEGIN
    WAITFOR DELAY '00:00:15';

    DECLARE @CurrentReads bigint;
    DECLARE @CurrentReadStallMilliseconds bigint;
    DECLARE @CurrentPageIoLatchWaitMilliseconds bigint;
    DECLARE @ReadDelta bigint;

    SELECT
        @CurrentReads = SUM(fileStats.num_of_reads),
        @CurrentReadStallMilliseconds = SUM(fileStats.io_stall_read_ms)
    FROM sys.dm_io_virtual_file_stats(DB_ID(), NULL) AS fileStats
    JOIN sys.database_files AS databaseFile
        ON databaseFile.file_id = fileStats.file_id
    WHERE databaseFile.type_desc = 'ROWS';

    SELECT
        @CurrentPageIoLatchWaitMilliseconds = COALESCE(SUM(waitStats.wait_time_ms), 0)
    FROM sys.dm_db_wait_stats AS waitStats
    WHERE waitStats.wait_type LIKE 'PAGEIOLATCH[_]%';

    SET @ReadDelta = @CurrentReads - @PreviousReads;

    INSERT #StorageSamples
    (
        SampleNumber,
        SampleTime,
        ReadIops,
        AverageReadLatencyMilliseconds,
        PageIoLatchWaitMillisecondsPerSecond
    )
    VALUES
    (
        @SampleNumber,
        SYSUTCDATETIME(),
        CONVERT(decimal(12,2), @ReadDelta * 1.0 / @SampleSeconds),
        CONVERT(decimal(12,2),
            (@CurrentReadStallMilliseconds - @PreviousReadStallMilliseconds) * 1.0
            / NULLIF(@ReadDelta, 0)),
        CONVERT(decimal(12,2),
            (@CurrentPageIoLatchWaitMilliseconds - @PreviousPageIoLatchWaitMilliseconds) * 1.0
            / @SampleSeconds)
    );

    SET @PreviousReads = @CurrentReads;
    SET @PreviousReadStallMilliseconds = @CurrentReadStallMilliseconds;
    SET @PreviousPageIoLatchWaitMilliseconds = @CurrentPageIoLatchWaitMilliseconds;
    SET @SampleNumber += 1;
END;

SELECT
    SampleNumber,
    SampleTime,
    ReadIops,
    AverageReadLatencyMilliseconds,
    PageIoLatchWaitMillisecondsPerSecond
FROM #StorageSamples
ORDER BY SampleNumber;

IF (SELECT COUNT(*) FROM #StorageSamples WHERE ReadIops >= 5) < 3
    THROW 59005, 'Phase 6 requires at least three samples with read IOPS at or above 5.', 1;

IF
(
    SELECT COUNT(*)
    FROM #StorageSamples
    WHERE AverageReadLatencyMilliseconds >= 50
) < 3
AND NOT
(
    (
        SELECT COUNT(*)
        FROM #StorageSamples
        WHERE AverageReadLatencyMilliseconds >= 20
    ) >= 3
    AND
    (
        SELECT COUNT(*)
        FROM #StorageSamples
        WHERE PageIoLatchWaitMillisecondsPerSecond >= 100
    ) >= 3
)
    THROW 59006, 'Phase 6 did not sustain the required read-latency or PAGEIOLATCH threshold.', 1;

PRINT 'Phase 6 validation completed successfully.';
