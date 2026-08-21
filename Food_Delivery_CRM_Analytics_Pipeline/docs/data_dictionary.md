# Data Dictionary — Food Delivery CRM Analytics Pipeline

## 0. Layer overview
| Layer | Schema | Purpose |
|---|---|---|
| Staging | `staging.*` | Raw, 1:1 mirror of the 7 source sheets. All `VARCHAR`, no cleaning. |
| Core (3NF) | `core.*` | Cleaned, typed, deduplicated, feature-engineered. Source of truth. |
| Star schema | `dw.*` | Denormalized `dim_*` / `fact_*` for fast analysis. |
| Analysis outputs | `results.*` | Materialized answers to the 10 business questions (Stage 5). |
| Analytical views | `mart.*` | Live, reusable views (Stage 6). |
| DQ log | `dq.*` | Audit trail of every duplicate-key resolution. |

---

## 1. Core layer — table & column reference

### core.customers  (PK: customer_id — 100,000 rows after cleaning)
| Column | Type | Description |
|---|---|---|
| customer_id | VARCHAR(20) | Natural key, e.g. `C000001` |
| customer_name | VARCHAR(200) | Full name |
| city | VARCHAR(100) | One of 5 cities: Delhi, Mumbai, Bangalore, Pune, Hyderabad |
| phone_clean | VARCHAR(20) | Normalized `+<countrycode><number>`, always 13 chars after cleaning |
| age_group | VARCHAR(10) | One of `18-24, 25-34, 35-44, 45-54, 55+` |
| birthdate | DATE | |
| gender | VARCHAR(20) | `Male`, `Female`, `Prefer not to say` |
| created_at | DATETIME2 | Account creation timestamp |
| tier | VARCHAR(10) | `casual`, `regular`, `loyal` |

### core.orders  (PK: order_id — 300,000 rows after cleaning)
| Column | Type | Description |
|---|---|---|
| order_id | VARCHAR(20) | |
| customer_id | VARCHAR(20) | FK → core.customers |
| restaurant_id | VARCHAR(20) | FK → dw.dim_restaurant (no restaurant master data exists in source) |
| order_datetime | DATETIME2 | Nullable — 4,991 raw rows had no timestamp captured |
| payment_mode | VARCHAR(10) | `card/wallet/upi/cash`; **NULL is a legitimate business state** — every `failed` order has NULL payment_mode (payment never captured) |
| order_status | VARCHAR(10) | `completed` (93.0%), `cancelled` (4.9%), `failed` (2.0%) |
| cancel_stage | VARCHAR(20) | `before_prepare/after_prepare/out_for_delivery`; NULL unless cancelled |
| cancel_reason | VARCHAR(20) | `delay/user_cancel/restaurant_issue`; NULL unless cancelled |
| delivery_partner_id | VARCHAR(20) | FK → dw.dim_delivery_partner; NULL for failed orders and cancellations before assignment |
| promo_id | VARCHAR(20) | FK → core.promotions; NULL when no promo applied (88.3% of orders) |
| discount_amount | DECIMAL(10,2) | NULL where source held sentinel `99999` (see DQ findings) |
| delivery_fee | DECIMAL(10,2) | NULL where source held sentinel `-1` |
| dq_flag_discount_sentinel | BIT | 1 if this row's discount_amount was recovered from a sentinel |
| dq_flag_fee_sentinel | BIT | 1 if this row's delivery_fee was recovered from a sentinel |

### core.order_items  (PK: order_item_id — 599,443 rows after cleaning)
| Column | Type | Description |
|---|---|---|
| order_item_id | VARCHAR(20) | |
| order_id | VARCHAR(20) | FK → core.orders |
| item_id | VARCHAR(20) | FK → dw.dim_item (no item/menu master data exists in source) |
| line_total | DECIMAL(10,2) | Treated as source-of-truth billing amount |
| quantity | INT | Recovered from `line_total / unit_price` where the raw quantity was the sentinel `0` and the division is exact; otherwise NULL |
| unit_price | DECIMAL(10,2) | Recovered from `line_total / quantity` where the raw unit_price was the sentinel `99999` and the division is exact; otherwise NULL |
| dq_flag_qty_sentinel | BIT | 1 if raw quantity was `0` |
| dq_flag_price_sentinel | BIT | 1 if raw unit_price was `99999` |

