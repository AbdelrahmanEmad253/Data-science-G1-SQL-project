/* ============================================================
   STAGE 5 — PERFORM THE ANALYSIS
   Target platform : Microsoft SQL Server (T-SQL)
   Each block answers one business question against the dw.* star
   schema and materializes the result to results.* for reuse/export.
   Result samples for every query below ship in /results as CSV.
   ============================================================ */
USE FoodDeliveryCRM;
GO
IF SCHEMA_ID('results') IS NULL EXEC('CREATE SCHEMA results');
GO

/* A1. Monthly revenue & order volume trend (completed orders) */
DROP TABLE IF EXISTS results.a1_monthly_revenue_trend;
SELECT d.[year], d.[month], d.month_name,
    COUNT(*) AS completed_orders,
    ROUND(SUM(f.order_total_value),2) AS revenue,
    ROUND(AVG(f.order_total_value),2) AS avg_order_value
INTO results.a1_monthly_revenue_trend
FROM dw.fact_orders f JOIN dw.dim_date d ON d.date_key = f.order_date_key
WHERE f.is_completed = 1
GROUP BY d.[year], d.[month], d.month_name;
GO

/* A2. Order funnel / cancellation & failure breakdown */
DROP TABLE IF EXISTS results.a2_order_funnel;
SELECT order_status, cancel_stage, cancel_reason, COUNT(*) AS orders,
    ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM dw.fact_orders),2) AS pct_of_all_orders
INTO results.a2_order_funnel
FROM dw.fact_orders
GROUP BY order_status, cancel_stage, cancel_reason;
GO

/* A3. Customer segmentation - RFM (Recency/Frequency/Monetary quartiles) */
DROP TABLE IF EXISTS results.a3_customer_rfm;
WITH agg AS (
    SELECT customer_key,
        DATEDIFF(DAY, MAX(order_datetime), (SELECT MAX(order_datetime) FROM dw.fact_orders)) AS recency_days,
        COUNT(*) AS frequency,
        ROUND(SUM(order_total_value),2) AS monetary
    FROM dw.fact_orders WHERE is_completed = 1
    GROUP BY customer_key
),
scored AS (
    SELECT *,
        NTILE(4) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(4) OVER (ORDER BY frequency ASC)     AS f_score,
        NTILE(4) OVER (ORDER BY monetary ASC)      AS m_score
    FROM agg
)
SELECT c.customer_id, c.city, c.tier, s.recency_days, s.frequency, s.monetary,
    s.r_score, s.f_score, s.m_score, (s.r_score+s.f_score+s.m_score) AS rfm_total,
    CASE
        WHEN s.r_score>=3 AND s.f_score>=3 AND s.m_score>=3 THEN 'Champion'
        WHEN s.f_score>=3 AND s.m_score>=3 THEN 'Loyal'
        WHEN s.r_score>=3 AND s.f_score<=2 THEN 'New/Promising'
        WHEN s.r_score<=2 AND s.f_score>=3 THEN 'At Risk'
        ELSE 'Needs Attention'
    END AS segment
INTO results.a3_customer_rfm
FROM scored s JOIN dw.dim_customer c ON c.customer_key = s.customer_key;
GO

/* A4. City & tier performance */
DROP TABLE IF EXISTS results.a4_city_tier_performance;
SELECT c.city, c.tier, COUNT(DISTINCT f.customer_key) AS customers,
    COUNT(*) AS completed_orders, ROUND(SUM(f.order_total_value),2) AS revenue,
    ROUND(AVG(f.order_total_value),2) AS avg_order_value
INTO results.a4_city_tier_performance
FROM dw.fact_orders f JOIN dw.dim_customer c ON c.customer_key = f.customer_key
WHERE f.is_completed = 1
GROUP BY c.city, c.tier;
GO

/* A5. Delivery performance by partner */
DROP TABLE IF EXISTS results.a5_delivery_partner_performance;
SELECT dp.delivery_partner_id, COUNT(*) AS deliveries,
    ROUND(AVG(f.total_delivery_minutes),2) AS avg_delivery_minutes,
    ROUND(AVG(f.distance_km),2) AS avg_distance_km,
    SUM(f.is_late_delivery) AS late_deliveries,
    ROUND(100.0*SUM(f.is_late_delivery)/COUNT(*),2) AS pct_late
INTO results.a5_delivery_partner_performance
FROM dw.fact_deliveries f JOIN dw.dim_delivery_partner dp ON dp.partner_key = f.partner_key
WHERE f.delivered_at IS NOT NULL
GROUP BY dp.delivery_partner_id;
GO

/* A6. Promotion effectiveness */
DROP TABLE IF EXISTS results.a6_promotion_effectiveness;
SELECT dp.promo_id, dp.promo_name, dp.discount_type, COUNT(*) AS orders_used,
    ROUND(SUM(f.discount_amount),2) AS total_discount_given,
    ROUND(SUM(f.order_total_value),2) AS revenue_from_promo_orders,
    ROUND(AVG(f.order_total_value),2) AS avg_order_value
INTO results.a6_promotion_effectiveness
FROM dw.fact_orders f JOIN dw.dim_promotion dp ON dp.promo_key = f.promo_key
WHERE f.is_completed = 1
GROUP BY dp.promo_id, dp.promo_name, dp.discount_type;
GO

/* A7. Refund / resolution analysis */
DROP TABLE IF EXISTS results.a7_refund_analysis;
SELECT refund_reason, refund_type, refund_status, COUNT(*) AS refunds,
    ROUND(SUM(refund_amount),2) AS total_refunded,
    ROUND(AVG(resolution_minutes),1) AS avg_resolution_minutes
INTO results.a7_refund_analysis
FROM dw.fact_refunds
GROUP BY refund_reason, refund_type, refund_status;
GO

/* A8. Rating drivers - late delivery impact on satisfaction */
DROP TABLE IF EXISTS results.a8_rating_vs_delivery;
SELECT fd.is_late_delivery, ROUND(AVG(fr.rating),2) AS avg_rating,
    ROUND(AVG(fr.delivery_rating),2) AS avg_delivery_rating, COUNT(*) AS n
INTO results.a8_rating_vs_delivery
FROM dw.fact_reviews fr
JOIN dw.fact_deliveries fd ON fd.order_id = fr.order_id
WHERE fr.rating IS NOT NULL AND fd.delivered_at IS NOT NULL
GROUP BY fd.is_late_delivery;
GO

/* A9. Top-selling items by revenue */
DROP TABLE IF EXISTS results.a9_top_items;
SELECT TOP 20 di.item_id, SUM(f.quantity) AS units_sold, ROUND(SUM(f.line_total),2) AS revenue,
    COUNT(DISTINCT f.order_id) AS orders_containing_item
INTO results.a9_top_items
FROM dw.fact_order_items f JOIN dw.dim_item di ON di.item_key = f.item_key
GROUP BY di.item_id
ORDER BY revenue DESC;
GO

/* A10. Payment mode mix & correlation with failed orders */
DROP TABLE IF EXISTS results.a10_payment_mode_mix;
SELECT ISNULL(payment_mode,'(not captured / failed order)') AS payment_mode,
    order_status, COUNT(*) AS orders, ROUND(SUM(order_total_value),2) AS revenue
INTO results.a10_payment_mode_mix
FROM dw.fact_orders
GROUP BY payment_mode, order_status;
GO
