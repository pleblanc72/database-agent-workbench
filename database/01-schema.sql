SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF SCHEMA_ID(N'guest') IS NULL EXEC(N'CREATE SCHEMA guest AUTHORIZATION dbo;');
IF SCHEMA_ID(N'property') IS NULL EXEC(N'CREATE SCHEMA property AUTHORIZATION dbo;');
IF SCHEMA_ID(N'reservation') IS NULL EXEC(N'CREATE SCHEMA reservation AUTHORIZATION dbo;');
IF SCHEMA_ID(N'billing') IS NULL EXEC(N'CREATE SCHEMA billing AUTHORIZATION dbo;');
IF SCHEMA_ID(N'operations') IS NULL EXEC(N'CREATE SCHEMA operations AUTHORIZATION dbo;');
IF SCHEMA_ID(N'reporting') IS NULL EXEC(N'CREATE SCHEMA reporting AUTHORIZATION dbo;');
GO

CREATE TABLE guest.Guest
(
    GuestId bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_Guest PRIMARY KEY,
    GuestNumber varchar(20) NOT NULL
        CONSTRAINT UQ_Guest_GuestNumber UNIQUE,
    FirstName nvarchar(100) NOT NULL,
    LastName nvarchar(100) NOT NULL,
    EmailAddress nvarchar(320) NOT NULL,
    PhoneNumber varchar(30) NULL,
    LoyaltyTier varchar(20) NOT NULL
        CONSTRAINT DF_Guest_LoyaltyTier DEFAULT ('Member'),
    CreatedAt datetime2(3) NOT NULL
        CONSTRAINT DF_Guest_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt datetime2(3) NOT NULL
        CONSTRAINT DF_Guest_UpdatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_Guest_LoyaltyTier
        CHECK (LoyaltyTier IN ('Member', 'Silver', 'Gold', 'Platinum'))
);
GO

CREATE INDEX IX_Guest_EmailAddress
    ON guest.Guest (EmailAddress);
GO

CREATE TABLE property.Property
(
    PropertyId int IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_Property PRIMARY KEY,
    PropertyCode varchar(12) NOT NULL
        CONSTRAINT UQ_Property_PropertyCode UNIQUE,
    PropertyName nvarchar(200) NOT NULL,
    TimeZoneId varchar(100) NOT NULL,
    AddressLine1 nvarchar(200) NOT NULL,
    City nvarchar(100) NOT NULL,
    StateProvince nvarchar(100) NOT NULL,
    PostalCode varchar(20) NOT NULL,
    CountryCode char(2) NOT NULL,
    CurrencyCode char(3) NOT NULL,
    IsActive bit NOT NULL
        CONSTRAINT DF_Property_IsActive DEFAULT (1),
    OpenedOn date NOT NULL,
    CreatedAt datetime2(3) NOT NULL
        CONSTRAINT DF_Property_CreatedAt DEFAULT (SYSUTCDATETIME())
);
GO

CREATE INDEX IX_Property_ActiveLocation
    ON property.Property (IsActive, CountryCode, StateProvince)
    INCLUDE (PropertyCode, PropertyName, City);
GO

CREATE TABLE property.RoomType
(
    RoomTypeId smallint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RoomType PRIMARY KEY,
    RoomTypeCode varchar(20) NOT NULL
        CONSTRAINT UQ_RoomType_RoomTypeCode UNIQUE,
    RoomTypeName nvarchar(100) NOT NULL,
    MaximumOccupancy tinyint NOT NULL,
    BaseRate decimal(10,2) NOT NULL,
    IsActive bit NOT NULL
        CONSTRAINT DF_RoomType_IsActive DEFAULT (1),
    CONSTRAINT CK_RoomType_MaximumOccupancy CHECK (MaximumOccupancy BETWEEN 1 AND 12),
    CONSTRAINT CK_RoomType_BaseRate CHECK (BaseRate > 0)
);
GO

