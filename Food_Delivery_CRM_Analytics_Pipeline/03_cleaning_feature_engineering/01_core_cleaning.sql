/* ============================================================
   STAGE 3 — CLEANING & FEATURE ENGINEERING
   Target platform : Microsoft SQL Server (T-SQL)

   This is not string-trimming only. Every rule below was derived from
   profiling the actual data (see /docs/data_dictionary.md, section
   "Data quality findings") and mirrors what a real analyst would do:
     1. Strip synthetic noise tokens injected into categorical text
        ("@@@", "###", "!!!") and literal-string "None" placeholders.
     2. Detect and null out numeric sentinel values (99999 / -1) used
        as error/placeholder markers, flagging every row affected.
     3. RECOVER data where possible instead of just nulling it:
        order_items.quantity=0 or unit_price=99999 can often be
        reverse-derived from line_total, which is treated as the
        billing-system source of truth.
     4. Normalize formats (phone numbers, dates) to one canonical shape.
     5. Resolve duplicate business keys where one copy of a row was
        corrupted (a different pattern from exact duplicate rows) by
        keeping the more complete/clean copy and logging the decision.
   ============================================================ */
USE FoodDeliveryCRM;
GO

/* ---------------------------------------------------------------
   3.1  core.promotions
   --------------------------------------------------------------- */
DROP TABLE IF EXISTS core.promotions;
GO
SELECT
    LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(promo_id,'@@@',''),'###',''),'!!!',''))) AS promo_id,
    LTRIM(RTRIM(promo_name))                                                      AS promo_name,
    LTRIM(RTRIM(discount_type))                                                   AS discount_type,
    TRY_CAST(discount_value AS DECIMAL(10,2))                                     AS discount_value,
    TRY_CAST(min_order_value AS DECIMAL(10,2))                                    AS min_order_value,
    TRY_CAST(valid_from AS DATE)                                                  AS valid_from,
    TRY_CAST(valid_to AS DATE)                                                    AS valid_to,
    CASE WHEN is_active = '1' THEN 1 ELSE 0 END                                   AS is_active,
    CASE WHEN promo_id NOT LIKE 'PROMO[0-9][0-9][0-9]'
              AND promo_id NOT LIKE 'PROMO[0-9][0-9][0-9]@@@' THEN 1 ELSE 0 END   AS dq_flag_bad_id_format,
    CASE WHEN discount_type IS NULL THEN 1 ELSE 0 END                            AS dq_flag_missing_discount_info
INTO core.promotions
FROM staging.stg_promotions;
GO
ALTER TABLE core.promotions ADD CONSTRAINT pk_core_promotions PRIMARY KEY (promo_id);
GO

/* ---------------------------------------------------------------
   3.2  core.customers  (dedup pass 1: exact-row distinct)
   --------------------------------------------------------------- */
DROP TABLE IF EXISTS core._customers_stage2;
GO
SELECT DISTINCT
    LTRIM(RTRIM(customer_id))                                                             AS customer_id,
    LTRIM(RTRIM(customer_name))                                                           AS customer_name,
    LTRIM(RTRIM(city))                                                                     AS city,
    '+' + REPLACE(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(phone)),'+',''),'@',''),'#',''),'!','') AS phone_clean,
    LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(age_group,'@@@',''),'###',''),'!!!','')))          AS age_group,
    TRY_CAST(birthdate AS DATE)                                                            AS birthdate,
    LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(gender,'@@@',''),'###',''),'!!!','')))             AS gender,
    TRY_CAST(created_at AS DATETIME2)                                                      AS created_at,
    LTRIM(RTRIM(tier))                                                                     AS tier
INTO core._customers_stage2
FROM staging.stg_customers;
GO

/* dedup pass 2: same customer_id appears twice with one row corrupted
   (e.g. transposed day/month birthdate). Keep the more complete row;
   log every resolved key for audit. */
