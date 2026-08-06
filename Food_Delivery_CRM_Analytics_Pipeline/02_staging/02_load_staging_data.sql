/* ============================================================
   STAGE 2 — INGEST INTO STAGING TABLES (load)
   Target platform : Microsoft SQL Server (T-SQL)

   The raw sheets were exported from the workbook to UTF-8 CSV
   (one file per sheet, header row kept) into a server-accessible
   folder before running this script. Adjust the path per environment.

   NOTE: this environment (sandbox) has no live SQL Server instance,
   so this script is a template — it was executed logically in an
   equivalent Python/SQLite harness against the CSVs to validate
   correctness and produce the sample results shipped in /results.
   ============================================================ */
USE FoodDeliveryCRM;
GO

DECLARE @path NVARCHAR(400) = N'\\fileserver\staging_drop\food_delivery_crm\';

TRUNCATE TABLE staging.stg_customers;
BULK INSERT staging.stg_customers
FROM '\\fileserver\staging_drop\food_delivery_crm\customers.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a',
      CODEPAGE='65001', TABLOCK,
      KEEPNULLS);

TRUNCATE TABLE staging.stg_orders;
BULK INSERT staging.stg_orders
FROM '\\fileserver\staging_drop\food_delivery_crm\orders.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a',
      CODEPAGE='65001', TABLOCK, KEEPNULLS);

TRUNCATE TABLE staging.stg_order_items;
BULK INSERT staging.stg_order_items
FROM '\\fileserver\staging_drop\food_delivery_crm\order_items.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a',
      CODEPAGE='65001', TABLOCK, KEEPNULLS);

TRUNCATE TABLE staging.stg_delivery_logs;
BULK INSERT staging.stg_delivery_logs
FROM '\\fileserver\staging_drop\food_delivery_crm\delivery_logs.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a',
      CODEPAGE='65001', TABLOCK, KEEPNULLS);

TRUNCATE TABLE staging.stg_refunds;
BULK INSERT staging.stg_refunds
FROM '\\fileserver\staging_drop\food_delivery_crm\refunds.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a',
      CODEPAGE='65001', TABLOCK, KEEPNULLS);

TRUNCATE TABLE staging.stg_promotions;
BULK INSERT staging.stg_promotions
FROM '\\fileserver\staging_drop\food_delivery_crm\promotions.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a',
      CODEPAGE='65001', TABLOCK, KEEPNULLS);

TRUNCATE TABLE staging.stg_customer_reviews;
BULK INSERT staging.stg_customer_reviews
FROM '\\fileserver\staging_drop\food_delivery_crm\customer_reviews.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a',
      CODEPAGE='65001', TABLOCK, KEEPNULLS);
GO

/* Row-count sanity check against the known source counts */
SELECT 'stg_customers' t, COUNT(*) rows_loaded FROM staging.stg_customers
UNION ALL SELECT 'stg_orders', COUNT(*) FROM staging.stg_orders
UNION ALL SELECT 'stg_order_items', COUNT(*) FROM staging.stg_order_items
UNION ALL SELECT 'stg_delivery_logs', COUNT(*) FROM staging.stg_delivery_logs
UNION ALL SELECT 'stg_refunds', COUNT(*) FROM staging.stg_refunds
UNION ALL SELECT 'stg_promotions', COUNT(*) FROM staging.stg_promotions
UNION ALL SELECT 'stg_customer_reviews', COUNT(*) FROM staging.stg_customer_reviews;
GO
/* Expected: 101,763 / 308,254 / 610,786 / 287,938 / 13,529 / 50 / 114,058
   (header row excluded; source workbook row counts minus 1) */
