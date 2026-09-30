SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;

SET IDENTITY_INSERT property.RoomType ON;

MERGE property.RoomType AS target
USING
(
    VALUES
        (CONVERT(smallint, 1), 'STANDARD_KING',  N'Standard King',  2, CONVERT(decimal(10,2), 149.00), CONVERT(bit, 1)),
        (CONVERT(smallint, 2), 'STANDARD_QUEEN', N'Standard Queen', 4, CONVERT(decimal(10,2), 159.00), CONVERT(bit, 1)),
        (CONVERT(smallint, 3), 'DELUXE_KING',    N'Deluxe King',    3, CONVERT(decimal(10,2), 219.00), CONVERT(bit, 1)),
        (CONVERT(smallint, 4), 'JUNIOR_SUITE',   N'Junior Suite',   4, CONVERT(decimal(10,2), 289.00), CONVERT(bit, 1)),
        (CONVERT(smallint, 5), 'FAMILY_SUITE',   N'Family Suite',   6, CONVERT(decimal(10,2), 359.00), CONVERT(bit, 1))
) AS source (RoomTypeId, RoomTypeCode, RoomTypeName, MaximumOccupancy, BaseRate, IsActive)
ON target.RoomTypeId = source.RoomTypeId
WHEN MATCHED THEN
    UPDATE SET
        RoomTypeCode = source.RoomTypeCode,
        RoomTypeName = source.RoomTypeName,
        MaximumOccupancy = source.MaximumOccupancy,
        BaseRate = source.BaseRate,
        IsActive = source.IsActive
WHEN NOT MATCHED BY TARGET THEN
    INSERT (RoomTypeId, RoomTypeCode, RoomTypeName, MaximumOccupancy, BaseRate, IsActive)
    VALUES (source.RoomTypeId, source.RoomTypeCode, source.RoomTypeName, source.MaximumOccupancy, source.BaseRate, source.IsActive);

SET IDENTITY_INSERT property.RoomType OFF;

COMMIT TRANSACTION;
