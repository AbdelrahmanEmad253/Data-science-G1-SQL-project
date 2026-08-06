/* ============================================================
   STAGE 2 — INGEST INTO STAGING TABLES
   Target platform : Microsoft SQL Server (T-SQL)
   Purpose         : land the 7 source sheets 1:1, no cleaning, no typing
                      beyond VARCHAR, so the raw source is always reproducible.
   ============================================================ */

IF DB_ID('FoodDeliveryCRM') IS NULL
BEGIN
    PRINT 'Create the database once from SSMS / sqlcmd: CREATE DATABASE FoodDeliveryCRM;';
END
GO
USE FoodDeliveryCRM;
GO

IF SCHEMA_ID('staging') IS NULL EXEC('CREATE SCHEMA staging');
IF SCHEMA_ID('core')    IS NULL EXEC('CREATE SCHEMA core');
IF SCHEMA_ID('dw')      IS NULL EXEC('CREATE SCHEMA dw');     -- star schema (dims/facts)
IF SCHEMA_ID('mart')    IS NULL EXEC('CREATE SCHEMA mart');   -- analytical views
IF SCHEMA_ID('dq')      IS NULL EXEC('CREATE SCHEMA dq');     -- data-quality logs
GO

/* Every staging table mirrors the source sheet exactly: all-VARCHAR,
   no constraints, plus a load timestamp + source row number for lineage. */

DROP TABLE IF EXISTS staging.stg_customers;
CREATE TABLE staging.stg_customers (
    row_id            INT IDENTITY(1,1) PRIMARY KEY,
    customer_id       VARCHAR(20),
    customer_name     VARCHAR(200),
    city              VARCHAR(100),
    phone             VARCHAR(30),
    age_group         VARCHAR(30),
    birthdate         VARCHAR(30),
    gender            VARCHAR(40),
    created_at        VARCHAR(30),
    tier              VARCHAR(30),
    loaded_at         DATETIME2 DEFAULT SYSUTCDATETIME()
);

DROP TABLE IF EXISTS staging.stg_orders;
CREATE TABLE staging.stg_orders (
    row_id               INT IDENTITY(1,1) PRIMARY KEY,
    order_id             VARCHAR(20),
    customer_id          VARCHAR(20),
    restaurant_id        VARCHAR(20),
    order_datetime       VARCHAR(30),
    payment_mode         VARCHAR(30),
    order_status         VARCHAR(30),
    cancel_stage         VARCHAR(40),
    cancel_reason        VARCHAR(40),
    delivery_partner_id  VARCHAR(20),
    promo_id             VARCHAR(30),
    discount_amount      VARCHAR(30),
    delivery_fee         VARCHAR(30),
    loaded_at            DATETIME2 DEFAULT SYSUTCDATETIME()
);

DROP TABLE IF EXISTS staging.stg_order_items;
CREATE TABLE staging.stg_order_items (
    row_id           INT IDENTITY(1,1) PRIMARY KEY,
    order_item_id    VARCHAR(20),
    order_id         VARCHAR(20),
    item_id          VARCHAR(20),
    quantity         VARCHAR(20),
    unit_price       VARCHAR(20),
    line_total       VARCHAR(20),
    loaded_at        DATETIME2 DEFAULT SYSUTCDATETIME()
);

DROP TABLE IF EXISTS staging.stg_delivery_logs;
CREATE TABLE staging.stg_delivery_logs (
    row_id               INT IDENTITY(1,1) PRIMARY KEY,
    delivery_id          VARCHAR(20),
    order_id             VARCHAR(20),
    delivery_partner_id  VARCHAR(20),
    assigned_at          VARCHAR(30),
    picked_at            VARCHAR(30),
    delivered_at         VARCHAR(30),
    distance_km          VARCHAR(20),
    loaded_at            DATETIME2 DEFAULT SYSUTCDATETIME()
);

DROP TABLE IF EXISTS staging.stg_refunds;
CREATE TABLE staging.stg_refunds (
    row_id           INT IDENTITY(1,1) PRIMARY KEY,
    refund_id        VARCHAR(20),
    order_id         VARCHAR(20),
    refund_reason    VARCHAR(40),
    refund_type      VARCHAR(30),
    refund_amount    VARCHAR(20),
    refund_method    VARCHAR(30),
    refund_status    VARCHAR(30),
    initiated_at     VARCHAR(30),
    processed_at     VARCHAR(30),
    loaded_at        DATETIME2 DEFAULT SYSUTCDATETIME()
);

DROP TABLE IF EXISTS staging.stg_promotions;
CREATE TABLE staging.stg_promotions (
    row_id            INT IDENTITY(1,1) PRIMARY KEY,
    promo_id          VARCHAR(30),
    promo_name        VARCHAR(100),
    discount_type     VARCHAR(20),
    discount_value    VARCHAR(20),
    min_order_value   VARCHAR(20),
    valid_from        VARCHAR(30),
    valid_to          VARCHAR(30),
    is_active         VARCHAR(5),
    loaded_at         DATETIME2 DEFAULT SYSUTCDATETIME()
);

DROP TABLE IF EXISTS staging.stg_customer_reviews;
CREATE TABLE staging.stg_customer_reviews (
    row_id            INT IDENTITY(1,1) PRIMARY KEY,
    review_id         VARCHAR(20),
    order_id          VARCHAR(20),
    rating            VARCHAR(20),
    food_rating       VARCHAR(20),
    delivery_rating   VARCHAR(20),
    review_text       VARCHAR(400),
    created_at        VARCHAR(30),
    loaded_at         DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO
