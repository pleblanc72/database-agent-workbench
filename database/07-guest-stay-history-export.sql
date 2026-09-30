SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'reporting.GuestStayHistoryArchive', N'U') IS NULL
BEGIN
    CREATE TABLE reporting.GuestStayHistoryArchive
    (
        GuestStayHistoryArchiveId bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_GuestStayHistoryArchive PRIMARY KEY,
        ReservationId bigint NOT NULL,
        GuestId bigint NOT NULL,
        PropertyId int NOT NULL,
        ArchiveSequence tinyint NOT NULL,
        StayDate date NOT NULL,
        StayDocument varchar(6000) NOT NULL,
        RecordedAt datetime2(3) NOT NULL,
        CONSTRAINT FK_GuestStayHistoryArchive_Reservation
            FOREIGN KEY (ReservationId) REFERENCES reservation.Reservation (ReservationId),
        CONSTRAINT FK_GuestStayHistoryArchive_Guest
            FOREIGN KEY (GuestId) REFERENCES guest.Guest (GuestId),
        CONSTRAINT FK_GuestStayHistoryArchive_Property
            FOREIGN KEY (PropertyId) REFERENCES property.Property (PropertyId),
        CONSTRAINT UQ_GuestStayHistoryArchive_Reservation_Sequence
            UNIQUE (ReservationId, ArchiveSequence),
        CONSTRAINT CK_GuestStayHistoryArchive_Sequence
            CHECK (ArchiveSequence BETWEEN 1 AND 20)
    );
END;
GO

