SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE reservation.SearchFlexibleStayOptions
    @SearchStartDate date,
    @SearchWindowDays int = 120,
    @MinimumNights int = 1,
    @MaximumNights int = 7,
    @ResultLimit int = 250
AS
BEGIN
    SET NOCOUNT ON;

    IF @SearchWindowDays NOT BETWEEN 30 AND 180
        THROW 56001, 'SearchWindowDays must be between 30 and 180.', 1;
    IF @MinimumNights NOT BETWEEN 1 AND 14
        THROW 56002, 'MinimumNights must be between 1 and 14.', 1;
    IF @MaximumNights < @MinimumNights OR @MaximumNights > 14
        THROW 56003, 'MaximumNights must be between MinimumNights and 14.', 1;
    IF @ResultLimit NOT BETWEEN 25 AND 1000
        THROW 56004, 'ResultLimit must be between 25 and 1,000.', 1;

    DECLARE @SearchEndDate date = DATEADD(day, @SearchWindowDays, @SearchStartDate);

    DROP TABLE IF EXISTS #ArrivalDate;
    CREATE TABLE #ArrivalDate
    (
        ArrivalDate date NOT NULL PRIMARY KEY
    );

    INSERT #ArrivalDate (ArrivalDate)
    SELECT DISTINCT inventory.InventoryDate
    FROM reservation.RoomInventory AS inventory
    WHERE inventory.InventoryDate >= @SearchStartDate
        AND inventory.InventoryDate < @SearchEndDate;

    ;WITH StayLength AS
    (
        SELECT Nights
        FROM
        (
            VALUES (1), (2), (3), (4), (5), (6), (7),
                (8), (9), (10), (11), (12), (13), (14)
        ) AS lengths (Nights)
        WHERE Nights BETWEEN @MinimumNights AND @MaximumNights
    ),
    CompleteRoomStay AS
    (
        SELECT
            room.PropertyId,
            room.RoomTypeId,
            room.RoomId,
            arrival.ArrivalDate,
            stay.Nights,
            MIN(inventory.RateAmount) AS LowestNightlyRate,
            MAX(inventory.RateAmount) AS HighestNightlyRate,
            AVG(inventory.RateAmount) AS AverageNightlyRate,
            SUM(inventory.RateAmount) AS StayRate
        FROM #ArrivalDate AS arrival
        CROSS JOIN StayLength AS stay
        JOIN reservation.RoomInventory AS inventory
            ON inventory.InventoryDate >= arrival.ArrivalDate
            AND inventory.InventoryDate < DATEADD(day, stay.Nights, arrival.ArrivalDate)
        JOIN property.Room AS room
            ON room.RoomId = inventory.RoomId
        WHERE inventory.InventoryStatus = 'Available'
            AND room.RoomStatus = 'Available'
            AND DATEADD(day, stay.Nights, arrival.ArrivalDate) <= @SearchEndDate
        GROUP BY
            room.PropertyId,
            room.RoomTypeId,
            room.RoomId,
            arrival.ArrivalDate,
            stay.Nights
        HAVING COUNT(*) = stay.Nights
    ),
    FlexibleOption AS
    (
        SELECT
            completeStay.PropertyId,
            completeStay.RoomTypeId,
            completeStay.ArrivalDate,
            DATEADD(day, completeStay.Nights, completeStay.ArrivalDate) AS DepartureDate,
            completeStay.Nights,
            COUNT(*) AS AvailableRoomCount,
            MIN(completeStay.StayRate) AS LowestStayRate,
            AVG(completeStay.AverageNightlyRate) AS AverageNightlyRate,
            MAX(completeStay.HighestNightlyRate) - MIN(completeStay.LowestNightlyRate) AS RateSpread,
            STDEV(completeStay.StayRate) AS StayRateDeviation
        FROM CompleteRoomStay AS completeStay
        GROUP BY
            completeStay.PropertyId,
            completeStay.RoomTypeId,
            completeStay.ArrivalDate,
            completeStay.Nights
    ),
    RankedOption AS
    (
        SELECT
            flexible.PropertyId,
            flexible.RoomTypeId,
            flexible.ArrivalDate,
            flexible.DepartureDate,
            flexible.Nights,
            flexible.AvailableRoomCount,
            flexible.LowestStayRate,
            flexible.AverageNightlyRate,
            flexible.RateSpread,
            flexible.StayRateDeviation,
            DENSE_RANK() OVER
            (
                PARTITION BY flexible.PropertyId
                ORDER BY
                    flexible.LowestStayRate,
                    flexible.AvailableRoomCount DESC,
                    flexible.ArrivalDate
            ) AS PropertyOptionRank,
            DENSE_RANK() OVER
            (
                PARTITION BY flexible.RoomTypeId
                ORDER BY
                    flexible.LowestStayRate,
                    flexible.AvailableRoomCount DESC
            ) AS RoomTypeValueRank
        FROM FlexibleOption AS flexible
    )
    SELECT TOP (@ResultLimit)
        propertyRecord.PropertyCode,
        propertyRecord.PropertyName,
        roomType.RoomTypeCode,
        roomType.RoomTypeName,
        ranked.ArrivalDate,
        ranked.DepartureDate,
        ranked.Nights,
        ranked.AvailableRoomCount,
        ranked.LowestStayRate,
        ranked.AverageNightlyRate,
        ranked.RateSpread,
        ranked.StayRateDeviation,
        ranked.PropertyOptionRank,
        ranked.RoomTypeValueRank
    FROM RankedOption AS ranked
    JOIN property.Property AS propertyRecord
        ON propertyRecord.PropertyId = ranked.PropertyId
    JOIN property.RoomType AS roomType
        ON roomType.RoomTypeId = ranked.RoomTypeId
    ORDER BY
        ranked.PropertyOptionRank,
        ranked.RoomTypeValueRank,
        ranked.LowestStayRate,
        propertyRecord.PropertyCode
    OPTION (RECOMPILE);
END;
GO
