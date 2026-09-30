SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE reporting.ReconcilePortfolioRevenue
    @PeriodStartDate date,
    @PeriodEndDate date,
    @PartitionNumber int,
    @PartitionCount int
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF @PeriodEndDate < @PeriodStartDate
        THROW 61001, 'PeriodEndDate must not be before PeriodStartDate.', 1;
    IF @PartitionCount NOT BETWEEN 1 AND 8
        THROW 61002, 'PartitionCount must be between 1 and 8.', 1;
    IF @PartitionNumber < 0 OR @PartitionNumber >= @PartitionCount
        THROW 61003, 'PartitionNumber must identify a valid zero-based partition.', 1;
    IF OBJECT_ID(N'reporting.GuestStayHistoryArchive', N'U') IS NULL
        THROW 61004, 'Guest stay history archive data is required for reconciliation.', 1;

    DROP TABLE IF EXISTS #ArchiveEvidence;
    DROP TABLE IF EXISTS #ArchiveLedger;
    DROP TABLE IF EXISTS #StayLedger;
    DROP TABLE IF EXISTS #PaymentLedger;

    SELECT
        archive.ReservationId,
        archive.PropertyId,
        archive.ArchiveSequence,
        archive.StayDate,
        DATALENGTH(archive.StayDocument) AS DocumentBytes,
        HASHBYTES('SHA2_256', archive.StayDocument) AS DocumentHash
    INTO #ArchiveEvidence
    FROM reporting.GuestStayHistoryArchive AS archive
    WHERE archive.StayDate >= @PeriodStartDate
        AND archive.StayDate <= @PeriodEndDate
        AND (archive.PropertyId - 1) % @PartitionCount = @PartitionNumber
    OPTION (RECOMPILE, MAXDOP 1);

    CREATE CLUSTERED INDEX CX_ArchiveEvidence_Reservation_Sequence
        ON #ArchiveEvidence (ReservationId, ArchiveSequence);

    SELECT
        evidence.ReservationId,
        COUNT_BIG(*) AS ArchiveDocumentCount,
        SUM(CONVERT(bigint, evidence.DocumentBytes)) AS ArchiveDocumentBytes,
        CHECKSUM_AGG(BINARY_CHECKSUM(evidence.DocumentHash)) AS ArchiveIntegrityChecksum,
        MIN(evidence.StayDate) AS FirstArchivedStayDate,
        MAX(evidence.StayDate) AS LatestArchivedStayDate
    INTO #ArchiveLedger
    FROM #ArchiveEvidence AS evidence
    GROUP BY evidence.ReservationId;

    CREATE UNIQUE CLUSTERED INDEX CX_ArchiveLedger_Reservation
        ON #ArchiveLedger (ReservationId);

    ;WITH MonthlyStay AS
    (
        SELECT
            res.ReservationId,
            res.PropertyId,
            DATEFROMPARTS(YEAR(inventory.InventoryDate), MONTH(inventory.InventoryDate), 1)
                AS AccountingMonth,
            SUM(inventory.RateAmount) AS NightlyRevenue,
            MAX(reservationRoom.TaxAmount) AS ReservationTaxAmount,
            COUNT_BIG(*) AS OccupiedNightCount
        FROM reservation.Reservation AS res
        JOIN reservation.ReservationRoom AS reservationRoom
            ON reservationRoom.ReservationId = res.ReservationId
        JOIN reservation.RoomInventory AS inventory
            ON inventory.ReservationRoomId = reservationRoom.ReservationRoomId
            AND inventory.InventoryDate >= reservationRoom.ArrivalDate
            AND inventory.InventoryDate < reservationRoom.DepartureDate
        WHERE inventory.InventoryDate >= @PeriodStartDate
            AND inventory.InventoryDate <= @PeriodEndDate
            AND res.ReservationStatus IN ('CheckedIn', 'Completed')
            AND (res.PropertyId - 1) % @PartitionCount = @PartitionNumber
        GROUP BY
            res.ReservationId,
            res.PropertyId,
            DATEFROMPARTS(YEAR(inventory.InventoryDate), MONTH(inventory.InventoryDate), 1)
    )
    SELECT
        monthly.ReservationId,
        monthly.PropertyId,
        monthly.AccountingMonth,
        monthly.NightlyRevenue,
        monthly.ReservationTaxAmount,
        monthly.OccupiedNightCount,
        SUM(monthly.NightlyRevenue) OVER
            (PARTITION BY monthly.ReservationId) AS ReservationNightlyRevenue
    INTO #StayLedger
    FROM MonthlyStay AS monthly
    OPTION (RECOMPILE, MAXDOP 1);

    CREATE CLUSTERED INDEX CX_StayLedger_Reservation
        ON #StayLedger (ReservationId, AccountingMonth);

    ;WITH PaymentTransactionLedger AS
    (
        SELECT
            paymentTransaction.PaymentId,
            SUM(CASE
                WHEN paymentTransaction.TransactionType = 'Capture'
                    AND paymentTransaction.TransactionStatus = 'Approved'
                THEN paymentTransaction.Amount
                ELSE 0
            END) AS TransactionCaptureAmount,
            SUM(CASE
                WHEN paymentTransaction.TransactionType = 'Refund'
                    AND paymentTransaction.TransactionStatus = 'Approved'
                THEN paymentTransaction.Amount
                ELSE 0
            END) AS TransactionRefundAmount,
            COUNT_BIG(*) AS TransactionCount
        FROM billing.PaymentTransaction AS paymentTransaction
        GROUP BY paymentTransaction.PaymentId
    )
    SELECT
        payment.ReservationId,
        SUM(payment.CapturedAmount) AS CapturedAmount,
        SUM(payment.RefundedAmount) AS RefundedAmount,
        SUM(COALESCE(paymentTransaction.TransactionCaptureAmount, 0)) AS TransactionCaptureAmount,
        SUM(COALESCE(paymentTransaction.TransactionRefundAmount, 0)) AS TransactionRefundAmount,
        SUM(COALESCE(paymentTransaction.TransactionCount, 0)) AS TransactionCount
    INTO #PaymentLedger
    FROM billing.Payment AS payment
    JOIN reservation.Reservation AS res
        ON res.ReservationId = payment.ReservationId
    LEFT JOIN PaymentTransactionLedger AS paymentTransaction
        ON paymentTransaction.PaymentId = payment.PaymentId
    WHERE res.ArrivalDate >= @PeriodStartDate
        AND res.ArrivalDate <= @PeriodEndDate
        AND (res.PropertyId - 1) % @PartitionCount = @PartitionNumber
    GROUP BY payment.ReservationId
    OPTION (RECOMPILE, MAXDOP 1);

    CREATE UNIQUE CLUSTERED INDEX CX_PaymentLedger_Reservation
        ON #PaymentLedger (ReservationId);

    ;WITH ReconciledPeriod AS
    (
        SELECT
        stay.PropertyId,
        stay.AccountingMonth,
        COUNT_BIG(DISTINCT stay.ReservationId) AS ReservationCount,
        SUM(stay.OccupiedNightCount) AS OccupiedNightCount,
        SUM(stay.NightlyRevenue) AS RecalculatedNightlyRevenue,
        SUM(stay.ReservationTaxAmount * stay.NightlyRevenue
            / NULLIF(stay.ReservationNightlyRevenue, 0)) AS RecalculatedTaxAmount,
        SUM(COALESCE(payment.CapturedAmount, 0) * stay.NightlyRevenue
            / NULLIF(stay.ReservationNightlyRevenue, 0)) AS PaymentCapturedAmount,
        SUM(COALESCE(payment.RefundedAmount, 0) * stay.NightlyRevenue
            / NULLIF(stay.ReservationNightlyRevenue, 0)) AS PaymentRefundedAmount,
        SUM(COALESCE(payment.TransactionCaptureAmount, 0) * stay.NightlyRevenue
            / NULLIF(stay.ReservationNightlyRevenue, 0)) AS TransactionCaptureAmount,
        SUM(COALESCE(payment.TransactionRefundAmount, 0) * stay.NightlyRevenue
            / NULLIF(stay.ReservationNightlyRevenue, 0)) AS TransactionRefundAmount,
        SUM(COALESCE(archive.ArchiveDocumentCount, 0)) AS ArchiveDocumentCount,
        SUM(COALESCE(archive.ArchiveDocumentBytes, 0)) AS ArchiveDocumentBytes,
        CHECKSUM_AGG(archive.ArchiveIntegrityChecksum) AS ArchiveIntegrityChecksum
    FROM #StayLedger AS stay
    LEFT JOIN #PaymentLedger AS payment
        ON payment.ReservationId = stay.ReservationId
    LEFT JOIN #ArchiveLedger AS archive
        ON archive.ReservationId = stay.ReservationId
    GROUP BY
        stay.PropertyId,
        stay.AccountingMonth
    ),
    SummaryPeriod AS
    (
        SELECT
            summary.PropertyId,
            DATEFROMPARTS(YEAR(summary.BusinessDate), MONTH(summary.BusinessDate), 1)
                AS AccountingMonth,
            SUM(summary.ReservationRevenue) AS SummaryReservationRevenue,
            SUM(summary.PaymentCollected) AS SummaryPaymentCollected,
            SUM(summary.RefundedAmount) AS SummaryRefundedAmount
        FROM reporting.PropertyDailySummary AS summary
        WHERE summary.BusinessDate >= @PeriodStartDate
            AND summary.BusinessDate <= @PeriodEndDate
            AND (summary.PropertyId - 1) % @PartitionCount = @PartitionNumber
        GROUP BY
            summary.PropertyId,
            DATEFROMPARTS(YEAR(summary.BusinessDate), MONTH(summary.BusinessDate), 1)
    )
    SELECT
        propertyRecord.PropertyCode,
        propertyRecord.PropertyName,
        reconciled.AccountingMonth,
        reconciled.ReservationCount,
        reconciled.OccupiedNightCount,
        reconciled.RecalculatedNightlyRevenue,
        reconciled.RecalculatedTaxAmount,
        reconciled.PaymentCapturedAmount,
        reconciled.PaymentRefundedAmount,
        reconciled.TransactionCaptureAmount,
        reconciled.TransactionRefundAmount,
        COALESCE(summary.SummaryReservationRevenue, 0) AS SummaryReservationRevenue,
        COALESCE(summary.SummaryPaymentCollected, 0) AS SummaryPaymentCollected,
        COALESCE(summary.SummaryRefundedAmount, 0) AS SummaryRefundedAmount,
        reconciled.ArchiveDocumentCount,
        reconciled.ArchiveDocumentBytes,
        reconciled.ArchiveIntegrityChecksum,
        reconciled.RecalculatedNightlyRevenue
            - COALESCE(summary.SummaryReservationRevenue, 0) AS RevenueVariance,
        reconciled.PaymentCapturedAmount
            - reconciled.TransactionCaptureAmount AS CaptureVariance,
        reconciled.PaymentRefundedAmount
            - reconciled.TransactionRefundAmount AS RefundVariance
    FROM ReconciledPeriod AS reconciled
    JOIN property.Property AS propertyRecord
        ON propertyRecord.PropertyId = reconciled.PropertyId
    LEFT JOIN SummaryPeriod AS summary
        ON summary.PropertyId = reconciled.PropertyId
        AND summary.AccountingMonth = reconciled.AccountingMonth
    ORDER BY
        reconciled.AccountingMonth,
        propertyRecord.PropertyCode
    OPTION (RECOMPILE, MAXDOP 1);
END;
GO
