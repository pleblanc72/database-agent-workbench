/*
    Northstar Reservations historical stay archive generation

    The default profile creates approximately 12 GB of denormalized historical
    stay documents. Adjust the values below for a different service tier.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @CopiesPerReservation int = 10;
DECLARE @PayloadBytes int = 6000;
DECLARE @ReservationBatchSize int = 5000;

IF @CopiesPerReservation NOT BETWEEN 1 AND 20
    THROW 60001, 'CopiesPerReservation must be between 1 and 20.', 1;
IF @PayloadBytes NOT BETWEEN 1000 AND 6000
    THROW 60002, 'PayloadBytes must be between 1,000 and 6,000.', 1;
IF @ReservationBatchSize NOT BETWEEN 1000 AND 20000
    THROW 60003, 'ReservationBatchSize must be between 1,000 and 20,000.', 1;
IF OBJECT_ID(N'reporting.GuestStayHistoryArchive', N'U') IS NULL
    THROW 60004, 'Run 07-guest-stay-history-export.sql before generating archive data.', 1;

DECLARE @MinimumReservationId bigint;
DECLARE @MaximumReservationId bigint;

SELECT
    @MinimumReservationId = MIN(ReservationId),
    @MaximumReservationId = MAX(ReservationId)
FROM reservation.Reservation;

IF @MinimumReservationId IS NULL
    THROW 60006, 'No reservations are available for archive generation.', 1;

DECLARE @ArchiveSequence int = 1;

WHILE @ArchiveSequence <= @CopiesPerReservation
BEGIN
    DECLARE @BatchStartReservationId bigint = @MinimumReservationId;

    WHILE @BatchStartReservationId <= @MaximumReservationId
    BEGIN
        DECLARE @BatchEndReservationId bigint =
            @BatchStartReservationId + @ReservationBatchSize - 1;

        BEGIN TRANSACTION;
        BEGIN TRY
            INSERT reporting.GuestStayHistoryArchive
            (
                ReservationId,
                GuestId,
                PropertyId,
                ArchiveSequence,
                StayDate,
                StayDocument,
                RecordedAt
            )
            SELECT
                res.ReservationId,
                res.GuestId,
                res.PropertyId,
                @ArchiveSequence,
                DATEADD(day, -(@ArchiveSequence * 365), res.ArrivalDate),
                CONVERT(varchar(6000),
                    documentPrefix.DocumentPrefix
                    + LEFT(
                        REPLICATE(
                            'Archived guest stay record retained for service history, folio review, loyalty support, and regulatory audit. ',
                            60),
                        @PayloadBytes - DATALENGTH(documentPrefix.DocumentPrefix))),
                DATEADD(day, -(@ArchiveSequence * 365), res.UpdatedAt)
            FROM reservation.Reservation AS res
            CROSS APPLY
            (
                SELECT CONCAT(
                    '{"reservation":"', res.ReservationNumber,
                    '","status":"', res.ReservationStatus,
                    '","source":"', res.SourceChannel,
                    '","arrival":"', CONVERT(char(10), res.ArrivalDate, 23),
                    '","departure":"', CONVERT(char(10), res.DepartureDate, 23),
                    '","archiveSequence":', @ArchiveSequence,
                    ',"stayNarrative":"')
            ) AS documentPrefix (DocumentPrefix)
            WHERE res.ReservationId >= @BatchStartReservationId
                AND res.ReservationId <= @BatchEndReservationId
                AND NOT EXISTS
                (
                    SELECT 1
                    FROM reporting.GuestStayHistoryArchive AS existingArchive
                    WHERE existingArchive.ReservationId = res.ReservationId
                        AND existingArchive.ArchiveSequence = @ArchiveSequence
                );

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;
        END CATCH;

        SET @BatchStartReservationId = @BatchEndReservationId + 1;
    END;

    RAISERROR(
        'Completed archive sequence %d of %d.',
        0,
        1,
        @ArchiveSequence,
        @CopiesPerReservation
    ) WITH NOWAIT;

    SET @ArchiveSequence += 1;
END;

SELECT
    COUNT_BIG(*) AS GeneratedArchiveRows,
    SUM(CONVERT(bigint, DATALENGTH(StayDocument))) AS GeneratedPayloadBytes
FROM reporting.GuestStayHistoryArchive;
