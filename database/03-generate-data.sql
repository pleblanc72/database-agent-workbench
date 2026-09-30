/*
    Northstar Reservations configurable data generation

    Run only after 01-schema.sql and 02-reference-data.sql.
    The script refuses to append to an already populated database.
    Lower the values below for a quick local validation run.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @PropertyCount int = 40;
DECLARE @RoomsPerProperty int = 75;
DECLARE @GuestCount int = 50000;
DECLARE @ReservationCount int = 200000;
DECLARE @InventoryPastDays int = 365;
DECLARE @InventoryFutureDays int = 365;
DECLARE @GenerationDate date = CONVERT(date, SYSUTCDATETIME());

IF @PropertyCount NOT BETWEEN 25 AND 200
    THROW 50001, '@PropertyCount must be between 25 and 200.', 1;
IF @RoomsPerProperty NOT BETWEEN 20 AND 500
    THROW 50002, '@RoomsPerProperty must be between 20 and 500.', 1;
IF @GuestCount < 1000
    THROW 50003, '@GuestCount must be at least 1,000.', 1;
IF @ReservationCount < 1000
    THROW 50004, '@ReservationCount must be at least 1,000.', 1;
IF @InventoryPastDays < 30 OR @InventoryFutureDays < 30
    THROW 50005, 'Inventory history and future ranges must each be at least 30 days.', 1;
IF EXISTS (SELECT 1 FROM property.Property)
    OR EXISTS (SELECT 1 FROM guest.Guest)
    OR EXISTS (SELECT 1 FROM reservation.Reservation)
    THROW 50006, 'Generation stopped because operational data already exists.', 1;

DECLARE @RoomCount int = @PropertyCount * @RoomsPerProperty;
DECLARE @InventoryDayCount int = @InventoryPastDays + @InventoryFutureDays + 1;
DECLARE @ReservationWindowDays int = @InventoryDayCount - 10;

IF @ReservationCount > @RoomCount * ((@ReservationWindowDays / 10) + 1)
    THROW 50007, 'Reservation count exceeds the non-overlapping seed capacity for this room and inventory configuration.', 1;

DROP TABLE IF EXISTS #Number;
CREATE TABLE #Number
(
    Number int NOT NULL PRIMARY KEY
);

DECLARE @LargestSet int =
(
    SELECT MAX(Value)
    FROM
    (
        VALUES
            (@PropertyCount),
            (@RoomCount),
            (@GuestCount),
            (@ReservationCount),
            (@InventoryDayCount)
    ) AS sizes (Value)
);

INSERT #Number (Number)
SELECT TOP (@LargestSet)
    CONVERT(int, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)))
FROM sys.all_objects AS a
CROSS JOIN sys.all_objects AS b;

IF @@ROWCOUNT < @LargestSet
    THROW 50008, 'The number source could not produce enough rows for the requested configuration.', 1;

BEGIN TRANSACTION;
BEGIN TRY

INSERT property.Property
(
    PropertyCode,
    PropertyName,
    TimeZoneId,
    AddressLine1,
    City,
    StateProvince,
    PostalCode,
    CountryCode,
    CurrencyCode,
    IsActive,
    OpenedOn
)
SELECT
    CONCAT('NS', RIGHT(CONCAT('000', Number), 3)),
    CONCAT(
        N'Northstar ',
        CHOOSE(((Number - 1) % 10) + 1, N'Harbor', N'Riverside', N'Central', N'Park', N'Grand',
            N'Market', N'Lakeside', N'Garden', N'Airport', N'Plaza'),
        N' ',
        CHOOSE(((Number - 1) % 8) + 1, N'Boston', N'Austin', N'Denver', N'Seattle',
            N'Chicago', N'Atlanta', N'Phoenix', N'Portland')
    ),
    CHOOSE(((Number - 1) % 4) + 1,
        'Eastern Standard Time', 'Central Standard Time', 'Mountain Standard Time', 'Pacific Standard Time'),
    CONCAT(100 + (Number * 17), N' Hospitality Way'),
    CHOOSE(((Number - 1) % 8) + 1, N'Boston', N'Austin', N'Denver', N'Seattle',
        N'Chicago', N'Atlanta', N'Phoenix', N'Portland'),
    CHOOSE(((Number - 1) % 8) + 1, N'MA', N'TX', N'CO', N'WA', N'IL', N'GA', N'AZ', N'OR'),
    RIGHT(CONCAT('00000', 10000 + (Number * 137) % 89999), 5),
    'US',
    'USD',
    1,
    DATEADD(day, -(Number * 113 % 7000), @GenerationDate)
FROM #Number
WHERE Number <= @PropertyCount;

INSERT property.Room
(
    PropertyId,
    RoomTypeId,
    RoomNumber,
    FloorNumber,
    RoomStatus,
    IsAccessible
)
SELECT
    p.PropertyId,
    CONVERT(smallint, ((n.Number - 1) % 5) + 1),
    CONCAT(
        (((n.Number - 1) % @RoomsPerProperty) / 20) + 1,
        RIGHT(CONCAT('00', (((n.Number - 1) % @RoomsPerProperty) % 20) + 1), 2)
    ),
    CONVERT(smallint, (((n.Number - 1) % @RoomsPerProperty) / 20) + 1),
    'Available',
    CONVERT(bit, IIF(n.Number % 20 = 0, 1, 0))
FROM #Number AS n
JOIN property.Property AS p
    ON p.PropertyCode = CONCAT(
        'NS',
        RIGHT(CONCAT('000', ((n.Number - 1) / @RoomsPerProperty) + 1), 3)
    )
WHERE n.Number <= @RoomCount;

DROP TABLE IF EXISTS #GeneratedRoom;
CREATE TABLE #GeneratedRoom
(
    SeedNumber int NOT NULL PRIMARY KEY,
    RoomId int NOT NULL,
    PropertyId int NOT NULL,
    RoomTypeId smallint NOT NULL
);

INSERT #GeneratedRoom (SeedNumber, RoomId, PropertyId, RoomTypeId)
SELECT
    CONVERT(int, ROW_NUMBER() OVER
    (
        ORDER BY p.PropertyCode, r.FloorNumber, CONVERT(int, r.RoomNumber)
    )),
    r.RoomId,
    r.PropertyId,
    r.RoomTypeId
FROM property.Room AS r
JOIN property.Property AS p
    ON p.PropertyId = r.PropertyId;

INSERT guest.Guest
(
    GuestNumber,
    FirstName,
    LastName,
    EmailAddress,
    PhoneNumber,
    LoyaltyTier,
    CreatedAt,
    UpdatedAt
)
SELECT
    CONCAT('NG', RIGHT(CONCAT('00000000', Number), 8)),
    CHOOSE(((Number - 1) % 16) + 1, N'Olivia', N'Liam', N'Emma', N'Noah', N'Amelia', N'Elijah',
        N'Sophia', N'James', N'Isabella', N'Lucas', N'Mia', N'Henry', N'Evelyn', N'Theo', N'Camila', N'Jack'),
    CHOOSE((((Number - 1) / 16) % 16) + 1, N'Bennett', N'Carter', N'Diaz', N'Edwards', N'Foster', N'Green',
        N'Hayes', N'Irwin', N'Johnson', N'Kim', N'Lewis', N'Morgan', N'Nguyen', N'Ortiz', N'Patel', N'Reed'),
    CONCAT('guest', Number, '@northstar.example'),
    CONCAT('+1-555-', RIGHT(CONCAT('000', (Number / 10000) % 1000), 3), '-', RIGHT(CONCAT('0000', Number % 10000), 4)),
    CASE
        WHEN Number % 50 = 0 THEN 'Platinum'
        WHEN Number % 10 = 0 THEN 'Gold'
        WHEN Number % 4 = 0 THEN 'Silver'
        ELSE 'Member'
    END,
    DATEADD(day, -(Number % 1825), SYSUTCDATETIME()),
    DATEADD(day, -(Number % 365), SYSUTCDATETIME())
FROM #Number
WHERE Number <= @GuestCount;

DROP TABLE IF EXISTS #ReservationSeed;
CREATE TABLE #ReservationSeed
(
    SeedNumber int NOT NULL PRIMARY KEY,
    GuestId bigint NOT NULL,
    RoomId int NOT NULL,
    PropertyId int NOT NULL,
    RoomTypeId smallint NOT NULL,
    ArrivalDate date NOT NULL,
    DepartureDate date NOT NULL,
    ReservationStatus varchar(20) NOT NULL,
    NightlyRate decimal(10,2) NOT NULL
);

INSERT #ReservationSeed
(
    SeedNumber,
    GuestId,
    RoomId,
    PropertyId,
    RoomTypeId,
    ArrivalDate,
    DepartureDate,
    ReservationStatus,
    NightlyRate
)
SELECT
    n.Number,
    g.GuestId,
    r.RoomId,
    r.PropertyId,
    r.RoomTypeId,
    DATEADD(day, -@InventoryPastDays + (((n.Number - 1) / @RoomCount) * 10), @GenerationDate),
    DATEADD(day, -@InventoryPastDays + (((n.Number - 1) / @RoomCount) * 10) + ((n.Number % 4) + 1), @GenerationDate),
    CASE
        WHEN DATEADD(day, -@InventoryPastDays + (((n.Number - 1) / @RoomCount) * 10), @GenerationDate) > @GenerationDate
            THEN IIF(n.Number % 12 = 0, 'Cancelled', 'Confirmed')
        WHEN DATEADD(day, -@InventoryPastDays + (((n.Number - 1) / @RoomCount) * 10) + ((n.Number % 4) + 1), @GenerationDate) > @GenerationDate
            THEN 'CheckedIn'
        WHEN n.Number % 20 = 0 THEN 'Cancelled'
        WHEN n.Number % 31 = 0 THEN 'NoShow'
        ELSE 'Completed'
    END,
    CONVERT(decimal(10,2), rt.BaseRate * (1 + ((n.Number % 7) - 3) * 0.025))
FROM #Number AS n
JOIN #GeneratedRoom AS r
    ON r.SeedNumber = ((n.Number - 1) % @RoomCount) + 1
JOIN property.RoomType AS rt
    ON rt.RoomTypeId = r.RoomTypeId
JOIN guest.Guest AS g
    ON g.GuestNumber = CONCAT(
        'NG',
        RIGHT(CONCAT('00000000', ((n.Number * 37 - 1) % @GuestCount) + 1), 8)
    )
WHERE n.Number <= @ReservationCount;

INSERT reservation.Reservation
(
    ReservationNumber,
    GuestId,
    PropertyId,
    ReservationStatus,
    BookedAt,
    ArrivalDate,
    DepartureDate,
    AdultCount,
    ChildCount,
    SourceChannel,
    SpecialRequests,
    CancelledAt,
    CreatedAt,
    UpdatedAt
)
SELECT
    CONCAT('NR', CONVERT(char(8), @GenerationDate, 112), RIGHT(CONCAT('000000000', SeedNumber), 9)),
    GuestId,
    PropertyId,
    ReservationStatus,
    DATEADD(day, -(14 + SeedNumber % 120), CONVERT(datetime2(3), ArrivalDate)),
    ArrivalDate,
    DepartureDate,
    CONVERT(tinyint, (SeedNumber % 2) + 1),
    CONVERT(tinyint, IIF(SeedNumber % 5 = 0, 1, 0)),
    CHOOSE((SeedNumber % 5) + 1, 'DirectWeb', 'MobileApp', 'PropertyDesk', 'TravelPartner', 'Corporate'),
    IIF(SeedNumber % 25 = 0, N'Quiet room requested', NULL),
    IIF(ReservationStatus = 'Cancelled', DATEADD(day, -2, CONVERT(datetime2(3), ArrivalDate)), NULL),
    DATEADD(day, -(14 + SeedNumber % 120), CONVERT(datetime2(3), ArrivalDate)),
    DATEADD(day, IIF(ReservationStatus IN ('Completed', 'Cancelled', 'NoShow'), 1, 0), CONVERT(datetime2(3), ArrivalDate))
FROM #ReservationSeed
ORDER BY SeedNumber;

INSERT reservation.ReservationRoom
(
    ReservationId,
    RoomId,
    RoomTypeId,
    ArrivalDate,
    DepartureDate,
    NightlyRate,
    TaxAmount,
    GuestCount
)
SELECT
    r.ReservationId,
    s.RoomId,
    s.RoomTypeId,
    s.ArrivalDate,
    s.DepartureDate,
    s.NightlyRate,
    CONVERT(decimal(10,2), s.NightlyRate * DATEDIFF(day, s.ArrivalDate, s.DepartureDate) * 0.12),
    CONVERT(tinyint, (s.SeedNumber % 3) + 1)
FROM #ReservationSeed AS s
JOIN reservation.Reservation AS r
    ON r.ReservationNumber = CONCAT('NR', CONVERT(char(8), @GenerationDate, 112), RIGHT(CONCAT('000000000', s.SeedNumber), 9));

INSERT reservation.RoomInventory
(
    RoomId,
    InventoryDate,
    InventoryStatus,
    ReservationRoomId,
    RateAmount,
    UpdatedAt
)
SELECT
    r.RoomId,
    DATEADD(day, d.Number - @InventoryPastDays - 1, @GenerationDate),
    'Available',
    NULL,
    CONVERT(decimal(10,2), rt.BaseRate * (1 + ((DATEPART(weekday, DATEADD(day, d.Number - @InventoryPastDays - 1, @GenerationDate)) + 5) % 7) * 0.02)),
    SYSUTCDATETIME()
FROM property.Room AS r
JOIN property.RoomType AS rt
    ON rt.RoomTypeId = r.RoomTypeId
JOIN #Number AS d
    ON d.Number <= @InventoryDayCount;

UPDATE inventory
SET
    InventoryStatus = CASE
        WHEN booking.ReservationStatus = 'CheckedIn' THEN 'Occupied'
        ELSE 'Reserved'
    END,
    ReservationRoomId = booking.ReservationRoomId,
    RateAmount = booking.NightlyRate,
    UpdatedAt = SYSUTCDATETIME()
FROM reservation.RoomInventory AS inventory
JOIN
(
    SELECT
        rr.ReservationRoomId,
        rr.RoomId,
        rr.ArrivalDate,
        rr.DepartureDate,
        rr.NightlyRate,
        r.ReservationStatus
    FROM reservation.ReservationRoom AS rr
    JOIN reservation.Reservation AS r
        ON r.ReservationId = rr.ReservationId
    WHERE r.ReservationStatus NOT IN ('Cancelled', 'NoShow')
) AS booking
    ON booking.RoomId = inventory.RoomId
    AND inventory.InventoryDate >= booking.ArrivalDate
    AND inventory.InventoryDate < booking.DepartureDate;

INSERT billing.Payment
(
    ReservationId,
    PaymentStatus,
    PaymentMethod,
    CurrencyCode,
    AuthorizedAmount,
    CapturedAmount,
    RefundedAmount,
    CreatedAt,
    UpdatedAt
)
SELECT
    r.ReservationId,
    CASE r.ReservationStatus
        WHEN 'Cancelled' THEN IIF(r.ReservationId % 3 = 0, 'Refunded', 'Voided')
        WHEN 'NoShow' THEN 'Captured'
        WHEN 'Pending' THEN 'Pending'
        ELSE 'Captured'
    END,
    CHOOSE((r.ReservationId % 5) + 1, 'Visa', 'Mastercard', 'Amex', 'DigitalWallet', 'BankTransfer'),
    'USD',
    totals.TotalAmount,
    CASE WHEN r.ReservationStatus = 'Cancelled' AND r.ReservationId % 3 <> 0 THEN 0 ELSE totals.TotalAmount END,
    CASE WHEN r.ReservationStatus = 'Cancelled' AND r.ReservationId % 3 = 0 THEN totals.TotalAmount ELSE 0 END,
    r.BookedAt,
    DATEADD(hour, 1, r.BookedAt)
FROM reservation.Reservation AS r
CROSS APPLY
(
    SELECT CONVERT(decimal(12,2), SUM(rr.NightlyRate * DATEDIFF(day, rr.ArrivalDate, rr.DepartureDate) + rr.TaxAmount))
    FROM reservation.ReservationRoom AS rr
    WHERE rr.ReservationId = r.ReservationId
) AS totals (TotalAmount);

INSERT billing.PaymentTransaction
(
    PaymentId,
    TransactionType,
    TransactionStatus,
    Amount,
    ProcessorReference,
    ProcessedAt
)
SELECT
    p.PaymentId,
    CASE
        WHEN p.PaymentStatus = 'Refunded' THEN 'Refund'
        WHEN p.PaymentStatus = 'Voided' THEN 'Void'
        ELSE 'Capture'
    END,
    'Approved',
    CASE WHEN p.PaymentStatus = 'Refunded' THEN p.RefundedAmount ELSE p.CapturedAmount END,
    CONCAT('NSP-', RIGHT(CONCAT('000000000000', p.PaymentId), 12)),
    DATEADD(minute, p.PaymentId % 120, p.CreatedAt)
FROM billing.Payment AS p
WHERE p.PaymentStatus NOT IN ('Pending', 'Declined');

INSERT operations.CheckIn
(
    ReservationId,
    PropertyId,
    CheckedInAt,
    CheckedOutAt,
    CheckedInBy,
    CheckInStatus
)
SELECT
    r.ReservationId,
    r.PropertyId,
    DATEADD(hour, 15, CONVERT(datetime2(3), r.ArrivalDate)),
    CASE WHEN r.ReservationStatus = 'Completed'
        THEN DATEADD(hour, 11, CONVERT(datetime2(3), r.DepartureDate))
        ELSE NULL
    END,
    CONCAT(N'Property Associate ', (r.PropertyId % 12) + 1),
    IIF(r.ReservationStatus = 'Completed', 'CheckedOut', 'InHouse')
FROM reservation.Reservation AS r
WHERE r.ReservationStatus IN ('CheckedIn', 'Completed');

INSERT operations.HousekeepingTask
(
    PropertyId,
    RoomId,
    ServiceDate,
    TaskType,
    TaskStatus,
    Priority,
    AssignedTo,
    StartedAt,
    CompletedAt,
    CreatedAt
)
SELECT
    r.PropertyId,
    r.RoomId,
    DATEADD(day, -((r.RoomId - 1) % 14), @GenerationDate),
    CASE WHEN r.RoomId % 10 = 0 THEN 'DeepClean' ELSE 'Turnover' END,
    CASE WHEN r.RoomId % 7 = 0 THEN 'Open' ELSE 'Completed' END,
    CONVERT(tinyint, (r.RoomId % 3) + 1),
    CONCAT(N'Housekeeping Team ', (r.RoomId % 8) + 1),
    DATEADD(hour, 9, CONVERT(datetime2(3), DATEADD(day, -((r.RoomId - 1) % 14), @GenerationDate))),
    CASE WHEN r.RoomId % 7 = 0 THEN NULL
        ELSE DATEADD(minute, 35, DATEADD(hour, 9, CONVERT(datetime2(3), DATEADD(day, -((r.RoomId - 1) % 14), @GenerationDate))))
    END,
    DATEADD(hour, 8, CONVERT(datetime2(3), DATEADD(day, -((r.RoomId - 1) % 14), @GenerationDate)))
FROM property.Room AS r;

INSERT reporting.PropertyDailySummary
(
    PropertyId,
    BusinessDate,
    AvailableRoomCount,
    OccupiedRoomCount,
    ArrivalCount,
    DepartureCount,
    ReservationRevenue,
    PaymentCollected,
    RefundedAmount,
    CalculatedAt
)
SELECT
    p.PropertyId,
    dates.BusinessDate,
    roomTotals.AvailableRoomCount,
    roomTotals.OccupiedRoomCount,
    reservationTotals.ArrivalCount,
    reservationTotals.DepartureCount,
    roomTotals.ReservationRevenue,
    COALESCE(paymentTotals.CollectedAmount, 0),
    COALESCE(paymentTotals.RefundedAmount, 0),
    SYSUTCDATETIME()
FROM property.Property AS p
CROSS APPLY
(
    SELECT DATEADD(day, n.Number - 91, @GenerationDate)
    FROM #Number AS n
    WHERE n.Number <= 181
) AS dates (BusinessDate)
CROSS APPLY
(
    SELECT
        SUM(CASE WHEN inventory.InventoryStatus = 'Available' THEN 1 ELSE 0 END) AS AvailableRoomCount,
        SUM(CASE WHEN inventory.InventoryStatus IN ('Reserved', 'Occupied') THEN 1 ELSE 0 END) AS OccupiedRoomCount,
        COALESCE(SUM(CASE WHEN inventory.InventoryStatus IN ('Reserved', 'Occupied')
            THEN inventory.RateAmount ELSE 0 END), 0) AS ReservationRevenue
    FROM property.Room AS room
    JOIN reservation.RoomInventory AS inventory
        ON inventory.RoomId = room.RoomId
        AND inventory.InventoryDate = dates.BusinessDate
    WHERE room.PropertyId = p.PropertyId
) AS roomTotals
CROSS APPLY
(
    SELECT
        (
            SELECT COUNT(*)
            FROM reservation.Reservation AS arrival
            WHERE arrival.PropertyId = p.PropertyId
                AND arrival.ArrivalDate = dates.BusinessDate
                AND arrival.ReservationStatus NOT IN ('Cancelled', 'NoShow')
        ) AS ArrivalCount,
        (
            SELECT COUNT(*)
            FROM reservation.Reservation AS departure
            WHERE departure.PropertyId = p.PropertyId
                AND departure.DepartureDate = dates.BusinessDate
                AND departure.ReservationStatus = 'Completed'
        ) AS DepartureCount
) AS reservationTotals
OUTER APPLY
(
    SELECT
        SUM(pay.CapturedAmount) AS CollectedAmount,
        SUM(pay.RefundedAmount) AS RefundedAmount
    FROM billing.Payment AS pay
    JOIN reservation.Reservation AS paidReservation
        ON paidReservation.ReservationId = pay.ReservationId
    WHERE paidReservation.PropertyId = p.PropertyId
        AND CONVERT(date, pay.UpdatedAt) = dates.BusinessDate
) AS paymentTotals;

COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;

SELECT
    @PropertyCount AS GeneratedProperties,
    @RoomCount AS GeneratedRooms,
    @GuestCount AS GeneratedGuests,
    @ReservationCount AS GeneratedReservations,
    @RoomCount * @InventoryDayCount AS GeneratedInventoryDays;