DROP TABLE IF EXISTS dq.duplicate_log;
GO
CREATE TABLE dq.duplicate_log (
    table_name        VARCHAR(60),
    business_key       VARCHAR(60),
    key_value          VARCHAR(30),
    copies_found       INT,
    resolution_rule    VARCHAR(100),
    logged_at          DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

INSERT INTO dq.duplicate_log (table_name, business_key, key_value, copies_found, resolution_rule)
SELECT 'core.customers', 'customer_id', customer_id, COUNT(*), 'fewest_nulls_then_first_seen'
FROM core._customers_stage2 GROUP BY customer_id HAVING COUNT(*) > 1;
GO

DROP TABLE IF EXISTS core.customers;
GO
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY
                (CASE WHEN phone_clean IS NULL THEN 1 ELSE 0 END
               + CASE WHEN birthdate IS NULL THEN 1 ELSE 0 END
               + CASE WHEN gender IS NULL THEN 1 ELSE 0 END
               + CASE WHEN age_group IS NULL THEN 1 ELSE 0 END) ASC
        ) AS rn
    FROM core._customers_stage2
)
SELECT customer_id, customer_name, city, phone_clean, age_group, birthdate, gender, created_at, tier
INTO core.customers
FROM ranked WHERE rn = 1;
GO
ALTER TABLE core.customers ADD CONSTRAINT pk_core_customers PRIMARY KEY (customer_id);
DROP TABLE core._customers_stage2;
GO

/* ---------------------------------------------------------------
   3.3  core.orders
   --------------------------------------------------------------- */
DROP TABLE IF EXISTS core._orders_stage2;
GO
SELECT DISTINCT
    LTRIM(RTRIM(order_id))          AS order_id,
    LTRIM(RTRIM(customer_id))       AS customer_id,
    LTRIM(RTRIM(restaurant_id))     AS restaurant_id,
    TRY_CAST(order_datetime AS DATETIME2) AS order_datetime,
    LTRIM(RTRIM(payment_mode))      AS payment_mode,               -- NULL is legitimate (failed orders)
    LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(order_status,'@@@',''),'###',''),'!!!',''))) AS order_status,
    LTRIM(RTRIM(cancel_stage))      AS cancel_stage,
    CASE
        WHEN cancel_reason IS NULL THEN NULL
        WHEN LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(cancel_reason,'@@@',''),'###',''),'!!!',''))) = 'None' THEN NULL
        ELSE LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(cancel_reason,'@@@',''),'###',''),'!!!','')))
    END AS cancel_reason,
    LTRIM(RTRIM(delivery_partner_id)) AS delivery_partner_id,
    CASE
        WHEN promo_id IS NULL THEN NULL
        WHEN LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(promo_id,'@@@',''),'###',''),'!!!',''))) = 'None' THEN NULL
        ELSE LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(promo_id,'@@@',''),'###',''),'!!!','')))
    END AS promo_id,
    CASE WHEN TRY_CAST(discount_amount AS DECIMAL(10,2)) = 99999 THEN NULL ELSE TRY_CAST(discount_amount AS DECIMAL(10,2)) END AS discount_amount,
    CASE WHEN TRY_CAST(delivery_fee AS DECIMAL(10,2)) = -1 THEN NULL ELSE TRY_CAST(delivery_fee AS DECIMAL(10,2)) END AS delivery_fee,
    CASE WHEN TRY_CAST(discount_amount AS DECIMAL(10,2)) = 99999 THEN 1 ELSE 0 END AS dq_flag_discount_sentinel,
    CASE WHEN TRY_CAST(delivery_fee AS DECIMAL(10,2)) = -1 THEN 1 ELSE 0 END AS dq_flag_fee_sentinel
INTO core._orders_stage2
FROM staging.stg_orders;
GO

INSERT INTO dq.duplicate_log (table_name, business_key, key_value, copies_found, resolution_rule)
SELECT 'core.orders', 'order_id', order_id, COUNT(*), 'fewest_nulls_and_dq_flags_then_first_seen'
FROM core._orders_stage2 GROUP BY order_id HAVING COUNT(*) > 1;
GO

