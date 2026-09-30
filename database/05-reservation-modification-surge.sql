SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'reservation.ReservationChange', N'U') IS NULL
BEGIN
    CREATE TABLE reservation.ReservationChange
    (
        ReservationChangeId bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_ReservationChange PRIMARY KEY,
        ReservationId bigint NOT NULL,
        PropertyId int NOT NULL,
        ChangeBatchId uniqueidentifier NOT NULL,
        ChangeType varchar(30) NOT NULL,
        PreviousNightlyRate decimal(10,2) NOT NULL,
        RevisedNightlyRate decimal(10,2) NOT NULL,
        ChangedAt datetime2(3) NOT NULL,
        ChangedByApplication varchar(100) NOT NULL,
        CONSTRAINT FK_ReservationChange_Reservation
            FOREIGN KEY (ReservationId) REFERENCES reservation.Reservation (ReservationId),
        CONSTRAINT FK_ReservationChange_Property
            FOREIGN KEY (PropertyId) REFERENCES property.Property (PropertyId),
        CONSTRAINT CK_ReservationChange_Type
            CHECK (ChangeType IN ('StayPricing', 'GuestDetails', 'StayDates', 'RoomAssignment')),
        CONSTRAINT CK_ReservationChange_Rates
            CHECK (PreviousNightlyRate > 0 AND RevisedNightlyRate > 0)
    );

    CREATE INDEX IX_ReservationChange_Reservation_ChangedAt
        ON reservation.ReservationChange (ReservationId, ChangedAt DESC)
        INCLUDE (ChangeType, PreviousNightlyRate, RevisedNightlyRate, ChangeBatchId);

    CREATE INDEX IX_ReservationChange_Property_ChangedAt
        ON reservation.ReservationChange (PropertyId, ChangedAt DESC)
        INCLUDE (ReservationId, ChangeType, ChangeBatchId);
END;
GO