CREATE OR ALTER PROCEDURE reporting.ExportGuestStayHistory
    @HistoryStartDate date,
    @HistoryEndDate date,
    @PartitionNumber int,
    @PartitionCount int
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF @HistoryEndDate < @HistoryStartDate
        THROW 58001, 'HistoryEndDate must not be before HistoryStartDate.', 1;
    IF @PartitionCount NOT BETWEEN 1 AND 64
        THROW 58002, 'PartitionCount must be between 1 and 64.', 1;
    IF @PartitionNumber < 0 OR @PartitionNumber >= @PartitionCount
        THROW 58003, 'PartitionNumber must identify a valid zero-based partition.', 1;

    DECLARE @MinimumArchiveId bigint;
    DECLARE @MaximumArchiveId bigint;
    DECLARE @ArchivePartitionStartId bigint;
    DECLARE @ArchivePartitionEndId bigint;

    SELECT
        @MinimumArchiveId = MIN(GuestStayHistoryArchiveId),
        @MaximumArchiveId = MAX(GuestStayHistoryArchiveId)
    FROM reporting.GuestStayHistoryArchive;

    IF @MinimumArchiveId IS NOT NULL
    BEGIN
        DECLARE @ArchiveIdRange bigint = @MaximumArchiveId - @MinimumArchiveId + 1;

        SET @ArchivePartitionStartId =
            @MinimumArchiveId + (@ArchiveIdRange * @PartitionNumber / @PartitionCount);
        SET @ArchivePartitionEndId =
            @MinimumArchiveId + (@ArchiveIdRange * (@PartitionNumber + 1) / @PartitionCount) - 1;
    END;

    SELECT
        guestRecord.GuestNumber,
        guestRecord.FirstName,
        guestRecord.LastName,
        guestRecord.LoyaltyTier,
        res.ReservationNumber,
        res.ReservationStatus,
        res.SourceChannel,
        propertyRecord.PropertyCode,
        propertyRecord.PropertyName,
        propertyRecord.City,
        propertyRecord.StateProvince,
        room.RoomNumber,
        roomType.RoomTypeName,
        reservationRoom.ArrivalDate,
        reservationRoom.DepartureDate,
        inventory.InventoryDate AS StayDate,
        inventory.InventoryStatus,
        reservationRoom.GuestCount,
        reservationRoom.NightlyRate,
        reservationRoom.TaxAmount,
        inventory.RateAmount AS AppliedNightlyRate,
        paymentRecord.PaymentStatus,
        paymentRecord.PaymentMethod,
        paymentRecord.AuthorizedAmount,
        paymentRecord.CapturedAmount,
        paymentRecord.RefundedAmount,
        checkInRecord.CheckedInAt,
        checkInRecord.CheckedOutAt,
        checkInRecord.CheckInStatus,
        COALESCE(changeHistory.ChangeCount, 0) AS ChangeCount,
        changeHistory.LatestChangeAt,
        changeHistory.LatestPreviousRate,
        changeHistory.LatestRevisedRate,
        paymentHistory.TransactionCount,
        paymentHistory.LatestTransactionAt
    FROM reservation.Reservation AS res
    JOIN guest.Guest AS guestRecord
        ON guestRecord.GuestId = res.GuestId
    JOIN property.Property AS propertyRecord
        ON propertyRecord.PropertyId = res.PropertyId
    JOIN reservation.ReservationRoom AS reservationRoom
        ON reservationRoom.ReservationId = res.ReservationId
    JOIN property.Room AS room
        ON room.RoomId = reservationRoom.RoomId
    JOIN property.RoomType AS roomType
        ON roomType.RoomTypeId = reservationRoom.RoomTypeId
    JOIN reservation.RoomInventory AS inventory
        ON inventory.ReservationRoomId = reservationRoom.ReservationRoomId
        AND inventory.InventoryDate >= reservationRoom.ArrivalDate
        AND inventory.InventoryDate < reservationRoom.DepartureDate
    LEFT JOIN billing.Payment AS paymentRecord
        ON paymentRecord.ReservationId = res.ReservationId
    LEFT JOIN operations.CheckIn AS checkInRecord
        ON checkInRecord.ReservationId = res.ReservationId
    OUTER APPLY
    (
        SELECT TOP (1)
            COUNT(*) OVER () AS ChangeCount,
            changeRecord.ChangedAt AS LatestChangeAt,
            changeRecord.PreviousNightlyRate AS LatestPreviousRate,
            changeRecord.RevisedNightlyRate AS LatestRevisedRate
        FROM reservation.ReservationChange AS changeRecord
        WHERE changeRecord.ReservationId = res.ReservationId
        ORDER BY changeRecord.ChangedAt DESC, changeRecord.ReservationChangeId DESC
    ) AS changeHistory
    OUTER APPLY
    (
        SELECT
            COUNT(paymentTransaction.PaymentTransactionId) AS TransactionCount,
            MAX(paymentTransaction.ProcessedAt) AS LatestTransactionAt
        FROM billing.PaymentTransaction AS paymentTransaction
        WHERE paymentTransaction.PaymentId = paymentRecord.PaymentId
    ) AS paymentHistory
    WHERE reservationRoom.ArrivalDate >= @HistoryStartDate
        AND reservationRoom.ArrivalDate <= @HistoryEndDate
        AND res.ReservationStatus IN ('Completed', 'CheckedIn')
        AND ABS(CHECKSUM(guestRecord.GuestId)) % @PartitionCount = @PartitionNumber
    ORDER BY
        guestRecord.GuestNumber,
        reservationRoom.ArrivalDate DESC,
        res.ReservationNumber,
        inventory.InventoryDate
    OPTION (RECOMPILE, MAXDOP 1);

    SELECT
        archive.GuestStayHistoryArchiveId,
        archive.ReservationId,
        archive.GuestId,
        archive.PropertyId,
        archive.ArchiveSequence,
        archive.StayDate,
        archive.StayDocument,
        archive.RecordedAt
    FROM reporting.GuestStayHistoryArchive AS archive
    WHERE archive.GuestStayHistoryArchiveId >= @ArchivePartitionStartId
        AND archive.GuestStayHistoryArchiveId <= @ArchivePartitionEndId
        AND archive.StayDate >= @HistoryStartDate
        AND archive.StayDate <= @HistoryEndDate
    OPTION (RECOMPILE, MAXDOP 1);
END;
GO