CREATE TABLE property.Room
(
    RoomId int IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_Room PRIMARY KEY,
    PropertyId int NOT NULL,
    RoomTypeId smallint NOT NULL,
    RoomNumber varchar(12) NOT NULL,
    FloorNumber smallint NOT NULL,
    RoomStatus varchar(20) NOT NULL
        CONSTRAINT DF_Room_RoomStatus DEFAULT ('Available'),
    IsAccessible bit NOT NULL
        CONSTRAINT DF_Room_IsAccessible DEFAULT (0),
    CreatedAt datetime2(3) NOT NULL
        CONSTRAINT DF_Room_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT FK_Room_Property
        FOREIGN KEY (PropertyId) REFERENCES property.Property (PropertyId),
    CONSTRAINT FK_Room_RoomType
        FOREIGN KEY (RoomTypeId) REFERENCES property.RoomType (RoomTypeId),
    CONSTRAINT UQ_Room_Property_RoomNumber UNIQUE (PropertyId, RoomNumber),
    CONSTRAINT CK_Room_FloorNumber CHECK (FloorNumber BETWEEN 1 AND 200),
    CONSTRAINT CK_Room_RoomStatus
        CHECK (RoomStatus IN ('Available', 'Occupied', 'Cleaning', 'Maintenance', 'OutOfService'))
);
GO

CREATE INDEX IX_Room_Property_RoomType_Status
    ON property.Room (PropertyId, RoomTypeId, RoomStatus)
    INCLUDE (RoomNumber, FloorNumber);
GO

CREATE TABLE reservation.Reservation
(
    ReservationId bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_Reservation PRIMARY KEY,
    ReservationNumber varchar(24) NOT NULL
        CONSTRAINT UQ_Reservation_ReservationNumber UNIQUE,
    GuestId bigint NOT NULL,
    PropertyId int NOT NULL,
    ReservationStatus varchar(20) NOT NULL,
    BookedAt datetime2(3) NOT NULL,
    ArrivalDate date NOT NULL,
    DepartureDate date NOT NULL,
    AdultCount tinyint NOT NULL,
    ChildCount tinyint NOT NULL
        CONSTRAINT DF_Reservation_ChildCount DEFAULT (0),
    SourceChannel varchar(20) NOT NULL,
    SpecialRequests nvarchar(500) NULL,
    CancelledAt datetime2(3) NULL,
    CreatedAt datetime2(3) NOT NULL
        CONSTRAINT DF_Reservation_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt datetime2(3) NOT NULL
        CONSTRAINT DF_Reservation_UpdatedAt DEFAULT (SYSUTCDATETIME()),
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_Reservation_Guest
        FOREIGN KEY (GuestId) REFERENCES guest.Guest (GuestId),
    CONSTRAINT FK_Reservation_Property
        FOREIGN KEY (PropertyId) REFERENCES property.Property (PropertyId),
    CONSTRAINT CK_Reservation_Status
        CHECK (ReservationStatus IN ('Pending', 'Confirmed', 'CheckedIn', 'Completed', 'Cancelled', 'NoShow')),
    CONSTRAINT CK_Reservation_Dates CHECK (DepartureDate > ArrivalDate),
    CONSTRAINT CK_Reservation_GuestCounts
        CHECK (AdultCount BETWEEN 1 AND 12 AND ChildCount BETWEEN 0 AND 12),
    CONSTRAINT CK_Reservation_SourceChannel
        CHECK (SourceChannel IN ('DirectWeb', 'MobileApp', 'PropertyDesk', 'TravelPartner', 'Corporate'))
);
GO

CREATE INDEX IX_Reservation_Guest_BookedAt
    ON reservation.Reservation (GuestId, BookedAt DESC)
    INCLUDE (ReservationNumber, PropertyId, ReservationStatus, ArrivalDate, DepartureDate);

