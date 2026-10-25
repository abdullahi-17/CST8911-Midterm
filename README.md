# PowerBI references and explanations:

## Data Connection
- I connected Power BI to the Azure SQL Database using the bi views instead of the raw staging tables, since these views provide the prepared data needed for analysis, including revenue, cost, and profit.

##  Query Folding
- I enabled query folding in Power Query so that supported transformations can be processed by SQL Server rather than locally, potentially improving efficiency.

##  Data Modeling
- I used one-to-many relationships between Sales and the Customers, Products, and Stores tables, with single-direction filtering. This allows the dashboard to filter sales data through related tables while avoiding unnecessary bidirectional filtering.

##  DAX Measures: 
- I used DAX to calculate revenue, profit, and profit margin. The DIVIDE() function also handles division by zero.

##  Interactive Dashboard
- I added Year and Country slicers so users can explore sales performance across different periods and locations.

## SQL validation
- I also validated the financial metrics by running SQL aggregation queries against bi.Sales. The results matched the Power BI dashboard, including total revenue of $55,755,479.59 and a profit margin of 58.58%.

## References

1. [Power Query Native Query Folding](https://learn.microsoft.com/en-us/power-query/native-query-folding)
2. [Power BI Star Schema Design](https://learn.microsoft.com/en-us/power-bi/guidance/star-schema)
3. [Power BI Model Relationships](https://learn.microsoft.com/en-us/power-bi/transform-model/desktop-relationships-understand)
4. [Power BI Slicers](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-slicers?tabs=powerbi-desktop)
5. [DAX DIVIDE Function](https://learn.microsoft.com/en-us/dax/divide-function-dax)