DROP TABLE IF EXISTS core.orders;
GO
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id
            ORDER BY
                (CASE WHEN order_datetime IS NULL THEN 1 ELSE 0 END
               + CASE WHEN payment_mode IS NULL THEN 1 ELSE 0 END
               + CASE WHEN discount_amount IS NULL THEN 1 ELSE 0 END
               + CASE WHEN delivery_fee IS NULL THEN 1 ELSE 0 END
               + dq_flag_discount_sentinel + dq_flag_fee_sentinel) ASC
        ) AS rn
    FROM core._orders_stage2
)
SELECT order_id, customer_id, restaurant_id, order_datetime, payment_mode, order_status,
       cancel_stage, cancel_reason, delivery_partner_id, promo_id, discount_amount, delivery_fee,
       dq_flag_discount_sentinel, dq_flag_fee_sentinel
INTO core.orders
FROM ranked WHERE rn = 1;
GO
ALTER TABLE core.orders ADD CONSTRAINT pk_core_orders PRIMARY KEY (order_id);
DROP TABLE core._orders_stage2;
GO

/* ---------------------------------------------------------------
   3.4  core.order_items  (sentinel recovery via line_total)
   --------------------------------------------------------------- */
DROP TABLE IF EXISTS core._order_items_stage2;
GO
SELECT DISTINCT
    LTRIM(RTRIM(order_item_id)) AS order_item_id,
    LTRIM(RTRIM(order_id))      AS order_id,
    LTRIM(RTRIM(item_id))       AS item_id,
    TRY_CAST(line_total AS DECIMAL(10,2)) AS line_total,
    CASE
        WHEN TRY_CAST(quantity AS INT) = 0
             AND TRY_CAST(unit_price AS DECIMAL(10,2)) NOT IN (99999)
             AND TRY_CAST(unit_price AS DECIMAL(10,2)) > 0
             AND TRY_CAST(line_total AS DECIMAL(10,2)) % TRY_CAST(unit_price AS DECIMAL(10,2)) = 0
            THEN TRY_CAST(line_total AS DECIMAL(10,2)) / TRY_CAST(unit_price AS DECIMAL(10,2))
        WHEN TRY_CAST(quantity AS INT) = 0 THEN NULL
        ELSE TRY_CAST(quantity AS INT)
    END AS quantity,
    CASE
        WHEN TRY_CAST(unit_price AS DECIMAL(10,2)) = 99999
             AND TRY_CAST(quantity AS INT) > 0
             AND TRY_CAST(line_total AS DECIMAL(10,2)) % TRY_CAST(quantity AS INT) = 0
            THEN TRY_CAST(line_total AS DECIMAL(10,2)) / TRY_CAST(quantity AS INT)
        WHEN TRY_CAST(unit_price AS DECIMAL(10,2)) = 99999 THEN NULL
        ELSE TRY_CAST(unit_price AS DECIMAL(10,2))
    END AS unit_price,
    CASE WHEN TRY_CAST(quantity AS INT) = 0 THEN 1 ELSE 0 END AS dq_flag_qty_sentinel,
    CASE WHEN TRY_CAST(unit_price AS DECIMAL(10,2)) = 99999 THEN 1 ELSE 0 END AS dq_flag_price_sentinel
INTO core._order_items_stage2
FROM staging.stg_order_items;
GO

INSERT INTO dq.duplicate_log (table_name, business_key, key_value, copies_found, resolution_rule)
SELECT 'core.order_items', 'order_item_id', order_item_id, COUNT(*), 'fewest_nulls_and_dq_flags_then_first_seen'
FROM core._order_items_stage2 GROUP BY order_item_id HAVING COUNT(*) > 1;
GO

DROP TABLE IF EXISTS core.order_items;
GO
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY order_item_id
            ORDER BY (dq_flag_qty_sentinel + dq_flag_price_sentinel
                    + CASE WHEN quantity IS NULL THEN 1 ELSE 0 END
                    + CASE WHEN unit_price IS NULL THEN 1 ELSE 0 END) ASC
        ) AS rn
    FROM core._order_items_stage2
)
SELECT order_item_id, order_id, item_id, line_total, quantity, unit_price,
       dq_flag_qty_sentinel, dq_flag_price_sentinel
INTO core.order_items
FROM ranked WHERE rn = 1;
GO
ALTER TABLE core.order_items ADD CONSTRAINT pk_core_order_items PRIMARY KEY (order_item_id);
DROP TABLE core._order_items_stage2;
GO