CREATE INDEX IX_Reservation_Property_Arrival_Status
    ON reservation.Reservation (PropertyId, ArrivalDate, ReservationStatus)
    INCLUDE (DepartureDate, GuestId, ReservationNumber);
GO

CREATE TABLE reservation.ReservationRoom
(
    ReservationRoomId bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_ReservationRoom PRIMARY KEY,
    ReservationId bigint NOT NULL,
    RoomId int NOT NULL,
    RoomTypeId smallint NOT NULL,
    ArrivalDate date NOT NULL,
    DepartureDate date NOT NULL,
    NightlyRate decimal(10,2) NOT NULL,
    TaxAmount decimal(10,2) NOT NULL,
    GuestCount tinyint NOT NULL,
    CreatedAt datetime2(3) NOT NULL
        CONSTRAINT DF_ReservationRoom_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT FK_ReservationRoom_Reservation
        FOREIGN KEY (ReservationId) REFERENCES reservation.Reservation (ReservationId),
    CONSTRAINT FK_ReservationRoom_Room
        FOREIGN KEY (RoomId) REFERENCES property.Room (RoomId),
    CONSTRAINT FK_ReservationRoom_RoomType
        FOREIGN KEY (RoomTypeId) REFERENCES property.RoomType (RoomTypeId),
    CONSTRAINT UQ_ReservationRoom_Reservation_Room UNIQUE (ReservationId, RoomId),
    CONSTRAINT CK_ReservationRoom_Dates CHECK (DepartureDate > ArrivalDate),
    CONSTRAINT CK_ReservationRoom_NightlyRate CHECK (NightlyRate > 0),
    CONSTRAINT CK_ReservationRoom_TaxAmount CHECK (TaxAmount >= 0),
    CONSTRAINT CK_ReservationRoom_GuestCount CHECK (GuestCount BETWEEN 1 AND 12)
);
GO

CREATE INDEX IX_ReservationRoom_Room_Dates
    ON reservation.ReservationRoom (RoomId, ArrivalDate, DepartureDate)
    INCLUDE (ReservationId, NightlyRate);
GO

CREATE TABLE reservation.RoomInventory
(
    RoomInventoryId bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_RoomInventory PRIMARY KEY,
    RoomId int NOT NULL,
    InventoryDate date NOT NULL,
    InventoryStatus varchar(20) NOT NULL
        CONSTRAINT DF_RoomInventory_Status DEFAULT ('Available'),
    ReservationRoomId bigint NULL,
    RateAmount decimal(10,2) NOT NULL,
    UpdatedAt datetime2(3) NOT NULL
        CONSTRAINT DF_RoomInventory_UpdatedAt DEFAULT (SYSUTCDATETIME()),
    RowVersion rowversion NOT NULL,
    CONSTRAINT FK_RoomInventory_Room
        FOREIGN KEY (RoomId) REFERENCES property.Room (RoomId),
    CONSTRAINT FK_RoomInventory_ReservationRoom
        FOREIGN KEY (ReservationRoomId) REFERENCES reservation.ReservationRoom (ReservationRoomId),
    CONSTRAINT UQ_RoomInventory_Room_Date UNIQUE (RoomId, InventoryDate),
    CONSTRAINT CK_RoomInventory_Status
        CHECK (InventoryStatus IN ('Available', 'Held', 'Reserved', 'Occupied', 'OutOfService')),
    CONSTRAINT CK_RoomInventory_RateAmount CHECK (RateAmount > 0)
);
GO

CREATE INDEX IX_RoomInventory_Date_Status_Room
    ON reservation.RoomInventory (InventoryDate, InventoryStatus, RoomId)
    INCLUDE (RateAmount, ReservationRoomId);
GO

