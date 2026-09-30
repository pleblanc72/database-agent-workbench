SET NOCOUNT ON;

PRINT 'Northstar Reservations - Phase 5 validation';

IF OBJECT_ID(N'reservation.SearchFlexibleStayOptions', N'P') IS NULL
    THROW 57001, 'reservation.SearchFlexibleStayOptions is missing.', 1;

SELECT TOP (12)
    end_time AS SampleTime,
    avg_cpu_percent AS AverageCpuPercent,
    avg_data_io_percent AS AverageDataIoPercent,
    avg_log_write_percent AS AverageLogWritePercent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;

DECLARE @SamplesAtOrAboveTarget int;

SELECT
    @SamplesAtOrAboveTarget = COUNT(*)
FROM
(
    SELECT TOP (12) avg_cpu_percent
    FROM sys.dm_db_resource_stats
    ORDER BY end_time DESC
) AS recent
WHERE recent.avg_cpu_percent >= 80;

SELECT @SamplesAtOrAboveTarget AS SamplesAtOrAboveTarget;

IF @SamplesAtOrAboveTarget < 3
    THROW 57002, 'Fewer than three recent CPU samples met the 80 percent target.', 1;

SELECT
    sessionInfo.program_name AS ApplicationName,
    COUNT(*) AS ActiveSessionCount,
    MAX(DATEDIFF(second, request.start_time, SYSUTCDATETIME())) AS LongestRequestSeconds
FROM sys.dm_exec_requests AS request
JOIN sys.dm_exec_sessions AS sessionInfo
    ON sessionInfo.session_id = request.session_id
WHERE request.database_id = DB_ID()
    AND sessionInfo.program_name = 'Northstar Search Services'
GROUP BY sessionInfo.program_name;

PRINT 'Phase 5 validation completed successfully.';
