/* ============================================================
   STAGE 4 — MODEL THE RELATIONSHIPS (star schema)
   Target platform : Microsoft SQL Server (T-SQL)
   Builds dw.dim_* and dw.fact_* from the cleaned core.* layer.
   ============================================================ */
USE FoodDeliveryCRM;
GO

/* ---------------- dim_date ---------------- */
DROP TABLE IF EXISTS dw.dim_date;
GO
;WITH d AS (
    SELECT CAST('2021-01-01' AS DATE) AS dt
    UNION ALL
    SELECT DATEADD(DAY,1,dt) FROM d WHERE dt < '2025-12-31'
)
SELECT
    dt                                    AS date_key,
    YEAR(dt)                              AS [year],
    MONTH(dt)                             AS [month],
    DATENAME(MONTH, dt)                   AS month_name,
    DATEPART(QUARTER, dt)                 AS quarter,
    DAY(dt)                               AS day_of_month,
    DATEPART(WEEKDAY, dt)                 AS day_of_week,
    CASE WHEN DATEPART(WEEKDAY,dt) IN (1,7) THEN 1 ELSE 0 END AS is_weekend
INTO dw.dim_date
FROM d
OPTION (MAXRECURSION 2000);
GO
ALTER TABLE dw.dim_date ADD CONSTRAINT pk_dim_date PRIMARY KEY (date_key);
GO

/* ---------------- dim_customer ---------------- */
DROP TABLE IF EXISTS dw.dim_customer;
GO
SELECT
    ROW_NUMBER() OVER (ORDER BY customer_id) AS customer_key,
    customer_id, customer_name, city, phone_clean AS phone, age_group, birthdate, gender,
    tier, CAST(created_at AS DATE) AS customer_since,
    DATEDIFF(YEAR, birthdate, GETDATE()) AS current_age_years
INTO dw.dim_customer
FROM core.customers;
GO
ALTER TABLE dw.dim_customer ADD CONSTRAINT pk_dim_customer PRIMARY KEY (customer_key);
CREATE UNIQUE INDEX ix_dim_customer_bk ON dw.dim_customer(customer_id);
GO

/* ---------------- dim_restaurant (minimal - source has no master data) ---------------- */
DROP TABLE IF EXISTS dw.dim_restaurant;
GO
SELECT ROW_NUMBER() OVER (ORDER BY restaurant_id) AS restaurant_key, restaurant_id
INTO dw.dim_restaurant
FROM (SELECT DISTINCT restaurant_id FROM core.orders) x;
GO
ALTER TABLE dw.dim_restaurant ADD CONSTRAINT pk_dim_restaurant PRIMARY KEY (restaurant_key);
CREATE UNIQUE INDEX ix_dim_restaurant_bk ON dw.dim_restaurant(restaurant_id);
GO

/* ---------------- dim_delivery_partner (minimal) ---------------- */
DROP TABLE IF EXISTS dw.dim_delivery_partner;
GO
SELECT ROW_NUMBER() OVER (ORDER BY delivery_partner_id) AS partner_key, delivery_partner_id
INTO dw.dim_delivery_partner
FROM (SELECT DISTINCT delivery_partner_id FROM core.delivery_logs WHERE delivery_partner_id IS NOT NULL) x;
GO
ALTER TABLE dw.dim_delivery_partner ADD CONSTRAINT pk_dim_delivery_partner PRIMARY KEY (partner_key);
CREATE UNIQUE INDEX ix_dim_partner_bk ON dw.dim_delivery_partner(delivery_partner_id);
GO

/* ---------------- dim_item (minimal, with derived stats) ---------------- */
DROP TABLE IF EXISTS dw.dim_item;
GO
SELECT
    ROW_NUMBER() OVER (ORDER BY item_id) AS item_key, item_id,
    ROUND(AVG(unit_price),2) AS avg_unit_price,
    COUNT(*) AS times_ordered
INTO dw.dim_item
FROM core.order_items
WHERE unit_price IS NOT NULL
GROUP BY item_id;
GO
ALTER TABLE dw.dim_item ADD CONSTRAINT pk_dim_item PRIMARY KEY (item_key);
CREATE UNIQUE INDEX ix_dim_item_bk ON dw.dim_item(item_id);
GO

/* ---------------- dim_promotion ---------------- */
DROP TABLE IF EXISTS dw.dim_promotion;
GO
SELECT ROW_NUMBER() OVER (ORDER BY promo_id) AS promo_key, *
INTO dw.dim_promotion
FROM core.promotions;
GO
ALTER TABLE dw.dim_promotion ADD CONSTRAINT pk_dim_promotion PRIMARY KEY (promo_key);
CREATE UNIQUE INDEX ix_dim_promotion_bk ON dw.dim_promotion(promo_id);
GO

/* ---------------- fact_order_items ---------------- */
DROP TABLE IF EXISTS dw.fact_order_items;
GO
SELECT
    oi.order_item_id, oi.order_id, di.item_key, oi.item_id,
    oi.quantity, oi.unit_price, oi.line_total,
    oi.dq_flag_qty_sentinel, oi.dq_flag_price_sentinel
INTO dw.fact_order_items
FROM core.order_items oi
LEFT JOIN dw.dim_item di ON di.item_id = oi.item_id;
GO
ALTER TABLE dw.fact_order_items ADD CONSTRAINT pk_fact_order_items PRIMARY KEY (order_item_id);
CREATE INDEX ix_fact_order_items_order ON dw.fact_order_items(order_id);
GO

