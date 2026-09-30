SET NOCOUNT ON;

PRINT 'Northstar Reservations - Phase 2 validation';

DECLARE @ExpectedProcedures TABLE
(
    SchemaName sysname NOT NULL,
    ProcedureName sysname NOT NULL,
    PRIMARY KEY (SchemaName, ProcedureName)
);

INSERT @ExpectedProcedures (SchemaName, ProcedureName)
VALUES
    ('operations', 'GetWorkloadBounds'),
    ('reservation', 'SearchAvailability'),
    ('reservation', 'GetReservation'),
    ('reservation', 'CreateReservation'),
    ('reservation', 'UpdateGuestCounts'),
    ('reservation', 'CancelReservation'),
    ('billing', 'ProcessNextPendingPayment'),
    ('operations', 'CheckInNextArrival'),
    ('operations', 'UpdateRoomStatus'),
    ('reporting', 'GetPropertyPerformance');

SELECT
    expected.SchemaName,
    expected.ProcedureName,
    IIF(procedureObject.object_id IS NULL, 'Missing', 'Present') AS DeploymentStatus
FROM @ExpectedProcedures AS expected
LEFT JOIN sys.procedures AS procedureObject
    ON procedureObject.schema_id = SCHEMA_ID(expected.SchemaName)
    AND procedureObject.name = expected.ProcedureName
ORDER BY expected.SchemaName, expected.ProcedureName;

IF EXISTS
(
    SELECT 1
    FROM @ExpectedProcedures AS expected
    LEFT JOIN sys.procedures AS procedureObject
        ON procedureObject.schema_id = SCHEMA_ID(expected.SchemaName)
        AND procedureObject.name = expected.ProcedureName
    WHERE procedureObject.object_id IS NULL
)
    THROW 53001, 'One or more Phase 2 stored procedures are missing.', 1;

SELECT
    COUNT_BIG(*) AS WorkloadReservationCount,
    MIN(CreatedAt) AS FirstWorkloadReservation,
    MAX(CreatedAt) AS LatestWorkloadReservation
FROM reservation.Reservation
WHERE ReservationNumber LIKE 'NW%';

DECLARE @Failures TABLE
(
    CheckName nvarchar(200) NOT NULL,
    FailureCount bigint NOT NULL
);

INSERT @Failures (CheckName, FailureCount)
SELECT 'Workload reservations without a room', COUNT_BIG(*)
FROM reservation.Reservation AS res
LEFT JOIN reservation.ReservationRoom AS reservationRoom
    ON reservationRoom.ReservationId = res.ReservationId
WHERE res.ReservationNumber LIKE 'NW%'
    AND reservationRoom.ReservationRoomId IS NULL
UNION ALL
SELECT 'Workload reservations without a payment', COUNT_BIG(*)
FROM reservation.Reservation AS res
LEFT JOIN billing.Payment AS pay
    ON pay.ReservationId = res.ReservationId
WHERE res.ReservationNumber LIKE 'NW%'
    AND pay.PaymentId IS NULL
UNION ALL
SELECT 'Active workload inventory without its reservation room', COUNT_BIG(*)
FROM reservation.Reservation AS res
JOIN reservation.ReservationRoom AS reservationRoom
    ON reservationRoom.ReservationId = res.ReservationId
LEFT JOIN reservation.RoomInventory AS inventory
    ON inventory.ReservationRoomId = reservationRoom.ReservationRoomId
WHERE res.ReservationNumber LIKE 'NW%'
    AND res.ReservationStatus IN ('Pending', 'Confirmed', 'CheckedIn')
GROUP BY reservationRoom.ReservationRoomId, reservationRoom.ArrivalDate, reservationRoom.DepartureDate
HAVING COUNT(inventory.RoomInventoryId) <> DATEDIFF(day, reservationRoom.ArrivalDate, reservationRoom.DepartureDate);

SELECT CheckName, FailureCount
FROM @Failures
ORDER BY CheckName;

IF EXISTS (SELECT 1 FROM @Failures WHERE FailureCount > 0)
    THROW 53002, 'One or more Phase 2 workload integrity checks failed.', 1;

SELECT
    program_name AS ApplicationName,
    status AS SessionStatus,
    COUNT(*) AS SessionCount
FROM sys.dm_exec_sessions
WHERE program_name IN
(
    'Northstar Reservations API',
    'Northstar Property Operations',
    'Northstar Reporting Service'
)
GROUP BY program_name, status
ORDER BY program_name, status;

SELECT
    COUNT(*) AS ActiveRequestCount,
    COALESCE(SUM(CASE WHEN request.blocking_session_id > 0 THEN 1 ELSE 0 END), 0) AS BlockedRequestCount,
    COALESCE(MAX(DATEDIFF(second, request.start_time, SYSUTCDATETIME())), 0) AS LongestRequestSeconds
FROM sys.dm_exec_requests AS request
JOIN sys.dm_exec_sessions AS sessionInfo
    ON sessionInfo.session_id = request.session_id
WHERE request.database_id = DB_ID()
    AND request.session_id <> @@SPID
    AND sessionInfo.is_user_process = 1;

PRINT 'Phase 2 validation completed successfully.';
