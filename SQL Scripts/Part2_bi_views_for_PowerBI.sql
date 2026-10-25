IF SCHEMA_ID('bi') IS NULL EXEC('CREATE SCHEMA bi');

/* ---------- bi.Sales  (replaces staging.Sales: typed + revenue columns) ---------- */
EXEC(N'CREATE OR ALTER VIEW bi.Sales AS
SELECT so.OrderNumber,
       ol.LineItem,
       so.OrderDate,
       so.DeliveryDate,
       so.CustomerKey,
       so.StoreKey,
       ol.ProductKey,
       ol.Quantity,
       so.CurrencyCode,
       ol.Quantity * p.UnitPriceUSD                    AS RevenueUSD,
       ol.Quantity * p.UnitCostUSD                     AS CostUSD,
       ol.Quantity * (p.UnitPriceUSD - p.UnitCostUSD)  AS ProfitUSD,
       er.Rate                                         AS ExchangeRate,
       ol.Quantity * p.UnitPriceUSD * er.Rate          AS RevenueLocalCurrency
FROM core.OrderLine  ol
JOIN core.SalesOrder so ON so.OrderNumber = ol.OrderNumber
JOIN core.Product    p  ON p.ProductKey   = ol.ProductKey
LEFT JOIN core.ExchangeRate er
       ON er.RateDate = so.OrderDate AND er.CurrencyCode = so.CurrencyCode;');

/* ---------- bi.Customers  (same columns as dbo.Customers) ---------- */
EXEC(N'CREATE OR ALTER VIEW bi.Customers AS
SELECT cu.CustomerKey,
       cu.Gender,
       cu.CustomerName AS Name,
       cu.City,
       cu.StateCode,
       cu.StateName    AS State,
       cu.ZipCode,
       cu.CountryName  AS Country,
       co.Continent,
       cu.Birthday
FROM core.Customer cu
JOIN core.Country  co ON co.CountryName = cu.CountryName;');

/* ---------- bi.Products  (same columns as dbo.Products) ---------- */
EXEC(N'CREATE OR ALTER VIEW bi.Products AS
SELECT p.ProductKey,
       p.ProductName,
       p.Brand,
       p.Color,
       p.UnitCostUSD,
       p.UnitPriceUSD,
       p.SubcategoryKey,
       sc.SubcategoryName AS Subcategory,
       sc.CategoryKey,
       c.CategoryName     AS Category
FROM core.Product     p
JOIN core.Subcategory sc ON sc.SubcategoryKey = p.SubcategoryKey
JOIN core.Category    c  ON c.CategoryKey     = sc.CategoryKey;');

/* ---------- bi.Stores  (same columns as dbo.Stores) ---------- */
EXEC(N'CREATE OR ALTER VIEW bi.Stores AS
SELECT StoreKey,
       CountryName AS Country,
       StateName   AS State,
       SquareMeters,
       OpenDate
FROM core.Store;');

/* ---------- bi.ExchangeRates  (same columns as staging.ExchangeRates, typed) ---------- */
EXEC(N'CREATE OR ALTER VIEW bi.ExchangeRates AS
SELECT RateDate     AS ExchangeDate,
       CurrencyCode AS Currency,
       Rate         AS ExchangeRate
FROM core.ExchangeRate;');

/* ---------- Check: row counts and revenue ---------- */
SELECT 'bi.Sales' AS ViewName, CAST(COUNT(*) AS DECIMAL(18,2)) AS Actual, CAST(62884 AS DECIMAL(18,2)) AS Expected FROM bi.Sales
UNION ALL SELECT 'bi.Customers',     COUNT(*), 15266 FROM bi.Customers
UNION ALL SELECT 'bi.Products',      COUNT(*),  2517 FROM bi.Products
UNION ALL SELECT 'bi.Stores',        COUNT(*),    67 FROM bi.Stores
UNION ALL SELECT 'bi.ExchangeRates', COUNT(*), 11215 FROM bi.ExchangeRates
UNION ALL SELECT 'Revenue (bi.Sales)', SUM(RevenueUSD), 55755479.59 FROM bi.Sales;