### core.delivery_logs  (PK: delivery_id — 283,998 rows after cleaning)
| Column | Type | Description |
|---|---|---|
| delivery_id | VARCHAR(20) | |
| order_id | VARCHAR(20) | FK → core.orders |
| delivery_partner_id | VARCHAR(20) | |
| assigned_at / picked_at | DATETIME2 | Always populated; assigned_at ≤ picked_at in 100% of rows (validated) |
| delivered_at | DATETIME2 | NULL when the delivery never completed (cancelled/failed order) |
| distance_km | DECIMAL(6,2) | NULL where source held sentinel `99999` |
| pickup_lag_minutes | DECIMAL | Feature: assigned_at → picked_at, minutes |
| transit_minutes | DECIMAL | Feature: picked_at → delivered_at, minutes (NULL if not delivered) |
| total_delivery_minutes | DECIMAL | Feature: assigned_at → delivered_at, minutes (NULL if not delivered) |
| dq_flag_distance_sentinel | BIT | |

### core.refunds  (PK: refund_id — 13,347 rows after cleaning)
| Column | Type | Description |
|---|---|---|
| refund_id, order_id | VARCHAR(20) | |
| refund_reason | VARCHAR(20) | `delay/user_cancel/restaurant_issue` |
| refund_type | VARCHAR(10) | `full`/`partial` |
| refund_amount | DECIMAL(10,2) | |
| refund_method | VARCHAR(10) | `wallet/upi/card/cash`; NULL = not yet resolved |
| refund_status | VARCHAR(10) | `processed/pending/failed` |
| initiated_at, processed_at | DATETIME2 | |
| resolution_minutes | DECIMAL | Feature: initiated_at → processed_at |

### core.reviews  (PK: review_id — 111,626 rows after cleaning)
| Column | Type | Description |
|---|---|---|
| review_id, order_id | VARCHAR(20) | |
| rating, food_rating | INT (1–5) | NULL where source held sentinel `99999` |
| delivery_rating | INT (1–5) | NULL where source held sentinel `-1` |
| review_text | VARCHAR(400) | |
| created_at | DATETIME2 | |

### core.promotions  (PK: promo_id — 50 rows, none dropped)
| Column | Type | Description |
|---|---|---|
| promo_id | VARCHAR(30) | |
| promo_name | VARCHAR(100) | 8 categories (Festival Offer, Bulk Order Discount, First Order Discount, Happy Hours, Weekend Deal, New User Offer, Referral Reward, Combo Saver, Loyalty Bonus, Flash Sale) |
| discount_type | VARCHAR(10) | `flat`/`percent`; NULL on 1 row (PROMO022 — see DQ findings) |
| discount_value, min_order_value | DECIMAL | |
| valid_from, valid_to | DATE | |
| is_active | BIT | |
| dq_flag_bad_id_format | BIT | 1 for `X6505` (malformed ID, never referenced by any order — kept, not dropped) |
| dq_flag_missing_discount_info | BIT | 1 for PROMO022 |

---

## 2. Star schema — dw.* dimensional model
| Table | Grain | Row count | Notes |
|---|---|---|---|
| dw.dim_date | 1 calendar day | 1,826 | 2021-01-01 → 2025-12-31 |
| dw.dim_customer | 1 customer | 100,000 | |
| dw.dim_restaurant | 1 restaurant | 50 | **ID only** — no name/cuisine/rating master data in source |
| dw.dim_delivery_partner | 1 partner | 300 | **ID only** |
| dw.dim_item | 1 menu item | 180 | **ID only**, + derived `avg_unit_price`, `times_ordered` |
| dw.dim_promotion | 1 promo code | 50 | |
| dw.fact_orders | 1 order | 300,000 | `order_total_value = order_item_value + delivery_fee - discount_amount` |
| dw.fact_order_items | 1 order line | 599,443 | |
| dw.fact_deliveries | 1 delivery attempt | 283,998 | `is_late_delivery = 1` when `total_delivery_minutes > 45` |
| dw.fact_refunds | 1 refund case | 13,347 | |
| dw.fact_reviews | 1 review | 111,626 | |

