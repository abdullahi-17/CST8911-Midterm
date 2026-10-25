IF SCHEMA_ID('core') IS NULL EXEC('CREATE SCHEMA core');

DROP VIEW      IF EXISTS core.vw_SalesDetail;
DROP VIEW      IF EXISTS core.vw_CustomerDetail;
DROP PROCEDURE IF EXISTS core.usp_LoadNormalizedTables;
DROP TABLE IF EXISTS core.OrderLine;
DROP TABLE IF EXISTS core.SalesOrder;
DROP TABLE IF EXISTS core.ExchangeRate;
DROP TABLE IF EXISTS core.Currency;
DROP TABLE IF EXISTS core.Product;
DROP TABLE IF EXISTS core.Subcategory;
DROP TABLE IF EXISTS core.Category;
DROP TABLE IF EXISTS core.Customer;
DROP TABLE IF EXISTS core.Store;
DROP TABLE IF EXISTS core.Country;
DROP TABLE IF EXISTS core.LoadLog;

/* Normalization decisions:
   1. Products repeats Category and Subcategory names on every product
      -> Category and Subcategory tables (removes a transitive dependency).
   2. Sales repeats OrderDate, DeliveryDate, Customer, Store and Currency on
      every line of the same order (partial dependency on OrderNumber)
      -> SalesOrder (one row per order) + OrderLine (one row per product).
   3. Customers repeats Continent for every customer of a country
      -> Country table (Country -> Continent).
   4. Currency codes are stored once in Currency. */

CREATE TABLE core.Country (
    CountryName NVARCHAR(50) NOT NULL CONSTRAINT PK_Country PRIMARY KEY,
    Continent   NVARCHAR(50) NULL                 -- NULL for "Online"
);

CREATE TABLE core.Customer (
    CustomerKey  INT           NOT NULL CONSTRAINT PK_Customer PRIMARY KEY,
    Gender       NVARCHAR(10)  NOT NULL,
    CustomerName NVARCHAR(100) NOT NULL,
    City         NVARCHAR(100) NOT NULL,
    StateCode    NVARCHAR(50)  NULL,
    StateName    NVARCHAR(100) NULL,
    ZipCode      NVARCHAR(20)  NULL,
    CountryName  NVARCHAR(50)  NOT NULL CONSTRAINT FK_Customer_Country REFERENCES core.Country(CountryName),
    Birthday     DATE          NULL
);

CREATE TABLE core.Store (
    StoreKey     INT           NOT NULL CONSTRAINT PK_Store PRIMARY KEY,
    CountryName  NVARCHAR(50)  NOT NULL CONSTRAINT FK_Store_Country REFERENCES core.Country(CountryName),
    StateName    NVARCHAR(100) NOT NULL,
    SquareMeters INT           NULL,              -- NULL for the Online store
    OpenDate     DATE          NOT NULL
);

CREATE TABLE core.Category (
    CategoryKey  INT           NOT NULL CONSTRAINT PK_Category PRIMARY KEY,
    CategoryName NVARCHAR(100) NOT NULL
);

CREATE TABLE core.Subcategory (
    SubcategoryKey  INT           NOT NULL CONSTRAINT PK_Subcategory PRIMARY KEY,
    SubcategoryName NVARCHAR(100) NOT NULL,
    CategoryKey     INT           NOT NULL CONSTRAINT FK_Subcategory_Category REFERENCES core.Category(CategoryKey)
);

CREATE TABLE core.Product (
    ProductKey     INT           NOT NULL CONSTRAINT PK_Product PRIMARY KEY,
    ProductName    NVARCHAR(150) NOT NULL,
    Brand          NVARCHAR(50)  NOT NULL,
    Color          NVARCHAR(30)  NOT NULL,
    UnitCostUSD    DECIMAL(10,2) NOT NULL CONSTRAINT CK_Product_Cost  CHECK (UnitCostUSD  >= 0),
    UnitPriceUSD   DECIMAL(10,2) NOT NULL CONSTRAINT CK_Product_Price CHECK (UnitPriceUSD >= 0),
    SubcategoryKey INT           NOT NULL CONSTRAINT FK_Product_Subcategory REFERENCES core.Subcategory(SubcategoryKey)
);

CREATE TABLE core.Currency (
    CurrencyCode CHAR(3) NOT NULL CONSTRAINT PK_Currency PRIMARY KEY
);

CREATE TABLE core.ExchangeRate (
    RateDate     DATE          NOT NULL,
    CurrencyCode CHAR(3)       NOT NULL CONSTRAINT FK_ExchangeRate_Currency REFERENCES core.Currency(CurrencyCode),
    Rate         DECIMAL(10,4) NOT NULL,          -- 1 USD = Rate x currency
    CONSTRAINT PK_ExchangeRate PRIMARY KEY (RateDate, CurrencyCode)
);

CREATE TABLE core.SalesOrder (
    OrderNumber  INT     NOT NULL CONSTRAINT PK_SalesOrder PRIMARY KEY,
    OrderDate    DATE    NOT NULL,
    DeliveryDate DATE    NULL,                    -- only online orders are delivered
    CustomerKey  INT     NOT NULL CONSTRAINT FK_SalesOrder_Customer REFERENCES core.Customer(CustomerKey),
    StoreKey     INT     NOT NULL CONSTRAINT FK_SalesOrder_Store    REFERENCES core.Store(StoreKey),
    CurrencyCode CHAR(3) NOT NULL CONSTRAINT FK_SalesOrder_Currency REFERENCES core.Currency(CurrencyCode),
    CONSTRAINT CK_SalesOrder_Dates CHECK (DeliveryDate IS NULL OR DeliveryDate >= OrderDate)
);

CREATE TABLE core.OrderLine (
    OrderNumber INT NOT NULL CONSTRAINT FK_OrderLine_SalesOrder REFERENCES core.SalesOrder(OrderNumber),
    LineItem    INT NOT NULL,
    ProductKey  INT NOT NULL CONSTRAINT FK_OrderLine_Product REFERENCES core.Product(ProductKey),
    Quantity    INT NOT NULL CONSTRAINT CK_OrderLine_Quantity CHECK (Quantity > 0),
    CONSTRAINT PK_OrderLine PRIMARY KEY (OrderNumber, LineItem)
);

/* Indexes on foreign keys: faster joins for Power BI */
CREATE INDEX IX_SalesOrder_OrderDate   ON core.SalesOrder (OrderDate);
CREATE INDEX IX_SalesOrder_CustomerKey ON core.SalesOrder (CustomerKey);
CREATE INDEX IX_SalesOrder_StoreKey    ON core.SalesOrder (StoreKey);
CREATE INDEX IX_OrderLine_ProductKey   ON core.OrderLine  (ProductKey);
CREATE INDEX IX_Product_Subcategory    ON core.Product    (SubcategoryKey);
CREATE INDEX IX_Customer_Country       ON core.Customer   (CountryName);

/* Load log: one row each time the procedure runs */
CREATE TABLE core.LoadLog (
    LoadID       INT IDENTITY(1,1) CONSTRAINT PK_LoadLog PRIMARY KEY,
    StartTime    DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME(),
    EndTime      DATETIME2      NULL,
    Status       NVARCHAR(20)   NOT NULL,         -- Running / Succeeded / Failed
    LinesLoaded  INT            NULL,
    ErrorMessage NVARCHAR(4000) NULL
);
GO


/* =====================================================================
   SECTION 2 – T-SQL transformation procedure (staging -> core)
   Transformations:
   - text -> INT, DATE, DECIMAL
   - dates "M/D/YYYY" -> DATE (style 101)
   - prices "$2,899.99" -> 2899.99 (remove $, commas and spaces)
   - empty text -> NULL; trim spaces
   - split Products and Sales into normalized tables
   Error handling: data checks first, then ONE transaction.
   If anything fails, everything is rolled back and the error is saved
   in core.LoadLog.
   ===================================================================== */
CREATE OR ALTER PROCEDURE core.usp_LoadNormalizedTables
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LoadID INT, @bad INT;
    INSERT INTO core.LoadLog (Status) VALUES (N'Running');
    SET @LoadID = SCOPE_IDENTITY();

    BEGIN TRY
        /* ---------- 1. Data quality checks on the staging data ---------- */
        SELECT @bad = COUNT(*) FROM staging.Sales
        WHERE TRY_CONVERT(INT, TRIM(OrderNumber)) IS NULL
           OR TRY_CONVERT(INT, TRIM(Quantity))    IS NULL
           OR TRY_CONVERT(DATE, TRIM(OrderDate), 101) IS NULL
           OR (NULLIF(TRIM(DeliveryDate), N'') IS NOT NULL
               AND TRY_CONVERT(DATE, TRIM(DeliveryDate), 101) IS NULL);
        IF @bad > 0 THROW 50001, N'staging.Sales has invalid numbers or dates.', 1;

        SELECT @bad = COUNT(*) FROM staging.Products
        WHERE TRY_CONVERT(DECIMAL(10,2), REPLACE(REPLACE(TRIM(UnitPriceUSD), N'$', N''), N',', N'')) IS NULL
           OR TRY_CONVERT(DECIMAL(10,2), REPLACE(REPLACE(TRIM(UnitCostUSD),  N'$', N''), N',', N'')) IS NULL;
        IF @bad > 0 THROW 50002, N'staging.Products has prices that cannot be converted.', 1;

        SELECT @bad = COUNT(*) FROM staging.ExchangeRates
        WHERE TRY_CONVERT(DATE, TRIM(ExchangeDate), 101) IS NULL
           OR TRY_CONVERT(DECIMAL(10,4), TRIM(ExchangeRate)) IS NULL;
        IF @bad > 0 THROW 50003, N'staging.ExchangeRates has invalid dates or rates.', 1;

        /* each order must have only ONE date, customer, store and currency */
        SELECT @bad = COUNT(*) FROM (
            SELECT OrderNumber FROM staging.Sales
            GROUP BY OrderNumber
            HAVING COUNT(DISTINCT CONCAT(OrderDate, N'|', DeliveryDate, N'|', CustomerKey,
                                         N'|', StoreKey, N'|', CurrencyCode)) > 1) x;
        IF @bad > 0 THROW 50004, N'Some orders have different header values on different lines.', 1;

        BEGIN TRANSACTION;

        /* ---------- 2. Clear the core tables (children first) ---------- */
        DELETE FROM core.OrderLine;
        DELETE FROM core.SalesOrder;
        DELETE FROM core.ExchangeRate;
        DELETE FROM core.Currency;
        DELETE FROM core.Product;
        DELETE FROM core.Subcategory;
        DELETE FROM core.Category;
        DELETE FROM core.Customer;
        DELETE FROM core.Store;
        DELETE FROM core.Country;

        /* ---------- 3. Country (from customers + stores) ---------- */
        INSERT INTO core.Country (CountryName, Continent)
        SELECT TRIM(Country), MAX(TRIM(Continent))
        FROM staging.Customers
        GROUP BY TRIM(Country);

        INSERT INTO core.Country (CountryName, Continent)        -- e.g. "Online"
        SELECT DISTINCT TRIM(s.Country), NULL
        FROM staging.Stores s
        WHERE NOT EXISTS (SELECT 1 FROM core.Country c WHERE c.CountryName = TRIM(s.Country));

        /* ---------- 4. Customer ---------- */
        INSERT INTO core.Customer (CustomerKey, Gender, CustomerName, City, StateCode, StateName,
                                   ZipCode, CountryName, Birthday)
        SELECT CONVERT(INT, TRIM(CustomerKey)),
               TRIM(Gender),
               TRIM(Name),
               TRIM(City),
               NULLIF(TRIM(StateCode), N''),
               NULLIF(TRIM(State), N''),
               NULLIF(TRIM(ZipCode), N''),
               TRIM(Country),
               TRY_CONVERT(DATE, TRIM(Birthday), 101)
        FROM staging.Customers;

        /* ---------- 5. Store ---------- */
        INSERT INTO core.Store (StoreKey, CountryName, StateName, SquareMeters, OpenDate)
        SELECT CONVERT(INT, TRIM(StoreKey)),
               TRIM(Country),
               TRIM(State),
               TRY_CONVERT(INT, NULLIF(TRIM(SquareMeters), N'')),
               CONVERT(DATE, TRIM(OpenDate), 101)
        FROM staging.Stores;

        /* ---------- 6. Category, Subcategory, Product ---------- */
        INSERT INTO core.Category (CategoryKey, CategoryName)
        SELECT DISTINCT CONVERT(INT, TRIM(CategoryKey)), TRIM(Category)
        FROM staging.Products;

        INSERT INTO core.Subcategory (SubcategoryKey, SubcategoryName, CategoryKey)
        SELECT DISTINCT CONVERT(INT, TRIM(SubcategoryKey)), TRIM(Subcategory),
                        CONVERT(INT, TRIM(CategoryKey))
        FROM staging.Products;

        INSERT INTO core.Product (ProductKey, ProductName, Brand, Color,
                                  UnitCostUSD, UnitPriceUSD, SubcategoryKey)
        SELECT CONVERT(INT, TRIM(ProductKey)),
               TRIM(ProductName),
               TRIM(Brand),
               TRIM(Color),
               CONVERT(DECIMAL(10,2), REPLACE(REPLACE(TRIM(UnitCostUSD),  N'$', N''), N',', N'')),
               CONVERT(DECIMAL(10,2), REPLACE(REPLACE(TRIM(UnitPriceUSD), N'$', N''), N',', N'')),
               CONVERT(INT, TRIM(SubcategoryKey))
        FROM staging.Products;

        /* ---------- 7. Currency and ExchangeRate ---------- */
        INSERT INTO core.Currency (CurrencyCode)
        SELECT DISTINCT TRIM(Currency) FROM staging.ExchangeRates;

        INSERT INTO core.ExchangeRate (RateDate, CurrencyCode, Rate)
        SELECT CONVERT(DATE, TRIM(ExchangeDate), 101),
               TRIM(Currency),
               CONVERT(DECIMAL(10,4), TRIM(ExchangeRate))
        FROM staging.ExchangeRates;

        /* ---------- 8. SalesOrder (one row per order) ---------- */
        INSERT INTO core.SalesOrder (OrderNumber, OrderDate, DeliveryDate, CustomerKey, StoreKey, CurrencyCode)
        SELECT CONVERT(INT, TRIM(OrderNumber)),
               MIN(CONVERT(DATE, TRIM(OrderDate), 101)),
               MIN(TRY_CONVERT(DATE, NULLIF(TRIM(DeliveryDate), N''), 101)),
               MIN(CONVERT(INT, TRIM(CustomerKey))),
               MIN(CONVERT(INT, TRIM(StoreKey))),
               MIN(TRIM(CurrencyCode))
        FROM staging.Sales
        GROUP BY CONVERT(INT, TRIM(OrderNumber));

        /* ---------- 9. OrderLine (one row per product in an order) ---------- */
        INSERT INTO core.OrderLine (OrderNumber, LineItem, ProductKey, Quantity)
        SELECT CONVERT(INT, TRIM(OrderNumber)),
               CONVERT(INT, TRIM(LineItem)),
               CONVERT(INT, TRIM(ProductKey)),
               CONVERT(INT, TRIM(Quantity))
        FROM staging.Sales;

        COMMIT TRANSACTION;

        UPDATE core.LoadLog
        SET EndTime = SYSUTCDATETIME(), Status = N'Succeeded',
            LinesLoaded = (SELECT COUNT(*) FROM core.OrderLine)
        WHERE LoadID = @LoadID;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        UPDATE core.LoadLog
        SET EndTime = SYSUTCDATETIME(), Status = N'Failed', ErrorMessage = ERROR_MESSAGE()
        WHERE LoadID = @LoadID;

        THROW;   -- send the error back (Data Factory shows the activity as Failed)
    END CATCH
END;
GO


/* =====================================================================
   SECTION 3 – View for Power BI: one row per order line
   ===================================================================== */
CREATE OR ALTER VIEW core.vw_SalesDetail
AS
SELECT
    so.OrderNumber,
    ol.LineItem,
    so.OrderDate,
    so.DeliveryDate,
    DATEDIFF(DAY, so.OrderDate, so.DeliveryDate)   AS DeliveryDays,
    CASE WHEN so.StoreKey = 0 THEN N'Online' ELSE N'In store' END AS SalesChannel,
    so.CustomerKey,
    so.StoreKey,
    st.CountryName                                 AS StoreCountry,
    ol.ProductKey,
    p.ProductName,
    p.Brand,
    sc.SubcategoryName,
    c.CategoryName,
    ol.Quantity,
    p.UnitPriceUSD,
    p.UnitCostUSD,
    ol.Quantity * p.UnitPriceUSD                   AS RevenueUSD,
    ol.Quantity * p.UnitCostUSD                    AS CostUSD,
    ol.Quantity * (p.UnitPriceUSD - p.UnitCostUSD) AS ProfitUSD,
    so.CurrencyCode,
    er.Rate                                        AS ExchangeRate,
    ol.Quantity * p.UnitPriceUSD * er.Rate         AS RevenueLocalCurrency
