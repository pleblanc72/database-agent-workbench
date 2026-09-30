SET NOCOUNT ON;

PRINT 'Northstar Reservations - Phase 1 validation';

SELECT
    s.name AS SchemaName,
    COUNT(t.object_id) AS TableCount
FROM sys.schemas AS s
LEFT JOIN sys.tables AS t
    ON t.schema_id = s.schema_id
WHERE s.name IN ('guest', 'property', 'reservation', 'billing', 'operations', 'reporting')
GROUP BY s.name
ORDER BY s.name;

SELECT 'guest.Guest' AS TableName, COUNT_BIG(*) AS [RowCount] FROM guest.Guest
UNION ALL SELECT 'property.Property', COUNT_BIG(*) FROM property.Property
UNION ALL SELECT 'property.Room', COUNT_BIG(*) FROM property.Room
UNION ALL SELECT 'reservation.Reservation', COUNT_BIG(*) FROM reservation.Reservation
UNION ALL SELECT 'reservation.ReservationRoom', COUNT_BIG(*) FROM reservation.ReservationRoom
UNION ALL SELECT 'reservation.RoomInventory', COUNT_BIG(*) FROM reservation.RoomInventory
UNION ALL SELECT 'billing.Payment', COUNT_BIG(*) FROM billing.Payment
UNION ALL SELECT 'billing.PaymentTransaction', COUNT_BIG(*) FROM billing.PaymentTransaction
UNION ALL SELECT 'operations.CheckIn', COUNT_BIG(*) FROM operations.CheckIn
UNION ALL SELECT 'operations.HousekeepingTask', COUNT_BIG(*) FROM operations.HousekeepingTask
UNION ALL SELECT 'reporting.PropertyDailySummary', COUNT_BIG(*) FROM reporting.PropertyDailySummary
ORDER BY TableName;

SELECT
    fk.name AS ForeignKeyName,
    OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id) AS ChildTable,
    fk.is_disabled AS IsDisabled,
    fk.is_not_trusted AS IsNotTrusted
FROM sys.foreign_keys AS fk
WHERE OBJECT_SCHEMA_NAME(fk.parent_object_id) IN ('guest', 'property', 'reservation', 'billing', 'operations', 'reporting')
ORDER BY ChildTable, ForeignKeyName;

DECLARE @Failures TABLE
(
    CheckName nvarchar(200) NOT NULL,
    FailureCount bigint NOT NULL
);

INSERT @Failures
SELECT 'Reservations without guests', COUNT_BIG(*)
FROM reservation.Reservation AS r
LEFT JOIN guest.Guest AS g ON g.GuestId = r.GuestId
WHERE g.GuestId IS NULL
UNION ALL
SELECT 'Reservation rooms without reservations', COUNT_BIG(*)
FROM reservation.ReservationRoom AS rr
LEFT JOIN reservation.Reservation AS r ON r.ReservationId = rr.ReservationId
WHERE r.ReservationId IS NULL
UNION ALL
SELECT 'Payments without reservations', COUNT_BIG(*)
FROM billing.Payment AS p
LEFT JOIN reservation.Reservation AS r ON r.ReservationId = p.ReservationId
WHERE r.ReservationId IS NULL
UNION ALL
SELECT 'Inventory outside its linked stay', COUNT_BIG(*)
FROM reservation.RoomInventory AS inventory
JOIN reservation.ReservationRoom AS rr ON rr.ReservationRoomId = inventory.ReservationRoomId
WHERE inventory.InventoryDate < rr.ArrivalDate OR inventory.InventoryDate >= rr.DepartureDate
UNION ALL
SELECT 'Overlapping active seeded stays', COUNT_BIG(*)
FROM reservation.ReservationRoom AS firstStay
JOIN reservation.Reservation AS firstReservation ON firstReservation.ReservationId = firstStay.ReservationId
JOIN reservation.ReservationRoom AS secondStay
    ON secondStay.RoomId = firstStay.RoomId
    AND secondStay.ReservationRoomId > firstStay.ReservationRoomId
    AND secondStay.ArrivalDate < firstStay.DepartureDate
    AND secondStay.DepartureDate > firstStay.ArrivalDate
JOIN reservation.Reservation AS secondReservation ON secondReservation.ReservationId = secondStay.ReservationId
WHERE firstReservation.ReservationStatus NOT IN ('Cancelled', 'NoShow')
    AND secondReservation.ReservationStatus NOT IN ('Cancelled', 'NoShow');

SELECT CheckName, FailureCount
FROM @Failures
ORDER BY CheckName;

IF EXISTS (SELECT 1 FROM @Failures WHERE FailureCount > 0)
    THROW 51001, 'One or more Phase 1 integrity checks failed.', 1;

IF (SELECT COUNT(*) FROM property.Property) NOT BETWEEN 25 AND 200
    THROW 51002, 'Property count is outside the configured supported range.', 1;

IF NOT EXISTS (SELECT 1 FROM reservation.Reservation)
    THROW 51003, 'No generated reservations were found.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'reservation.RoomInventory')
        AND name = N'IX_RoomInventory_Date_Status_Room'
)
    THROW 51004, 'Expected availability-search index was not found.', 1;

SELECT TOP (20)
    p.PropertyCode,
    inventory.InventoryDate,
    rt.RoomTypeName,
    COUNT(*) AS AvailableRooms,
    MIN(inventory.RateAmount) AS StartingRate
FROM reservation.RoomInventory AS inventory
JOIN property.Room AS room ON room.RoomId = inventory.RoomId
JOIN property.Property AS p ON p.PropertyId = room.PropertyId
JOIN property.RoomType AS rt ON rt.RoomTypeId = room.RoomTypeId
WHERE inventory.InventoryStatus = 'Available'
    AND inventory.InventoryDate BETWEEN DATEADD(day, 7, CONVERT(date, SYSUTCDATETIME()))
        AND DATEADD(day, 30, CONVERT(date, SYSUTCDATETIME()))
GROUP BY p.PropertyCode, inventory.InventoryDate, rt.RoomTypeName
ORDER BY p.PropertyCode, inventory.InventoryDate, rt.RoomTypeName;

PRINT 'Phase 1 validation completed successfully.';
