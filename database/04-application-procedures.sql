SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE operations.GetWorkloadBounds
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        MIN(p.PropertyId) AS MinimumPropertyId,
        MAX(p.PropertyId) AS MaximumPropertyId,
        MIN(g.GuestId) AS MinimumGuestId,
        MAX(g.GuestId) AS MaximumGuestId,
        MIN(r.RoomId) AS MinimumRoomId,
        MAX(r.RoomId) AS MaximumRoomId,
        MIN(res.ReservationId) AS MinimumReservationId,
        MAX(res.ReservationId) AS MaximumReservationId
    FROM property.Property AS p
    CROSS JOIN
    (
        SELECT MIN(GuestId) AS GuestId
        FROM guest.Guest
        UNION ALL
        SELECT MAX(GuestId)
        FROM guest.Guest
    ) AS g
    CROSS JOIN
    (
        SELECT MIN(RoomId) AS RoomId
        FROM property.Room
        UNION ALL
        SELECT MAX(RoomId)
        FROM property.Room
    ) AS r
    CROSS JOIN
    (
        SELECT MIN(ReservationId) AS ReservationId
        FROM reservation.Reservation
        UNION ALL
        SELECT MAX(ReservationId)
        FROM reservation.Reservation
    ) AS res;
END;
GO

CREATE OR ALTER PROCEDURE reservation.SearchAvailability
    @PropertyId int,
    @ArrivalDate date,
    @DepartureDate date
AS
BEGIN
    SET NOCOUNT ON;

    IF @DepartureDate <= @ArrivalDate
        THROW 52001, 'Departure date must be after arrival date.', 1;

    DECLARE @StayDays int = DATEDIFF(day, @ArrivalDate, @DepartureDate);

    ;WITH AvailableRoom AS
    (
        SELECT
            room.RoomId,
            room.RoomTypeId,
            MIN(inventory.RateAmount) AS StartingRate
        FROM property.Room AS room
        JOIN reservation.RoomInventory AS inventory
            ON inventory.RoomId = room.RoomId
        WHERE room.PropertyId = @PropertyId
            AND room.RoomStatus = 'Available'
            AND inventory.InventoryDate >= @ArrivalDate
            AND inventory.InventoryDate < @DepartureDate
        GROUP BY room.RoomId, room.RoomTypeId
        HAVING COUNT(*) = @StayDays
            AND SUM(CASE WHEN inventory.InventoryStatus = 'Available' THEN 1 ELSE 0 END) = @StayDays
    )
    SELECT
        roomType.RoomTypeId,
        roomType.RoomTypeCode,
        roomType.RoomTypeName,
        roomType.MaximumOccupancy,
        COUNT(*) AS AvailableRoomCount,
        MIN(available.StartingRate) AS StartingNightlyRate
    FROM AvailableRoom AS available
    JOIN property.RoomType AS roomType
        ON roomType.RoomTypeId = available.RoomTypeId
    GROUP BY
        roomType.RoomTypeId,
        roomType.RoomTypeCode,
        roomType.RoomTypeName,
        roomType.MaximumOccupancy
    ORDER BY StartingNightlyRate, roomType.RoomTypeCode;
END;
GO

CREATE OR ALTER PROCEDURE reservation.GetReservation
    @ReservationId bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        res.ReservationId,
        res.ReservationNumber,
        res.ReservationStatus,
        res.ArrivalDate,
        res.DepartureDate,
        res.AdultCount,
        res.ChildCount,
        res.SourceChannel,
        g.GuestNumber,
        g.FirstName,
        g.LastName,
        p.PropertyCode,
        p.PropertyName,
        room.RoomNumber,
        roomType.RoomTypeName,
        reservationRoom.NightlyRate,
        pay.PaymentStatus,
        pay.AuthorizedAmount,
        pay.CapturedAmount,
        pay.RefundedAmount
    FROM reservation.Reservation AS res
    JOIN guest.Guest AS g
        ON g.GuestId = res.GuestId
    JOIN property.Property AS p
        ON p.PropertyId = res.PropertyId
    LEFT JOIN reservation.ReservationRoom AS reservationRoom
        ON reservationRoom.ReservationId = res.ReservationId
    LEFT JOIN property.Room AS room
        ON room.RoomId = reservationRoom.RoomId
    LEFT JOIN property.RoomType AS roomType
        ON roomType.RoomTypeId = reservationRoom.RoomTypeId
    LEFT JOIN billing.Payment AS pay
        ON pay.ReservationId = res.ReservationId
    WHERE res.ReservationId = @ReservationId;
