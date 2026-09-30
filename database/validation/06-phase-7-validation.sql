SET NOCOUNT ON;

PRINT 'Northstar Reservations - Phase 7 validation';

IF OBJECT_ID(N'reporting.ReconcilePortfolioRevenue', N'P') IS NULL
    THROW 62001, 'reporting.ReconcilePortfolioRevenue is missing.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.dm_exec_requests AS request
    JOIN sys.dm_exec_sessions AS sessionInfo
        ON sessionInfo.session_id = request.session_id
    WHERE request.database_id = DB_ID()
        AND sessionInfo.program_name = 'Northstar Revenue Reconciliation'
        AND request.status IN ('running', 'runnable', 'suspended')
)
    THROW 62002, 'Start Portfolio Revenue Reconciliation before running Phase 7 validation.', 1;

CREATE TABLE #Observations
(
    SampleNumber int NOT NULL PRIMARY KEY,
    SampleTime datetime2(3) NOT NULL,
    ActiveRequestCount int NOT NULL,
    LongestRequestSeconds int NOT NULL,
    WaitMillisecondsPerSecond decimal(12,2) NULL
);

DECLARE @SampleNumber int = 0;
DECLARE @PreviousWaitMilliseconds bigint;

SELECT
    @PreviousWaitMilliseconds = COALESCE(SUM(waitStats.wait_time_ms), 0)
FROM sys.dm_db_wait_stats AS waitStats
WHERE waitStats.wait_type NOT IN
(
    'BROKER_EVENTHANDLER',
    'BROKER_RECEIVE_WAITFOR',
    'BROKER_TASK_STOP',
    'CHECKPOINT_QUEUE',
    'DIRTY_PAGE_POLL',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'LAZYWRITER_SLEEP',
    'LOGMGR_QUEUE',
    'REQUEST_FOR_DEADLOCK_SEARCH',
    'SLEEP_TASK',
    'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    'XE_DISPATCHER_WAIT',
    'XE_TIMER_EVENT'
);

WHILE @SampleNumber <= 8
BEGIN
    IF @SampleNumber > 0
        WAITFOR DELAY '00:01:00';

    DECLARE @CurrentWaitMilliseconds bigint;
    DECLARE @ActiveRequestCount int;
    DECLARE @LongestRequestSeconds int;

    SELECT
        @ActiveRequestCount = COUNT(*),
        @LongestRequestSeconds = COALESCE(
            MAX(DATEDIFF(second, request.start_time, SYSUTCDATETIME())),
            0)
    FROM sys.dm_exec_requests AS request
    JOIN sys.dm_exec_sessions AS sessionInfo
        ON sessionInfo.session_id = request.session_id
    WHERE request.database_id = DB_ID()
        AND sessionInfo.program_name = 'Northstar Revenue Reconciliation'
        AND request.status IN ('running', 'runnable', 'suspended');

    SELECT
        @CurrentWaitMilliseconds = COALESCE(SUM(waitStats.wait_time_ms), 0)
    FROM sys.dm_db_wait_stats AS waitStats
    WHERE waitStats.wait_type NOT IN
    (
        'BROKER_EVENTHANDLER',
        'BROKER_RECEIVE_WAITFOR',
        'BROKER_TASK_STOP',
        'CHECKPOINT_QUEUE',
        'DIRTY_PAGE_POLL',
        'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        'LAZYWRITER_SLEEP',
        'LOGMGR_QUEUE',
        'REQUEST_FOR_DEADLOCK_SEARCH',
        'SLEEP_TASK',
        'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
        'XE_DISPATCHER_WAIT',
        'XE_TIMER_EVENT'
    );

    INSERT #Observations
    (
        SampleNumber,
        SampleTime,
        ActiveRequestCount,
        LongestRequestSeconds,
        WaitMillisecondsPerSecond
    )
    VALUES
    (
        @SampleNumber,
        SYSUTCDATETIME(),
        @ActiveRequestCount,
        @LongestRequestSeconds,
        CASE WHEN @SampleNumber = 0 THEN NULL
            ELSE CONVERT(decimal(12,2),
                (@CurrentWaitMilliseconds - @PreviousWaitMilliseconds) / 60.0)
        END
    );

    SET @PreviousWaitMilliseconds = @CurrentWaitMilliseconds;
    SET @SampleNumber += 1;
END;

SELECT
    SampleNumber,
    SampleTime,
    ActiveRequestCount,
    LongestRequestSeconds,
    WaitMillisecondsPerSecond
FROM #Observations
ORDER BY SampleNumber;

IF DATEDIFF(
    second,
    (SELECT MIN(SampleTime) FROM #Observations),
    (SELECT MAX(SampleTime) FROM #Observations)) < 300
    THROW 62003, 'The Phase 7 observation window must span at least five minutes.', 1;

IF
(
    SELECT COUNT(DISTINCT DATEDIFF(minute, CONVERT(datetime2, '20000101'), SampleTime))
    FROM #Observations
    WHERE ActiveRequestCount > 0
) < 3
    THROW 62004, 'A reconciliation request was not observed in at least three one-minute bins.', 1;

IF DATEDIFF
(
    second,
    (SELECT MAX(SampleTime) FROM #Observations WHERE ActiveRequestCount > 0),
    (SELECT MAX(SampleTime) FROM #Observations)
) > 120
    THROW 62005, 'No reconciliation request was observed within two minutes of the window end.', 1;

IF
(
    SELECT COUNT(*)
    FROM #Observations
    WHERE WaitMillisecondsPerSecond >= 500
) < 3
    THROW 62006, 'Fewer than three one-minute samples reached 500 wait-ms/sec.', 1;

PRINT 'Phase 7 validation completed successfully.';