CREATE TABLE billing.Payment
(
    PaymentId bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_Payment PRIMARY KEY,
    ReservationId bigint NOT NULL,
    PaymentStatus varchar(20) NOT NULL,
    PaymentMethod varchar(20) NOT NULL,
    CurrencyCode char(3) NOT NULL,
    AuthorizedAmount decimal(12,2) NOT NULL,
    CapturedAmount decimal(12,2) NOT NULL
        CONSTRAINT DF_Payment_CapturedAmount DEFAULT (0),
    RefundedAmount decimal(12,2) NOT NULL
        CONSTRAINT DF_Payment_RefundedAmount DEFAULT (0),
    CreatedAt datetime2(3) NOT NULL
        CONSTRAINT DF_Payment_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt datetime2(3) NOT NULL
        CONSTRAINT DF_Payment_UpdatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT FK_Payment_Reservation
        FOREIGN KEY (ReservationId) REFERENCES reservation.Reservation (ReservationId),
    CONSTRAINT CK_Payment_Status
        CHECK (PaymentStatus IN ('Pending', 'Authorized', 'Captured', 'PartiallyRefunded', 'Refunded', 'Declined', 'Voided')),
    CONSTRAINT CK_Payment_Method
        CHECK (PaymentMethod IN ('Visa', 'Mastercard', 'Amex', 'DigitalWallet', 'BankTransfer')),
    CONSTRAINT CK_Payment_Amounts
        CHECK (AuthorizedAmount >= 0 AND CapturedAmount >= 0 AND RefundedAmount >= 0
            AND CapturedAmount <= AuthorizedAmount AND RefundedAmount <= CapturedAmount)
);
GO

CREATE INDEX IX_Payment_Reservation_Status
    ON billing.Payment (ReservationId, PaymentStatus)
    INCLUDE (AuthorizedAmount, CapturedAmount, RefundedAmount, CurrencyCode);
GO

CREATE TABLE billing.PaymentTransaction
(
    PaymentTransactionId bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_PaymentTransaction PRIMARY KEY,
    PaymentId bigint NOT NULL,
    TransactionType varchar(20) NOT NULL,
    TransactionStatus varchar(20) NOT NULL,
    Amount decimal(12,2) NOT NULL,
    ProcessorReference varchar(50) NOT NULL,
    ProcessedAt datetime2(3) NOT NULL,
    CONSTRAINT FK_PaymentTransaction_Payment
        FOREIGN KEY (PaymentId) REFERENCES billing.Payment (PaymentId),
    CONSTRAINT UQ_PaymentTransaction_ProcessorReference UNIQUE (ProcessorReference),
    CONSTRAINT CK_PaymentTransaction_Type
        CHECK (TransactionType IN ('Authorization', 'Capture', 'Refund', 'Void')),
    CONSTRAINT CK_PaymentTransaction_Status
        CHECK (TransactionStatus IN ('Approved', 'Declined', 'Pending')),
    CONSTRAINT CK_PaymentTransaction_Amount CHECK (Amount >= 0)
);
GO

CREATE INDEX IX_PaymentTransaction_Payment_ProcessedAt
    ON billing.PaymentTransaction (PaymentId, ProcessedAt DESC)
    INCLUDE (TransactionType, TransactionStatus, Amount);
GO

CREATE TABLE operations.CheckIn
(
    CheckInId bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_CheckIn PRIMARY KEY,
    ReservationId bigint NOT NULL,
    PropertyId int NOT NULL,
    CheckedInAt datetime2(3) NOT NULL,
    CheckedOutAt datetime2(3) NULL,
    CheckedInBy nvarchar(100) NOT NULL,
    CheckInStatus varchar(20) NOT NULL,
    CONSTRAINT FK_CheckIn_Reservation
        FOREIGN KEY (ReservationId) REFERENCES reservation.Reservation (ReservationId),
    CONSTRAINT FK_CheckIn_Property
        FOREIGN KEY (PropertyId) REFERENCES property.Property (PropertyId),
    CONSTRAINT UQ_CheckIn_Reservation UNIQUE (ReservationId),
    CONSTRAINT CK_CheckIn_Status
        CHECK (CheckInStatus IN ('InHouse', 'CheckedOut', 'EarlyDeparture')),
    CONSTRAINT CK_CheckIn_Timestamps
        CHECK (CheckedOutAt IS NULL OR CheckedOutAt >= CheckedInAt)
);
GO