END;
GO

CREATE OR ALTER PROCEDURE reservation.CreateReservation
    @GuestId bigint,
    @PropertyId int,
    @ArrivalDate date,
    @DepartureDate date,
    @AdultCount tinyint,
    @ChildCount tinyint,
    @SourceChannel varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @DepartureDate <= @ArrivalDate
        THROW 52002, 'Departure date must be after arrival date.', 1;
    IF @AdultCount < 1 OR @AdultCount + @ChildCount > 12
        THROW 52003, 'Guest counts are outside the supported range.', 1;
    IF @SourceChannel NOT IN ('DirectWeb', 'MobileApp', 'PropertyDesk', 'TravelPartner', 'Corporate')
        THROW 52004, 'Source channel is not supported.', 1;
    IF NOT EXISTS (SELECT 1 FROM guest.Guest WHERE GuestId = @GuestId)
        THROW 52005, 'Guest was not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM property.Property WHERE PropertyId = @PropertyId AND IsActive = 1)
        THROW 52006, 'Active property was not found.', 1;

    DECLARE @StayDays int = DATEDIFF(day, @ArrivalDate, @DepartureDate);
    DECLARE @RoomId int;
    DECLARE @RoomTypeId smallint;
    DECLARE @NightlyRate decimal(10,2);
    DECLARE @ReservationId bigint;
    DECLARE @ReservationRoomId bigint;
    DECLARE @PaymentId bigint;
    DECLARE @ReservationNumber varchar(24) =
        CONCAT(
            'NW',
            CONVERT(char(8), SYSUTCDATETIME(), 112),
            LEFT(REPLACE(CONVERT(varchar(36), NEWID()), '-', ''), 14)
        );

    BEGIN TRANSACTION;
    BEGIN TRY
        SELECT TOP (1)
            @RoomId = room.RoomId,
            @RoomTypeId = room.RoomTypeId,
            @NightlyRate = MIN(inventory.RateAmount)
        FROM property.Room AS room
        JOIN reservation.RoomInventory AS inventory WITH (UPDLOCK, HOLDLOCK)
            ON inventory.RoomId = room.RoomId
        JOIN property.RoomType AS roomType
            ON roomType.RoomTypeId = room.RoomTypeId
        WHERE room.PropertyId = @PropertyId
            AND room.RoomStatus = 'Available'
            AND roomType.MaximumOccupancy >= @AdultCount + @ChildCount
            AND inventory.InventoryDate >= @ArrivalDate
            AND inventory.InventoryDate < @DepartureDate
        GROUP BY room.RoomId, room.RoomTypeId
        HAVING COUNT(*) = @StayDays
            AND SUM(CASE WHEN inventory.InventoryStatus = 'Available' THEN 1 ELSE 0 END) = @StayDays
        ORDER BY MIN(inventory.RateAmount), room.RoomId;

        IF @RoomId IS NULL
            THROW 52007, 'No room is available for the requested stay.', 1;

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
            CreatedAt,
            UpdatedAt
        )
        VALUES
        (
            @ReservationNumber,
            @GuestId,
            @PropertyId,
            'Confirmed',
            SYSUTCDATETIME(),
            @ArrivalDate,
            @DepartureDate,
            @AdultCount,
            @ChildCount,
            @SourceChannel,
            SYSUTCDATETIME(),
            SYSUTCDATETIME()
        );

        SET @ReservationId = SCOPE_IDENTITY();

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
        VALUES
        (
            @ReservationId,
            @RoomId,
            @RoomTypeId,
            @ArrivalDate,
            @DepartureDate,
            @NightlyRate,
            CONVERT(decimal(10,2), @NightlyRate * @StayDays * 0.12),
            @AdultCount + @ChildCount
        );

        SET @ReservationRoomId = SCOPE_IDENTITY();

        UPDATE reservation.RoomInventory
        SET
            InventoryStatus = 'Reserved',
            ReservationRoomId = @ReservationRoomId,
            RateAmount = @NightlyRate,
            UpdatedAt = SYSUTCDATETIME()
        WHERE RoomId = @RoomId
            AND InventoryDate >= @ArrivalDate
            AND InventoryDate < @DepartureDate
            AND InventoryStatus = 'Available';

        IF @@ROWCOUNT <> @StayDays
            THROW 52008, 'Room availability changed while the reservation was being created.', 1;

        INSERT billing.Payment
        (
            ReservationId,
            PaymentStatus,
            PaymentMethod,
            CurrencyCode,
            AuthorizedAmount,
            CapturedAmount,
            RefundedAmount
        )
        VALUES
        (
            @ReservationId,
            'Pending',
            'DigitalWallet',
            'USD',
            CONVERT(decimal(12,2), @NightlyRate * @StayDays * 1.12),
            0,
            0
        );

        SET @PaymentId = SCOPE_IDENTITY();

        COMMIT TRANSACTION;

        SELECT
            @ReservationId AS ReservationId,
            @ReservationNumber AS ReservationNumber,
            @ReservationRoomId AS ReservationRoomId,
            @PaymentId AS PaymentId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE reservation.UpdateGuestCounts
    @ReservationId bigint,
    @AdultCount tinyint,
    @ChildCount tinyint
