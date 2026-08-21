/* ============================================================
   STAGE 6 — CONSTRUCT ANALYTICAL VIEWS
   Target platform : Microsoft SQL Server (T-SQL)
   Live, reusable views on top of the dw.* star schema so BI tools /
   analysts never have to re-derive the joins/measures in stage 5.
   ============================================================ */
USE FoodDeliveryCRM;
GO
IF SCHEMA_ID('mart') IS NULL EXEC('CREATE SCHEMA mart');
GO

CREATE OR ALTER VIEW mart.vw_monthly_revenue AS
SELECT d.[year], d.[month], d.month_name,
    COUNT(*) AS completed_orders, SUM(f.order_total_value) AS revenue,
    AVG(f.order_total_value) AS avg_order_value
FROM dw.fact_orders f JOIN dw.dim_date d ON d.date_key = f.order_date_key
WHERE f.is_completed = 1
GROUP BY d.[year], d.[month], d.month_name;
GO

CREATE OR ALTER VIEW mart.vw_customer_360 AS
SELECT c.customer_id, c.customer_name, c.city, c.tier, c.gender, c.age_group,
    COUNT(DISTINCT o.order_id) AS total_orders,
    SUM(o.is_completed) AS completed_orders, SUM(o.is_cancelled) AS cancelled_orders,
    SUM(CASE WHEN o.is_completed=1 THEN o.order_total_value ELSE 0 END) AS lifetime_value,
    AVG(CAST(r.rating AS FLOAT)) AS avg_rating_given
FROM dw.dim_customer c
LEFT JOIN dw.fact_orders o  ON o.customer_key = c.customer_key
LEFT JOIN dw.fact_reviews r ON r.customer_key = c.customer_key
GROUP BY c.customer_id, c.customer_name, c.city, c.tier, c.gender, c.age_group;
GO

CREATE OR ALTER VIEW mart.vw_restaurant_scorecard AS
SELECT dr.restaurant_id, COUNT(*) AS total_orders, SUM(f.is_completed) AS completed,
    SUM(f.is_cancelled) AS cancelled,
    ROUND(100.0*SUM(f.is_cancelled)/COUNT(*),2) AS cancel_rate_pct,
    SUM(CASE WHEN f.is_completed=1 THEN f.order_total_value ELSE 0 END) AS revenue,
    AVG(CAST(rv.rating AS FLOAT)) AS avg_rating
FROM dw.fact_orders f
JOIN dw.dim_restaurant dr ON dr.restaurant_key = f.restaurant_key
LEFT JOIN dw.fact_reviews rv ON rv.order_id = f.order_id
GROUP BY dr.restaurant_id;
GO

CREATE OR ALTER VIEW mart.vw_delivery_partner_scorecard AS
SELECT dp.delivery_partner_id, COUNT(*) AS deliveries,
    AVG(fd.total_delivery_minutes) AS avg_delivery_minutes,
    SUM(fd.is_late_delivery) AS late_deliveries,
    ROUND(100.0*SUM(fd.is_late_delivery)/COUNT(*),2) AS pct_late,
    AVG(CAST(fr.delivery_rating AS FLOAT)) AS avg_delivery_rating
FROM dw.fact_deliveries fd
JOIN dw.dim_delivery_partner dp ON dp.partner_key = fd.partner_key
LEFT JOIN dw.fact_reviews fr ON fr.order_id = fd.order_id
WHERE fd.delivered_at IS NOT NULL
GROUP BY dp.delivery_partner_id;
GO

CREATE OR ALTER VIEW mart.vw_cancellation_reasons AS
SELECT cancel_stage, cancel_reason, COUNT(*) AS orders,
    ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM dw.fact_orders WHERE is_cancelled=1),2) AS pct_of_cancellations
FROM dw.fact_orders WHERE is_cancelled = 1
GROUP BY cancel_stage, cancel_reason;
GO

CREATE OR ALTER VIEW mart.vw_promo_effectiveness AS
SELECT dp.promo_id, dp.promo_name, COUNT(*) AS orders_used,
    SUM(f.discount_amount) AS total_discount, AVG(f.order_total_value) AS avg_order_value
FROM dw.fact_orders f JOIN dw.dim_promotion dp ON dp.promo_key = f.promo_key
WHERE f.is_completed = 1
GROUP BY dp.promo_id, dp.promo_name;
GO

/* Transparency view: every DQ rule's impact, for the data dictionary /
   for anyone auditing the pipeline. */
CREATE OR ALTER VIEW mart.vw_data_quality_summary AS
SELECT 'orders - discount sentinel (99999) recovered as NULL' AS issue, SUM(dq_flag_discount_sentinel) AS affected_rows FROM dw.fact_orders
UNION ALL SELECT 'orders - fee sentinel (-1) recovered as NULL', SUM(dq_flag_fee_sentinel) FROM dw.fact_orders
UNION ALL SELECT 'order_items - qty sentinel (0) recovered/nulled', SUM(dq_flag_qty_sentinel) FROM dw.fact_order_items
UNION ALL SELECT 'order_items - price sentinel (99999) recovered/nulled', SUM(dq_flag_price_sentinel) FROM dw.fact_order_items
UNION ALL SELECT 'delivery_logs - distance sentinel (99999) nulled', SUM(dq_flag_distance_sentinel) FROM dw.fact_deliveries
UNION ALL SELECT 'duplicate business keys resolved', COUNT(*) FROM dq.duplicate_log;
GO