/* order-level revenue rollup used to build fact_orders */
DROP TABLE IF EXISTS dw._order_value_agg;
GO
SELECT order_id, SUM(line_total) AS order_item_value, COUNT(*) AS item_line_count, SUM(quantity) AS total_items_qty
INTO dw._order_value_agg
FROM core.order_items
GROUP BY order_id;
GO

/* ---------------- fact_orders ---------------- */
DROP TABLE IF EXISTS dw.fact_orders;
GO
SELECT
    o.order_id, dc.customer_key, dr.restaurant_key, dp.promo_key,
    CAST(o.order_datetime AS DATE) AS order_date_key, o.order_datetime,
    dpart.partner_key,
    o.payment_mode, o.order_status, o.cancel_stage, o.cancel_reason,
    ISNULL(o.discount_amount,0) AS discount_amount,
    o.delivery_fee,
    ISNULL(v.order_item_value,0) AS order_item_value,
    ISNULL(v.order_item_value,0) + ISNULL(o.delivery_fee,0) - ISNULL(o.discount_amount,0) AS order_total_value,
    v.item_line_count, v.total_items_qty,
    CASE WHEN o.order_status='completed' THEN 1 ELSE 0 END AS is_completed,
    CASE WHEN o.order_status='cancelled' THEN 1 ELSE 0 END AS is_cancelled,
    CASE WHEN o.order_status='failed'    THEN 1 ELSE 0 END AS is_failed,
    CASE WHEN o.promo_id IS NOT NULL THEN 1 ELSE 0 END AS used_promo,
    o.dq_flag_discount_sentinel, o.dq_flag_fee_sentinel
INTO dw.fact_orders
FROM core.orders o
LEFT JOIN dw.dim_customer dc          ON dc.customer_id = o.customer_id
LEFT JOIN dw.dim_restaurant dr        ON dr.restaurant_id = o.restaurant_id
LEFT JOIN dw.dim_promotion dp         ON dp.promo_id = o.promo_id
LEFT JOIN dw.dim_delivery_partner dpart ON dpart.delivery_partner_id = o.delivery_partner_id
LEFT JOIN dw._order_value_agg v       ON v.order_id = o.order_id;
GO
ALTER TABLE dw.fact_orders ADD CONSTRAINT pk_fact_orders PRIMARY KEY (order_id);
CREATE INDEX ix_fact_orders_customer ON dw.fact_orders(customer_key);
CREATE INDEX ix_fact_orders_date ON dw.fact_orders(order_date_key);
DROP TABLE dw._order_value_agg;
GO

/* ---------------- fact_deliveries ---------------- */
DROP TABLE IF EXISTS dw.fact_deliveries;
GO
SELECT
    dl.delivery_id, dl.order_id, dp.partner_key,
    dl.assigned_at, dl.picked_at, dl.delivered_at,
    dl.pickup_lag_minutes, dl.transit_minutes, dl.total_delivery_minutes,
    dl.distance_km,
    CASE WHEN dl.total_delivery_minutes > 45 THEN 1 ELSE 0 END AS is_late_delivery,
    dl.dq_flag_distance_sentinel
INTO dw.fact_deliveries
FROM core.delivery_logs dl
LEFT JOIN dw.dim_delivery_partner dp ON dp.delivery_partner_id = dl.delivery_partner_id;
GO
ALTER TABLE dw.fact_deliveries ADD CONSTRAINT pk_fact_deliveries PRIMARY KEY (delivery_id);
CREATE INDEX ix_fact_deliveries_order ON dw.fact_deliveries(order_id);
GO

/* ---------------- fact_refunds ---------------- */
DROP TABLE IF EXISTS dw.fact_refunds;
GO
SELECT refund_id, order_id, refund_reason, refund_type, refund_amount,
       refund_method, refund_status, initiated_at, processed_at, resolution_minutes
INTO dw.fact_refunds
FROM core.refunds;
GO
ALTER TABLE dw.fact_refunds ADD CONSTRAINT pk_fact_refunds PRIMARY KEY (refund_id);
CREATE INDEX ix_fact_refunds_order ON dw.fact_refunds(order_id);
GO

/* ---------------- fact_reviews ---------------- */
DROP TABLE IF EXISTS dw.fact_reviews;
GO
SELECT rv.review_id, rv.order_id, o.customer_key,
       rv.rating, rv.food_rating, rv.delivery_rating, rv.review_text, rv.created_at
INTO dw.fact_reviews
FROM core.reviews rv
LEFT JOIN dw.fact_orders o ON o.order_id = rv.order_id;
GO
ALTER TABLE dw.fact_reviews ADD CONSTRAINT pk_fact_reviews PRIMARY KEY (review_id);
CREATE INDEX ix_fact_reviews_order ON dw.fact_reviews(order_id);
GO

/* Expected fact/dim row counts (validated): dim_customer 100,000 |
   dim_restaurant 50 | dim_delivery_partner 300 | dim_item 180 |
   dim_promotion 50 | fact_orders 300,000 | fact_order_items 599,443 |
   fact_deliveries 283,998 | fact_refunds 13,347 | fact_reviews 111,626 */