AS
BEGIN
    SET NOCOUNT ON;

    IF @AdultCount < 1 OR @AdultCount + @ChildCount > 12
        THROW 52009, 'Guest counts are outside the supported range.', 1;

    DECLARE @MaximumOccupancy tinyint;
    DECLARE @ReservationStatus varchar(20);

    SELECT
        @MaximumOccupancy = roomType.MaximumOccupancy,
        @ReservationStatus = res.ReservationStatus
    FROM reservation.Reservation AS res
    JOIN reservation.ReservationRoom AS reservationRoom
        ON reservationRoom.ReservationId = res.ReservationId
    JOIN property.RoomType AS roomType
        ON roomType.RoomTypeId = reservationRoom.RoomTypeId
    WHERE res.ReservationId = @ReservationId;

    IF @MaximumOccupancy IS NULL
        THROW 52010, 'Reservation was not found.', 1;

    IF @ReservationStatus NOT IN ('Pending', 'Confirmed')
    BEGIN
        SELECT CONVERT(bit, 0) AS Updated;
        RETURN;
    END;

    IF @AdultCount + @ChildCount > @MaximumOccupancy
        THROW 52011, 'Guest count exceeds room occupancy.', 1;

    UPDATE reservation.Reservation
    SET
        AdultCount = @AdultCount,
        ChildCount = @ChildCount,
        UpdatedAt = SYSUTCDATETIME()
    WHERE ReservationId = @ReservationId;

    UPDATE reservation.ReservationRoom
    SET GuestCount = @AdultCount + @ChildCount
    WHERE ReservationId = @ReservationId;

    SELECT CONVERT(bit, 1) AS Updated;
END;
GO

CREATE OR ALTER PROCEDURE reservation.CancelReservation
    @ReservationId bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @ReservationStatus varchar(20);

        SELECT @ReservationStatus = ReservationStatus
        FROM reservation.Reservation WITH (UPDLOCK)
        WHERE ReservationId = @ReservationId;

        IF @ReservationStatus IS NULL
            THROW 52012, 'Reservation was not found.', 1;

        IF @ReservationStatus NOT IN ('Pending', 'Confirmed')
        BEGIN
            COMMIT TRANSACTION;
            SELECT CONVERT(bit, 0) AS Cancelled;
            RETURN;
        END;

        UPDATE reservation.Reservation
        SET
            ReservationStatus = 'Cancelled',
            CancelledAt = SYSUTCDATETIME(),
            UpdatedAt = SYSUTCDATETIME()
        WHERE ReservationId = @ReservationId;

        UPDATE inventory
        SET
            InventoryStatus = 'Available',
            ReservationRoomId = NULL,
            UpdatedAt = SYSUTCDATETIME()
        FROM reservation.RoomInventory AS inventory
        JOIN reservation.ReservationRoom AS reservationRoom
            ON reservationRoom.ReservationRoomId = inventory.ReservationRoomId
        WHERE reservationRoom.ReservationId = @ReservationId
            AND inventory.InventoryDate >= CONVERT(date, SYSUTCDATETIME());

        UPDATE billing.Payment
        SET
            PaymentStatus = CASE WHEN CapturedAmount > 0 THEN 'Refunded' ELSE 'Voided' END,
            RefundedAmount = CASE WHEN CapturedAmount > 0 THEN CapturedAmount ELSE 0 END,
            UpdatedAt = SYSUTCDATETIME()
        WHERE ReservationId = @ReservationId
            AND PaymentStatus IN ('Pending', 'Authorized', 'Captured');

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
            PaymentId,
            CASE WHEN CapturedAmount > 0 THEN 'Refund' ELSE 'Void' END,
            'Approved',
            CASE WHEN CapturedAmount > 0 THEN CapturedAmount ELSE 0 END,
            CONCAT('NSC-', REPLACE(CONVERT(varchar(36), NEWID()), '-', '')),
            SYSUTCDATETIME()
        FROM billing.Payment
        WHERE ReservationId = @ReservationId
            AND PaymentStatus IN ('Refunded', 'Voided');

        COMMIT TRANSACTION;
        SELECT CONVERT(bit, 1) AS Cancelled;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE billing.ProcessNextPendingPayment
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @PaymentId bigint;
        DECLARE @Amount decimal(12,2);

        SELECT TOP (1)
            @PaymentId = PaymentId,
            @Amount = AuthorizedAmount
        FROM billing.Payment WITH (UPDLOCK, READPAST, ROWLOCK)
        WHERE PaymentStatus = 'Pending'
        ORDER BY CreatedAt, PaymentId;

        IF @PaymentId IS NULL
        BEGIN
            COMMIT TRANSACTION;
            SELECT CONVERT(bit, 0) AS Processed;
            RETURN;
        END;

        UPDATE billing.Payment
        SET
            PaymentStatus = 'Captured',
            CapturedAmount = @Amount,
            UpdatedAt = SYSUTCDATETIME()
        WHERE PaymentId = @PaymentId;

        INSERT billing.PaymentTransaction
        (
            PaymentId,
            TransactionType,
            TransactionStatus,
            Amount,
            ProcessorReference,
            ProcessedAt
        )
        VALUES
        (
            @PaymentId,
            'Capture',
            'Approved',
            @Amount,
            CONCAT('NSP-', REPLACE(CONVERT(varchar(36), NEWID()), '-', '')),
            SYSUTCDATETIME()
        );

        COMMIT TRANSACTION;
        SELECT CONVERT(bit, 1) AS Processed, @PaymentId AS PaymentId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE operations.CheckInNextArrival
    @PropertyId int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @ReservationId bigint;

        SELECT TOP (1) @ReservationId = ReservationId
        FROM reservation.Reservation WITH (UPDLOCK, READPAST, ROWLOCK)
        WHERE PropertyId = @PropertyId
            AND ReservationStatus = 'Confirmed'
            AND ArrivalDate <= CONVERT(date, SYSUTCDATETIME())
            AND DepartureDate > CONVERT(date, SYSUTCDATETIME())
        ORDER BY ArrivalDate, ReservationId;

        IF @ReservationId IS NULL
        BEGIN
            COMMIT TRANSACTION;
            SELECT CONVERT(bit, 0) AS CheckedIn;
            RETURN;
        END;

        UPDATE reservation.Reservation
        SET
            ReservationStatus = 'CheckedIn',
            UpdatedAt = SYSUTCDATETIME()
        WHERE ReservationId = @ReservationId;

        INSERT operations.CheckIn
        (
            ReservationId,
            PropertyId,
            CheckedInAt,
            CheckedInBy,
            CheckInStatus
        )
        VALUES
        (
            @ReservationId,
            @PropertyId,
            SYSUTCDATETIME(),
            N'Northstar Property Operations',
            'InHouse'
        );

        UPDATE room
        SET RoomStatus = 'Occupied'
        FROM property.Room AS room
        JOIN reservation.ReservationRoom AS reservationRoom
            ON reservationRoom.RoomId = room.RoomId
        WHERE reservationRoom.ReservationId = @ReservationId;

        UPDATE inventory
        SET
            InventoryStatus = 'Occupied',
            UpdatedAt = SYSUTCDATETIME()
        FROM reservation.RoomInventory AS inventory
        JOIN reservation.ReservationRoom AS reservationRoom
            ON reservationRoom.ReservationRoomId = inventory.ReservationRoomId
        WHERE reservationRoom.ReservationId = @ReservationId
            AND inventory.InventoryDate = CONVERT(date, SYSUTCDATETIME());

        COMMIT TRANSACTION;
        SELECT CONVERT(bit, 1) AS CheckedIn, @ReservationId AS ReservationId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE operations.UpdateRoomStatus
    @RoomId int,
    @RoomStatus varchar(20)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RoomStatus NOT IN ('Available', 'Cleaning', 'Maintenance', 'OutOfService')
        THROW 52013, 'Room status is not supported for routine updates.', 1;

    UPDATE property.Room
    SET RoomStatus = @RoomStatus
    WHERE RoomId = @RoomId
        AND RoomStatus <> 'Occupied';

    SELECT CONVERT(bit, IIF(@@ROWCOUNT = 1, 1, 0)) AS Updated;