CREATE OR ALTER PROCEDURE reservation.ApplyReservationModificationBatch
    @PropertyId int,
    @WindowStartDate date,
    @WindowDays int = 120,
    @BatchSize int = 150,
    @RateAdjustmentBasisPoints int = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @WindowDays NOT BETWEEN 30 AND 365
        THROW 54001, 'WindowDays must be between 30 and 365.', 1;
    IF @BatchSize NOT BETWEEN 25 AND 1000
        THROW 54002, 'BatchSize must be between 25 and 1,000.', 1;
    IF @RateAdjustmentBasisPoints NOT BETWEEN -200 AND 200
        THROW 54003, 'RateAdjustmentBasisPoints must be between -200 and 200.', 1;
    IF NOT EXISTS (SELECT 1 FROM property.Property WHERE PropertyId = @PropertyId AND IsActive = 1)
        THROW 54004, 'Active property was not found.', 1;

    DECLARE @WindowEndDate date = DATEADD(day, @WindowDays, @WindowStartDate);
    DECLARE @ChangeBatchId uniqueidentifier = NEWID();

    DROP TABLE IF EXISTS #ReservationChangeCandidate;
    CREATE TABLE #ReservationChangeCandidate
    (
        ReservationId bigint NOT NULL PRIMARY KEY,
        ReservationRoomId bigint NOT NULL,
        PreviousNightlyRate decimal(10,2) NOT NULL,
        RevisedNightlyRate decimal(10,2) NOT NULL
    );

    BEGIN TRANSACTION;
    BEGIN TRY
        UPDATE inventory WITH (UPDLOCK)
        SET
            RateAmount = CONVERT(decimal(10,2),
                roomType.BaseRate
                * (1 + CASE WHEN DATEPART(weekday, inventory.InventoryDate) IN (1, 7) THEN 0.08 ELSE 0 END)
                * (1 + @RateAdjustmentBasisPoints / 10000.0)),
            UpdatedAt = SYSUTCDATETIME()
        FROM reservation.RoomInventory AS inventory
        JOIN property.Room AS room
            ON room.RoomId = inventory.RoomId
        JOIN property.RoomType AS roomType
            ON roomType.RoomTypeId = room.RoomTypeId
        WHERE room.PropertyId = @PropertyId
            AND inventory.InventoryDate >= @WindowStartDate
            AND inventory.InventoryDate < @WindowEndDate;

        INSERT #ReservationChangeCandidate
        (
            ReservationId,
            ReservationRoomId,
            PreviousNightlyRate,
            RevisedNightlyRate
        )
        SELECT TOP (@BatchSize)
            res.ReservationId,
            reservationRoom.ReservationRoomId,
            reservationRoom.NightlyRate,
            CONVERT(decimal(10,2),
                roomType.BaseRate * (1 + @RateAdjustmentBasisPoints / 10000.0))
        FROM reservation.Reservation AS res WITH (UPDLOCK)
        JOIN reservation.ReservationRoom AS reservationRoom
            ON reservationRoom.ReservationId = res.ReservationId
        JOIN property.RoomType AS roomType
            ON roomType.RoomTypeId = reservationRoom.RoomTypeId
        WHERE res.PropertyId = @PropertyId
            AND res.ReservationStatus IN ('Pending', 'Confirmed')
            AND res.ArrivalDate < @WindowEndDate
            AND res.DepartureDate > @WindowStartDate
        ORDER BY CHECKSUM(res.ReservationId, @ChangeBatchId);

        UPDATE reservationRoom
        SET
            NightlyRate = candidate.RevisedNightlyRate,
            TaxAmount = CONVERT(decimal(10,2),
                candidate.RevisedNightlyRate
                * DATEDIFF(day, reservationRoom.ArrivalDate, reservationRoom.DepartureDate)
                * 0.12)
        FROM reservation.ReservationRoom AS reservationRoom
        JOIN #ReservationChangeCandidate AS candidate
            ON candidate.ReservationRoomId = reservationRoom.ReservationRoomId;

        UPDATE inventory
        SET
            RateAmount = candidate.RevisedNightlyRate,
            UpdatedAt = SYSUTCDATETIME()
        FROM reservation.RoomInventory AS inventory
        JOIN #ReservationChangeCandidate AS candidate
            ON candidate.ReservationRoomId = inventory.ReservationRoomId;

        UPDATE res
        SET UpdatedAt = SYSUTCDATETIME()
        FROM reservation.Reservation AS res
        JOIN #ReservationChangeCandidate AS candidate
            ON candidate.ReservationId = res.ReservationId;

        INSERT reservation.ReservationChange
        (
            ReservationId,
            PropertyId,
            ChangeBatchId,
            ChangeType,
            PreviousNightlyRate,
            RevisedNightlyRate,
            ChangedAt,
            ChangedByApplication
        )
        SELECT
            candidate.ReservationId,
            @PropertyId,
            @ChangeBatchId,
            'StayPricing',
            candidate.PreviousNightlyRate,
            candidate.RevisedNightlyRate,
            SYSUTCDATETIME(),
            'Northstar Reservation Management'
        FROM #ReservationChangeCandidate AS candidate;

        UPDATE summary
        SET
            ReservationRevenue = totals.ReservationRevenue,
            CalculatedAt = SYSUTCDATETIME()
        FROM reporting.PropertyDailySummary AS summary
        CROSS APPLY
        (
            SELECT
                COALESCE(SUM(CASE
                    WHEN inventory.InventoryStatus IN ('Reserved', 'Occupied')
                    THEN inventory.RateAmount
                    ELSE 0
                END), 0)
            FROM property.Room AS room
            JOIN reservation.RoomInventory AS inventory
                ON inventory.RoomId = room.RoomId
                AND inventory.InventoryDate = summary.BusinessDate
            WHERE room.PropertyId = summary.PropertyId
        ) AS totals (ReservationRevenue)
        WHERE summary.PropertyId = @PropertyId
            AND summary.BusinessDate >= @WindowStartDate
            AND summary.BusinessDate < @WindowEndDate;

        COMMIT TRANSACTION;

        SELECT
            @ChangeBatchId AS ChangeBatchId,
            COUNT(*) AS ModifiedReservationCount
        FROM #ReservationChangeCandidate;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO
