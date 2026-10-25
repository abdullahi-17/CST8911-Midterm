# Part 2 – Azure SQL Database (Georges Ngepi)

Normalization and T-SQL transformation of the **Global Electronics Retailer** dataset.

**Database:** `8911-db` on `8911-server` (Sweden Central, resource group `cst8911-midterm`)

## Files

| File | What it does |
|---|---|
| `Part2_core_normalization.sql` | Creates the `core` schema (10 normalized tables, 3NF), the procedure `core.usp_LoadNormalizedTables`, 2 views, and the checks |
| `Part2_bi_views_for_PowerBI.sql` | Creates the `bi` views for Power BI, with the same names and columns as the tables used in the dashboard |

## Data flow

```
CSV files ─► Blob Storage ─► Data Factory ─► staging.*  (Part 1)
                                               │
                         core.usp_LoadNormalizedTables  (Part 2)
                                               ▼
                         core.* (normalized) ─► bi.* views ─► Power BI (Part 3)
```

## How to run

1. Open the database in the Azure Portal → **Query editor** → **SQL authentication**.
2. Run `Part2_core_normalization.sql` **section by section** (Sections 1 to 6), in order.
3. Run `Part2_bi_views_for_PowerBI.sql` (all at once).
4. After every new pipeline run, reload the data:
   ```sql
   EXEC core.usp_LoadNormalizedTables;
   ```

## Normalized tables (`core` schema)

| Table | From | Why |
|---|---|---|
| `SalesOrder` + `OrderLine` | Sales.csv | Order date, customer, store and currency depend only on the order number (2NF) |
| `Category` + `Subcategory` + `Product` | Products.csv | Category depends on subcategory, not on product (3NF) |
| `Country` + `Customer` | Customers.csv | Continent depends on country (3NF) |
| `Store` | Stores.csv | Typed columns; Online store has NULL size |
| `Currency` + `ExchangeRate` | Exchange_Rates.csv | One rate per date and currency |
| `LoadLog` | – | One row per load: status and error message |

## Results (checked against the CSV files)

| Check | Result |
|---|---|
| Order lines | 62,884 |
| Orders | 26,326 |
| Customers | 15,266 |
| Total revenue (USD) | 55,755,479.59 |
| Total profit (USD) | 32,662,688.38 |
| Broken names after encoding fix | 0 (was 532) |

## Data quality note

`Customers.csv` is **ISO-8859-1 (Latin-1)**, not UTF-8. With the wrong encoding, 532 names were broken (for example `Frank M�ller`). The Customers dataset in Data Factory now uses ISO-8859-1.