---

## 3. Data-quality findings & resolution rules (Stage 3 detail)

| # | Finding | Scope | Rows affected | Resolution |
|---|---|---|---|---|
| 1 | Injected noise tokens `@@@ / ### / !!!` appended to categorical text | `order_status`, `cancel_reason`, `promo_id`, `gender`, `age_group`, `refund_method`, `refund_status`, `refund_type`, `promotions.promo_id`, `customers.phone` | tens of thousands across columns | Stripped via `REPLACE`; values collapse back to their clean categories |
| 2 | Literal string `"None"` used instead of true NULL (after stripping its own noise suffix, e.g. `"None###"`) | `cancel_reason`, `promo_id`, `refund_method` | ~8,600 / ~8,300 / ~400 | Mapped to real NULL |
| 3 | Numeric sentinel `99999` used as an error/placeholder marker | `orders.discount_amount` (6,231), `order_items.unit_price` (12,212), `delivery_logs.distance_km` (5,801), `reviews.rating` (2,173), `reviews.food_rating` (2,296) | ~28,700 cells | Nulled + flagged; `order_items.unit_price` additionally **recovered** from `line_total / quantity` when the division is exact |
| 4 | Numeric sentinel `-1` used as an error marker | `orders.delivery_fee` (6,246), `reviews.delivery_rating` (2,248) | ~8,500 cells | Nulled + flagged |
| 5 | `order_items.quantity = 0` (invalid — no line can have zero units) | `order_items` | 12,383 | **Recovered** from `line_total / unit_price` when exact; else NULLed + flagged |
| 6 | `line_total ≠ quantity × unit_price` | `order_items` | 35,966 | Root cause was findings #3/#5 above; `line_total` treated as source of truth, the sentinel field recomputed from it |
| 7 | Exact duplicate rows | every sheet | 2,020–10,027 per sheet | Removed via `SELECT DISTINCT` |
| 8 | **Duplicate business key with one corrupted copy** (a harder pattern than #7 — same `order_id`/`customer_id`/etc. appears twice, one copy carries a sentinel or a transposed date) | `core.customers` (118 keys), `core.orders` (1,438), `core.order_items` (1,316), `core.delivery_logs` (166), `core.refunds` (7), `core.reviews` (409) | 3,454 keys, 3,460 extra rows | Kept the copy with fewest NULLs/DQ flags, tie-break first-seen; **every decision logged to `dq.duplicate_log`** for audit — this is not silently guessed |
| 9 | Malformed `promo_id` `X6505` (doesn't match `PROMO0nn` pattern) | `promotions` | 1 row | Not referenced by any order; kept with `dq_flag_bad_id_format=1` rather than dropped |
| 10 | `promotions.discount_type`/`discount_value` NULL for PROMO022 | `promotions` | 1 row | Kept with `dq_flag_missing_discount_info=1`; any promo-ROI query should filter or note this row is unusable for discount-rate math |
| 11 | Phone numbers with trailing noise (`+91XXXXXXXXXX###`) | `customers.phone` | 3,008 | Normalized to `+<digits>` only |
| 12 | `refund_reason` trailing-whitespace variant of the same value | `refunds` | ~420 | Fixed by `TRIM` |
| 13 | Birthdate day/month transposition between duplicate customer rows | `core.customers` | subset of finding #8 | Cannot be resolved from data alone — logged, not silently corrected; downstream age-based analysis should treat `current_age_years` as approximate |

**Business rules that look like data-quality issues but are not:** `payment_mode` and `delivery_partner_id` are NULL for 100% of `failed` orders (payment never captured, no delivery ever assigned) and for some `cancelled` orders depending on `cancel_stage` — this is expected system behavior, verified by cross-tabulation, and was **not** treated as missing data to impute.

---

## 4. Business rules encoded as features
- `order_total_value = order_item_value + delivery_fee − discount_amount` (fact_orders)
- `is_late_delivery = 1` when `total_delivery_minutes > 45`
- RFM `segment` (Champion / Loyal / New-Promising / At Risk / Needs Attention) — quartile scoring on Recency, Frequency, Monetary computed only over `completed` orders (see Stage 5, A3)