CREATE INDEX IX_CheckIn_Property_CheckedInAt
    ON operations.CheckIn (PropertyId, CheckedInAt DESC)
    INCLUDE (ReservationId, CheckedOutAt, CheckInStatus);
GO

CREATE TABLE operations.HousekeepingTask
(
    HousekeepingTaskId bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_HousekeepingTask PRIMARY KEY,
    PropertyId int NOT NULL,
    RoomId int NOT NULL,
    ServiceDate date NOT NULL,
    TaskType varchar(20) NOT NULL,
    TaskStatus varchar(20) NOT NULL,
    Priority tinyint NOT NULL,
    AssignedTo nvarchar(100) NULL,
    StartedAt datetime2(3) NULL,
    CompletedAt datetime2(3) NULL,
    CreatedAt datetime2(3) NOT NULL
        CONSTRAINT DF_HousekeepingTask_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT FK_HousekeepingTask_Property
        FOREIGN KEY (PropertyId) REFERENCES property.Property (PropertyId),
    CONSTRAINT FK_HousekeepingTask_Room
        FOREIGN KEY (RoomId) REFERENCES property.Room (RoomId),
    CONSTRAINT CK_HousekeepingTask_Type
        CHECK (TaskType IN ('Turnover', 'Stayover', 'Inspection', 'DeepClean')),
    CONSTRAINT CK_HousekeepingTask_Status
        CHECK (TaskStatus IN ('Open', 'Assigned', 'InProgress', 'Completed', 'Deferred')),
    CONSTRAINT CK_HousekeepingTask_Priority CHECK (Priority BETWEEN 1 AND 5),
    CONSTRAINT CK_HousekeepingTask_Timestamps
        CHECK (CompletedAt IS NULL OR StartedAt IS NULL OR CompletedAt >= StartedAt)
);
GO

CREATE INDEX IX_HousekeepingTask_Property_Date_Status
    ON operations.HousekeepingTask (PropertyId, ServiceDate, TaskStatus)
    INCLUDE (RoomId, TaskType, Priority, AssignedTo);
GO

CREATE TABLE reporting.PropertyDailySummary
(
    PropertyDailySummaryId bigint IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_PropertyDailySummary PRIMARY KEY,
    PropertyId int NOT NULL,
    BusinessDate date NOT NULL,
    AvailableRoomCount int NOT NULL,
    OccupiedRoomCount int NOT NULL,
    ArrivalCount int NOT NULL,
    DepartureCount int NOT NULL,
    ReservationRevenue decimal(14,2) NOT NULL,
    PaymentCollected decimal(14,2) NOT NULL,
    RefundedAmount decimal(14,2) NOT NULL,
    CalculatedAt datetime2(3) NOT NULL,
    CONSTRAINT FK_PropertyDailySummary_Property
        FOREIGN KEY (PropertyId) REFERENCES property.Property (PropertyId),
    CONSTRAINT UQ_PropertyDailySummary_Property_Date UNIQUE (PropertyId, BusinessDate),
    CONSTRAINT CK_PropertyDailySummary_Counts
        CHECK (AvailableRoomCount >= 0 AND OccupiedRoomCount >= 0
            AND ArrivalCount >= 0 AND DepartureCount >= 0),
    CONSTRAINT CK_PropertyDailySummary_Amounts
        CHECK (ReservationRevenue >= 0 AND PaymentCollected >= 0 AND RefundedAmount >= 0)
);
GO

CREATE INDEX IX_PropertyDailySummary_BusinessDate
    ON reporting.PropertyDailySummary (BusinessDate, PropertyId)
    INCLUDE (OccupiedRoomCount, ReservationRevenue, PaymentCollected, RefundedAmount);
GO