FROM core.OrderLine   ol
JOIN core.SalesOrder  so ON so.OrderNumber    = ol.OrderNumber
JOIN core.Store       st ON st.StoreKey       = so.StoreKey
JOIN core.Product     p  ON p.ProductKey      = ol.ProductKey
JOIN core.Subcategory sc ON sc.SubcategoryKey = p.SubcategoryKey
JOIN core.Category    c  ON c.CategoryKey     = sc.CategoryKey
LEFT JOIN core.ExchangeRate er
       ON er.RateDate = so.OrderDate AND er.CurrencyCode = so.CurrencyCode;
GO


/* =====================================================================
   SECTION 4 – View for Power BI: customers with age and continent
   ===================================================================== */
CREATE OR ALTER VIEW core.vw_CustomerDetail
AS
SELECT
    cu.CustomerKey,
    cu.CustomerName,
    cu.Gender,
    cu.City,
    cu.StateName,
    cu.CountryName,
    co.Continent,
    cu.Birthday,
    DATEDIFF(YEAR, cu.Birthday, GETDATE())
      - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, cu.Birthday, GETDATE()), cu.Birthday) > GETDATE()
             THEN 1 ELSE 0 END                     AS Age
FROM core.Customer cu
JOIN core.Country  co ON co.CountryName = cu.CountryName;
GO


/* =====================================================================
   SECTION 5 – Run the transformation
   ===================================================================== */
EXEC core.usp_LoadNormalizedTables;
GO


/* =====================================================================
   SECTION 6 – Checks (one result table)
   Expected values were calculated from the original CSV files.
   ===================================================================== */
SELECT 'core.Country'      AS CheckName, CAST(COUNT(*) AS DECIMAL(18,2)) AS Actual, CAST(9 AS DECIMAL(18,2)) AS Expected FROM core.Country
UNION ALL SELECT 'core.Customer',     COUNT(*), 15266 FROM core.Customer
UNION ALL SELECT 'core.Store',        COUNT(*),    67 FROM core.Store
UNION ALL SELECT 'core.Category',     COUNT(*),     8 FROM core.Category
UNION ALL SELECT 'core.Subcategory',  COUNT(*),    32 FROM core.Subcategory
UNION ALL SELECT 'core.Product',      COUNT(*),  2517 FROM core.Product
UNION ALL SELECT 'core.Currency',     COUNT(*),     5 FROM core.Currency
UNION ALL SELECT 'core.ExchangeRate', COUNT(*), 11215 FROM core.ExchangeRate
UNION ALL SELECT 'core.SalesOrder',   COUNT(*), 26326 FROM core.SalesOrder
UNION ALL SELECT 'core.OrderLine',    COUNT(*), 62884 FROM core.OrderLine
UNION ALL SELECT 'Total revenue USD', SUM(RevenueUSD), 55755479.59 FROM core.vw_SalesDetail
UNION ALL SELECT 'Total profit USD',  SUM(ProfitUSD),  32662688.38 FROM core.vw_SalesDetail
UNION ALL SELECT 'Lines without exchange rate', SUM(CASE WHEN ExchangeRate IS NULL THEN 1 ELSE 0 END), 0 FROM core.vw_SalesDetail
UNION ALL SELECT 'Online orders',     COUNT(*), 5580 FROM core.SalesOrder WHERE StoreKey = 0
UNION ALL SELECT 'Last load succeeded (1 = yes)', (SELECT TOP 1 CASE WHEN Status = N'Succeeded' THEN 1 ELSE 0 END FROM core.LoadLog ORDER BY LoadID DESC), 1;