/* ---------------------------------------------------------------
   3.5  core.delivery_logs  (+ feature engineering: durations)
   --------------------------------------------------------------- */
DROP TABLE IF EXISTS core._delivery_logs_stage2;
GO
SELECT DISTINCT
    LTRIM(RTRIM(delivery_id))          AS delivery_id,
    LTRIM(RTRIM(order_id))             AS order_id,
    LTRIM(RTRIM(delivery_partner_id))  AS delivery_partner_id,
    TRY_CAST(assigned_at AS DATETIME2) AS assigned_at,
    TRY_CAST(picked_at AS DATETIME2)   AS picked_at,
    TRY_CAST(delivered_at AS DATETIME2) AS delivered_at,      -- NULL = never completed (cancelled/failed in flight)
    CASE WHEN TRY_CAST(distance_km AS DECIMAL(10,2)) = 99999 THEN NULL ELSE TRY_CAST(distance_km AS DECIMAL(10,2)) END AS distance_km,
    CASE WHEN TRY_CAST(distance_km AS DECIMAL(10,2)) = 99999 THEN 1 ELSE 0 END AS dq_flag_distance_sentinel
INTO core._delivery_logs_stage2
FROM staging.stg_delivery_logs;
GO

INSERT INTO dq.duplicate_log (table_name, business_key, key_value, copies_found, resolution_rule)
SELECT 'core.delivery_logs', 'delivery_id', delivery_id, COUNT(*), 'fewest_nulls_and_dq_flags_then_first_seen'
FROM core._delivery_logs_stage2 GROUP BY delivery_id HAVING COUNT(*) > 1;
GO

DROP TABLE IF EXISTS core.delivery_logs;
GO
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY delivery_id
            ORDER BY (dq_flag_distance_sentinel
                    + CASE WHEN delivered_at IS NULL THEN 1 ELSE 0 END
                    + CASE WHEN distance_km IS NULL THEN 1 ELSE 0 END) ASC
        ) AS rn
    FROM core._delivery_logs_stage2
)
SELECT delivery_id, order_id, delivery_partner_id, assigned_at, picked_at, delivered_at,
       distance_km, dq_flag_distance_sentinel,
       -- feature engineering: derived durations, minutes
       DATEDIFF(SECOND, assigned_at, picked_at) / 60.0                                    AS pickup_lag_minutes,
       CASE WHEN delivered_at IS NOT NULL THEN DATEDIFF(SECOND, picked_at, delivered_at) / 60.0 END     AS transit_minutes,
       CASE WHEN delivered_at IS NOT NULL THEN DATEDIFF(SECOND, assigned_at, delivered_at) / 60.0 END   AS total_delivery_minutes
INTO core.delivery_logs
FROM ranked WHERE rn = 1;
GO
ALTER TABLE core.delivery_logs ADD CONSTRAINT pk_core_delivery_logs PRIMARY KEY (delivery_id);
DROP TABLE core._delivery_logs_stage2;
GO

/* ---------------------------------------------------------------
   3.6  core.refunds
   --------------------------------------------------------------- */
DROP TABLE IF EXISTS core._refunds_stage2;
GO
SELECT DISTINCT
    LTRIM(RTRIM(refund_id))     AS refund_id,
    LTRIM(RTRIM(order_id))      AS order_id,
    LTRIM(RTRIM(refund_reason)) AS refund_reason,      -- trailing-space variant fixed by TRIM
    LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(refund_type,'@@@',''),'###',''),'!!!','')))   AS refund_type,
    TRY_CAST(refund_amount AS DECIMAL(10,2)) AS refund_amount,
    CASE
        WHEN refund_method IS NULL THEN NULL
        WHEN LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(refund_method,'@@@',''),'###',''),'!!!',''))) = 'None' THEN NULL
        ELSE LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(refund_method,'@@@',''),'###',''),'!!!','')))
    END AS refund_method,
    LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(refund_status,'@@@',''),'###',''),'!!!','')))  AS refund_status,
    TRY_CAST(initiated_at AS DATETIME2) AS initiated_at,
    TRY_CAST(processed_at AS DATETIME2) AS processed_at
