-- Run this in the Azure SQL database that will store collection data.
-- Keep customer PII only as long as your retention policy requires.

CREATE TABLE dbo.ShoppingLists (
    ListId UNIQUEIDENTIFIER NOT NULL
        CONSTRAINT DF_ShoppingLists_ListId DEFAULT NEWSEQUENTIALID(),
    SourceOrderId NVARCHAR(100) NOT NULL,
    StoreId NVARCHAR(64) NOT NULL,
    CustomerReference NVARCHAR(100) NULL,
    CustomerDisplayName NVARCHAR(120) NULL,
    DeliveryAddressJson NVARCHAR(MAX) NULL,
    CustomerNote NVARCHAR(1000) NULL,
    AllowSubstitutions BIT NOT NULL
        CONSTRAINT DF_ShoppingLists_AllowSubstitutions DEFAULT 0,
    IsPriority BIT NOT NULL
        CONSTRAINT DF_ShoppingLists_IsPriority DEFAULT 0,
    CollectionWindowStart DATETIMEOFFSET(0) NOT NULL,
    CollectionWindowEnd DATETIMEOFFSET(0) NOT NULL,
    AssignedEmployeeRef NVARCHAR(128) NULL,
    Status VARCHAR(24) NOT NULL
        CONSTRAINT DF_ShoppingLists_Status DEFAULT 'Queued',
    CurrencyCode CHAR(3) NOT NULL,
    CreatedAt DATETIMEOFFSET(0) NOT NULL
        CONSTRAINT DF_ShoppingLists_CreatedAt DEFAULT SYSUTCDATETIME(),
    UpdatedAt DATETIMEOFFSET(0) NOT NULL
        CONSTRAINT DF_ShoppingLists_UpdatedAt DEFAULT SYSUTCDATETIME(),
    Version ROWVERSION NOT NULL,
    CONSTRAINT PK_ShoppingLists PRIMARY KEY (ListId),
    CONSTRAINT UQ_ShoppingLists_SourceOrderId UNIQUE (SourceOrderId),
    CONSTRAINT CK_ShoppingLists_AddressJson
        CHECK (DeliveryAddressJson IS NULL OR ISJSON(DeliveryAddressJson) = 1),
    CONSTRAINT CK_ShoppingLists_Status
        CHECK (Status IN ('Queued', 'Picking', 'CollectionComplete', 'PaymentPending', 'Paid', 'PaymentFailed', 'Cancelled')),
    CONSTRAINT CK_ShoppingLists_CollectionWindow
        CHECK (CollectionWindowEnd >= CollectionWindowStart)
);
GO

-- Supports the employee tablet's store queue and collection-time ordering.
CREATE INDEX IX_ShoppingLists_StoreQueue
    ON dbo.ShoppingLists (StoreId, Status, CollectionWindowStart)
    INCLUDE (SourceOrderId, CustomerDisplayName, AssignedEmployeeRef, IsPriority);
GO

CREATE TABLE dbo.ShoppingListItems (
    ListItemId BIGINT IDENTITY(1,1) NOT NULL,
    ListId UNIQUEIDENTIFIER NOT NULL,
    SourceItemId NVARCHAR(100) NOT NULL,
    ProductCode NVARCHAR(100) NULL,
    ProductName NVARCHAR(200) NOT NULL,
    RequestedQuantity DECIMAL(9,3) NOT NULL,
    CollectedQuantity DECIMAL(9,3) NOT NULL
        CONSTRAINT DF_ShoppingListItems_CollectedQuantity DEFAULT 0,
    Unit NVARCHAR(24) NOT NULL,
    UnitPrice DECIMAL(12,2) NOT NULL,
    ItemStatus VARCHAR(16) NOT NULL
        CONSTRAINT DF_ShoppingListItems_Status DEFAULT 'Pending',
    SubstituteProductCode NVARCHAR(100) NULL,
    SubstituteProductName NVARCHAR(200) NULL,
    UnavailableReason NVARCHAR(300) NULL,
    Version ROWVERSION NOT NULL,
    CONSTRAINT PK_ShoppingListItems PRIMARY KEY (ListItemId),
    CONSTRAINT UQ_ShoppingListItems_SourceItem UNIQUE (ListId, SourceItemId),
    CONSTRAINT UQ_ShoppingListItems_ListAndId UNIQUE (ListId, ListItemId),
    CONSTRAINT FK_ShoppingListItems_ShoppingLists FOREIGN KEY (ListId)
        REFERENCES dbo.ShoppingLists (ListId),
    CONSTRAINT CK_ShoppingListItems_Quantity
        CHECK (RequestedQuantity > 0 AND CollectedQuantity >= 0 AND CollectedQuantity <= RequestedQuantity),
    CONSTRAINT CK_ShoppingListItems_Price CHECK (UnitPrice >= 0),
    CONSTRAINT CK_ShoppingListItems_Status
        CHECK (ItemStatus IN ('Pending', 'Collected', 'Unavailable', 'Substituted'))
);
GO

CREATE INDEX IX_ShoppingListItems_List
    ON dbo.ShoppingListItems (ListId, ListItemId)
    INCLUDE (ProductName, RequestedQuantity, CollectedQuantity, UnitPrice, ItemStatus);
