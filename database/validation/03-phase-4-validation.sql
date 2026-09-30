SET NOCOUNT ON;

PRINT 'Northstar Reservations - Phase 4 validation';

IF OBJECT_ID(N'reservation.ReservationChange', N'U') IS NULL
    THROW 55001, 'reservation.ReservationChange is missing.', 1;

IF OBJECT_ID(N'reservation.ApplyReservationModificationBatch', N'P') IS NULL
    THROW 55002, 'reservation.ApplyReservationModificationBatch is missing.', 1;

SELECT
    COUNT_BIG(*) AS RecordedChangeCount,
    COUNT(DISTINCT ChangeBatchId) AS ChangeBatchCount,
    COUNT(DISTINCT ReservationId) AS ModifiedReservationCount,
    MIN(ChangedAt) AS FirstChangeAt,
    MAX(ChangedAt) AS LatestChangeAt
FROM reservation.ReservationChange;

DECLARE @IntegrityFailureCount bigint;

SELECT @IntegrityFailureCount = COUNT_BIG(*)
FROM reservation.ReservationChange AS changeRecord
LEFT JOIN reservation.Reservation AS res
    ON res.ReservationId = changeRecord.ReservationId
LEFT JOIN property.Property AS propertyRecord
    ON propertyRecord.PropertyId = changeRecord.PropertyId
WHERE res.ReservationId IS NULL
    OR propertyRecord.PropertyId IS NULL
    OR res.PropertyId <> changeRecord.PropertyId;

SELECT @IntegrityFailureCount AS IntegrityFailureCount;

IF @IntegrityFailureCount > 0
    THROW 55003, 'Reservation modification audit integrity failed.', 1;

CREATE TABLE #BlockingSamples
(
    SampleNumber int NOT NULL PRIMARY KEY,
    SampleTime datetime2(3) NOT NULL,
    ActiveRequestCount int NOT NULL,
    BlockedRequestCount int NOT NULL,
    LongestRequestSeconds int NOT NULL
);

DECLARE @SampleNumber int = 1;

WHILE @SampleNumber <= 4
BEGIN
    INSERT #BlockingSamples
    (
        SampleNumber,
        SampleTime,
        ActiveRequestCount,
        BlockedRequestCount,
        LongestRequestSeconds
    )
    SELECT
        @SampleNumber,
        SYSUTCDATETIME(),
        COUNT(*),
        COALESCE(SUM(CASE WHEN request.blocking_session_id > 0 THEN 1 ELSE 0 END), 0),
        COALESCE(MAX(DATEDIFF(second, request.start_time, SYSUTCDATETIME())), 0)
    FROM sys.dm_exec_requests AS request
    JOIN sys.dm_exec_sessions AS sessionInfo
        ON sessionInfo.session_id = request.session_id
    WHERE request.database_id = DB_ID()
        AND sessionInfo.program_name = 'Northstar Reservation Management';

    IF @SampleNumber < 4
        WAITFOR DELAY '00:00:15';

    SET @SampleNumber += 1;
END;

SELECT
    SampleNumber,
    SampleTime,
    ActiveRequestCount,
    BlockedRequestCount,
    LongestRequestSeconds
FROM #BlockingSamples
ORDER BY SampleNumber;

IF (SELECT COUNT(*) FROM #BlockingSamples WHERE BlockedRequestCount > 0) < 3
    THROW 55004, 'Fewer than three blocking samples contained blocked requests.', 1;

IF (SELECT BlockedRequestCount FROM #BlockingSamples WHERE SampleNumber = 4) = 0
    THROW 55005, 'The latest blocking sample did not contain a blocked request.', 1;

PRINT 'Phase 4 validation completed successfully.';