INTO core._refunds_stage2
FROM staging.stg_refunds;
GO

INSERT INTO dq.duplicate_log (table_name, business_key, key_value, copies_found, resolution_rule)
SELECT 'core.refunds', 'refund_id', refund_id, COUNT(*), 'fewest_nulls_then_first_seen'
FROM core._refunds_stage2 GROUP BY refund_id HAVING COUNT(*) > 1;
GO

DROP TABLE IF EXISTS core.refunds;
GO
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY refund_id
            ORDER BY (CASE WHEN refund_method IS NULL THEN 1 ELSE 0 END
                    + CASE WHEN initiated_at IS NULL THEN 1 ELSE 0 END) ASC
        ) AS rn
    FROM core._refunds_stage2
)
SELECT refund_id, order_id, refund_reason, refund_type, refund_amount, refund_method,
       refund_status, initiated_at, processed_at,
       CASE WHEN initiated_at IS NOT NULL THEN DATEDIFF(SECOND, initiated_at, processed_at) / 60.0 END AS resolution_minutes
INTO core.refunds
FROM ranked WHERE rn = 1;
GO
ALTER TABLE core.refunds ADD CONSTRAINT pk_core_refunds PRIMARY KEY (refund_id);
DROP TABLE core._refunds_stage2;
GO

/* ---------------------------------------------------------------
   3.7  core.reviews
   --------------------------------------------------------------- */
DROP TABLE IF EXISTS core._reviews_stage2;
GO
SELECT DISTINCT
    LTRIM(RTRIM(review_id)) AS review_id,
    LTRIM(RTRIM(order_id))  AS order_id,
    CASE WHEN TRY_CAST(rating AS INT) = 99999 THEN NULL ELSE TRY_CAST(rating AS INT) END AS rating,
    CASE WHEN TRY_CAST(food_rating AS INT) = 99999 THEN NULL ELSE TRY_CAST(food_rating AS INT) END AS food_rating,
    CASE WHEN TRY_CAST(delivery_rating AS INT) = -1 THEN NULL ELSE TRY_CAST(delivery_rating AS INT) END AS delivery_rating,
    LTRIM(RTRIM(review_text)) AS review_text,
    TRY_CAST(created_at AS DATETIME2) AS created_at
INTO core._reviews_stage2
FROM staging.stg_customer_reviews;
GO

INSERT INTO dq.duplicate_log (table_name, business_key, key_value, copies_found, resolution_rule)
SELECT 'core.reviews', 'review_id', review_id, COUNT(*), 'fewest_nulls_then_first_seen'
FROM core._reviews_stage2 GROUP BY review_id HAVING COUNT(*) > 1;
GO

DROP TABLE IF EXISTS core.reviews;
GO
WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY review_id
            ORDER BY (CASE WHEN rating IS NULL THEN 1 ELSE 0 END
                    + CASE WHEN food_rating IS NULL THEN 1 ELSE 0 END
                    + CASE WHEN delivery_rating IS NULL THEN 1 ELSE 0 END) ASC
        ) AS rn
    FROM core._reviews_stage2
)
SELECT review_id, order_id, rating, food_rating, delivery_rating, review_text, created_at
INTO core.reviews
FROM ranked WHERE rn = 1;
GO
ALTER TABLE core.reviews ADD CONSTRAINT pk_core_reviews PRIMARY KEY (review_id);
DROP TABLE core._reviews_stage2;
GO

/* Expected post-cleaning row counts (validated in sandbox execution):
   core.customers      100,000   (101,763 raw -> 1,763 exact/near dupes removed)
   core.orders         300,000   (308,254 raw -> 8,254 exact/near dupes removed)
   core.order_items    599,443   (610,786 raw -> 11,343 exact/near dupes removed)
   core.delivery_logs  283,998   (287,938 raw -> 3,940 exact/near dupes removed)
   core.refunds         13,347   (13,529 raw  -> 182 exact/near dupes removed)
   core.reviews        111,626   (114,058 raw -> 2,432 exact/near dupes removed)
   core.promotions          50   (unchanged; two rows carry DQ flags, not dropped)         */
