# Azure Pipeline Configuration

## Azure resource setup

- We used Azure Blob Storage, Azure Data Factory, and Azure SQL Database for the data-loading workflow. The resources were placed in the same resource group to simplify management and cleanup. We chose Sweden Central based on student subscription restraints.

## Source dataset and Blob Storage

[Source Dataset](https://github.com/DimitriKneur/Global-Electronics-Retailer-Analysis/tree/main/0_Data_Sources)

- We used the Global Electronics Retailer dataset, which contains separate files for customers, products, stores, sales, and exchange rates. We uploaded the five CSV files to a private Blob container. The data dictionary was kept as a reference for understanding the columns and creating the database tables.

## Connections and access

- We created linked services in Data Factory to connect to Blob Storage and Azure SQL Database. For Blob Storage, we used Data Factory’s managed identity and assigned the Storage Blob Data Reader role. This allowed the pipeline to read the files without using a storage account key. The SQL connection used SQL authentication.

## Staging tables

- We created five tables in a staging schema. Their columns initially used NVARCHAR so the source values could be loaded before converting dates and numbers. This also kept the original values available when investigating transformation errors.

## Data mapping and loading

- Each CSV file had its own Copy activity with explicit mappings between source headers and SQL columns. For example, `Order Number` was mapped to `OrderNumber`. Before each full load, the activity cleared its staging table using `TRUNCATE TABLE`, which prevented duplicate rows during repeated runs.

## Transformations

- Script activities ran T-SQL after the files were loaded. These scripts trimmed extra spaces, converted IDs and quantities to integers, and converted dates to the SQL `DATE` type. Product prices were cleaned by removing currency symbols and commas before conversion to decimal. Currency codes were standardized to uppercase, and blank optional values were converted to `NULL`.

## Transactions and error handling

- Each transformation used a transaction with `TRY...CATCH`. If a statement failed, the transaction rolled back and the error was returned to Data Factory. A failure path recorded the pipeline run ID, activity name, error message, and time in `dbo.PipelineErrors`. A Fail activity then kept the overall pipeline marked as failed.

## Customer encoding correction

- A group member reported that approximately 532 customer names contained broken characters. We changed the Customers source dataset encoding to **ISO-8859-1** so the CSV could be read using the intended character encoding. The corrected customer data needed to be checked after reloading and then passed to the team’s core-table load.

## Error-handling test

- We tested the Products transformation by temporarily adding an intentional error after the delete statement. The transformation failed, the logger recorded the error, and the transaction preserved the existing product records. We removed the test statement before running the pipeline again.

## Validation

- We compared the number of rows copied by Data Factory with the staging table counts and checked the transformed table counts. We also reviewed sample records to confirm that dates, prices, and customer names were loaded correctly.

# PowerBI references and explanations:

## Data Connection

- I connected Power BI to the Azure SQL Database using the bi views instead of the raw staging tables, since these views provide the prepared data needed for analysis, including revenue, cost, and profit.

## Query Folding

- I enabled query folding in Power Query so that supported transformations can be processed by SQL Server rather than locally, potentially improving efficiency.

## Data Modeling

- I used one-to-many relationships between Sales and the Customers, Products, and Stores tables, with single-direction filtering. This allows the dashboard to filter sales data through related tables while avoiding unnecessary bidirectional filtering.

## DAX Measures:

- I used DAX to calculate revenue, profit, and profit margin. The DIVIDE() function also handles division by zero.

## Interactive Dashboard

- I added Year and Country slicers so users can explore sales performance across different periods and locations.

## SQL validation

- I also validated the financial metrics by running SQL aggregation queries against bi.Sales. The results matched the Power BI dashboard, including total revenue of $55,755,479.59 and a profit margin of 58.58%.

## References

1. [Power Query Native Query Folding](https://learn.microsoft.com/en-us/power-query/native-query-folding)
2. [Power BI Star Schema Design](https://learn.microsoft.com/en-us/power-bi/guidance/star-schema)
3. [Power BI Model Relationships](https://learn.microsoft.com/en-us/power-bi/transform-model/desktop-relationships-understand)
4. [Power BI Slicers](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-slicers?tabs=powerbi-desktop)
5. [DAX DIVIDE Function](https://learn.microsoft.com/en-us/dax/divide-function-dax)
6. [Global Electronics Retailer source repository](https://github.com/DimitriKneur/Global-Electronics-Retailer-Analysis/tree/main/0_Data_Sources)
7. [Dataset Background](https://mavenanalytics.io/data-playground/global-electronics-retailer)
8. [Microsoft: Azure Blob Storage connector](https://learn.microsoft.com/en-us/azure/data-factory/connector-azure-blob-storage)
9. [Microsoft: Azure SQL Database connector](https://learn.microsoft.com/en-us/azure/data-factory/connector-azure-sql-database)
10. [Microsoft: Delimited text format](https://learn.microsoft.com/en-us/azure/data-factory/format-delimited-text)
11. [Microsoft: Schema and data type mapping](https://learn.microsoft.com/en-us/azure/data-factory/copy-activity-schema-and-type-mapping)
12. [Microsoft: Script activity](https://learn.microsoft.com/en-us/azure/data-factory/transform-data-using-script)
13. [Microsoft: Errors and conditional execution](https://learn.microsoft.com/en-us/azure/data-factory/tutorial-pipeline-failure-and-error-handling)
14. [Microsoft: TRY...CATCH](https://learn.microsoft.com/en-us/sql/t-sql/language-elements/try-catch-transact-sql)
15. [Microsoft: SET XACT_ABORT](https://learn.microsoft.com/en-us/sql/t-sql/statements/set-xact-abort-transact-sql)