END;
GO

CREATE OR ALTER PROCEDURE reporting.GetPropertyPerformance
    @PropertyId int,
    @StartDate date,
    @EndDate date
AS
BEGIN
    SET NOCOUNT ON;

    IF @EndDate < @StartDate
        THROW 52014, 'End date must not be before start date.', 1;

    SELECT
        p.PropertyCode,
        p.PropertyName,
        COUNT(*) AS BusinessDayCount,
        SUM(summary.AvailableRoomCount) AS AvailableRoomNights,
        SUM(summary.OccupiedRoomCount) AS OccupiedRoomNights,
        CONVERT(decimal(9,4),
            SUM(summary.OccupiedRoomCount) * 1.0
            / NULLIF(SUM(summary.AvailableRoomCount + summary.OccupiedRoomCount), 0)
        ) AS OccupancyRate,
        SUM(summary.ArrivalCount) AS ArrivalCount,
        SUM(summary.DepartureCount) AS DepartureCount,
        SUM(summary.ReservationRevenue) AS ReservationRevenue,
        SUM(summary.PaymentCollected) AS PaymentCollected,
        SUM(summary.RefundedAmount) AS RefundedAmount
    FROM reporting.PropertyDailySummary AS summary
    JOIN property.Property AS p
        ON p.PropertyId = summary.PropertyId
    WHERE summary.PropertyId = @PropertyId
        AND summary.BusinessDate >= @StartDate
        AND summary.BusinessDate <= @EndDate
    GROUP BY p.PropertyCode, p.PropertyName;
END;
GO