GO

-- Append-only record of tablet actions. OperationId and device sequence make
-- retries safe when a tablet reconnects and replays its offline changes.
CREATE TABLE dbo.CollectionEvents (
    OperationId UNIQUEIDENTIFIER NOT NULL,
    ListId UNIQUEIDENTIFIER NOT NULL,
    ListItemId BIGINT NOT NULL,
    DeviceId NVARCHAR(128) NOT NULL,
    DeviceSequence BIGINT NOT NULL,
    EmployeeRef NVARCHAR(128) NOT NULL,
    Action VARCHAR(24) NOT NULL,
    OccurredAtClient DATETIMEOFFSET(0) NOT NULL,
    RecordedAt DATETIMEOFFSET(0) NOT NULL
        CONSTRAINT DF_CollectionEvents_RecordedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_CollectionEvents PRIMARY KEY (OperationId),
    CONSTRAINT UQ_CollectionEvents_DeviceSequence UNIQUE (DeviceId, DeviceSequence),
    CONSTRAINT FK_CollectionEvents_ListItem FOREIGN KEY (ListId, ListItemId)
        REFERENCES dbo.ShoppingListItems (ListId, ListItemId),
    CONSTRAINT CK_CollectionEvents_Action
        CHECK (Action IN ('MarkedCollected', 'MarkedUnavailable', 'Reopened')),
    CONSTRAINT CK_CollectionEvents_DeviceSequence CHECK (DeviceSequence > 0)
);
GO

CREATE INDEX IX_CollectionEvents_ListItem
    ON dbo.CollectionEvents (ListId, ListItemId, RecordedAt);
GO

-- Transactional outbox: insert the payment message in the same SQL transaction
-- that completes a list. A worker publishes pending messages and retries safely.
CREATE TABLE dbo.PaymentOutbox (
    OutboxId BIGINT IDENTITY(1,1) NOT NULL,
    ListId UNIQUEIDENTIFIER NOT NULL,
    MessageType VARCHAR(40) NOT NULL,
    PayloadJson NVARCHAR(MAX) NOT NULL,
    DeliveryStatus VARCHAR(16) NOT NULL
        CONSTRAINT DF_PaymentOutbox_Status DEFAULT 'Pending',
    AttemptCount INT NOT NULL
        CONSTRAINT DF_PaymentOutbox_AttemptCount DEFAULT 0,
    NextAttemptAt DATETIMEOFFSET(0) NOT NULL
        CONSTRAINT DF_PaymentOutbox_NextAttemptAt DEFAULT SYSUTCDATETIME(),
    CreatedAt DATETIMEOFFSET(0) NOT NULL
        CONSTRAINT DF_PaymentOutbox_CreatedAt DEFAULT SYSUTCDATETIME(),
    DeliveredAt DATETIMEOFFSET(0) NULL,
    LastError NVARCHAR(1000) NULL,
    CONSTRAINT PK_PaymentOutbox PRIMARY KEY (OutboxId),
    CONSTRAINT UQ_PaymentOutbox_ListMessage UNIQUE (ListId, MessageType),
    CONSTRAINT FK_PaymentOutbox_ShoppingLists FOREIGN KEY (ListId)
        REFERENCES dbo.ShoppingLists (ListId),
    CONSTRAINT CK_PaymentOutbox_PayloadJson CHECK (ISJSON(PayloadJson) = 1),
    CONSTRAINT CK_PaymentOutbox_Status
        CHECK (DeliveryStatus IN ('Pending', 'Sending', 'Delivered', 'Failed')),
    CONSTRAINT CK_PaymentOutbox_AttemptCount CHECK (AttemptCount >= 0)
);
GO

CREATE INDEX IX_PaymentOutbox_Ready
    ON dbo.PaymentOutbox (DeliveryStatus, NextAttemptAt, OutboxId)
    INCLUDE (ListId, MessageType, AttemptCount);
GO

-- A unique payment request ID makes result handling idempotent across Service
-- Bus redeliveries; the order status update happens in the same transaction.
CREATE TABLE dbo.PaymentResults (
    PaymentRequestId NVARCHAR(100) NOT NULL,
    SourceOrderId NVARCHAR(100) NOT NULL,
    Status VARCHAR(16) NOT NULL,
    Amount DECIMAL(12,2) NOT NULL,
    CurrencyCode CHAR(3) NOT NULL,
    TransactionReference NVARCHAR(100) NOT NULL,
    ProcessedAt DATETIMEOFFSET(0) NOT NULL,
    ReceivedAt DATETIMEOFFSET(0) NOT NULL
        CONSTRAINT DF_PaymentResults_ReceivedAt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_PaymentResults PRIMARY KEY (PaymentRequestId),
    CONSTRAINT FK_PaymentResults_ShoppingLists FOREIGN KEY (SourceOrderId)
        REFERENCES dbo.ShoppingLists (SourceOrderId),
    CONSTRAINT CK_PaymentResults_Status CHECK (Status IN ('Approved', 'Declined')),
    CONSTRAINT CK_PaymentResults_Amount CHECK (Amount >= 0)
);
GO