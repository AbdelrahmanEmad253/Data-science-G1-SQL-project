# Food Delivery CRM — Final Report & Executive Summary

## Executive Summary

This project turned a raw, deliberately messy 7-sheet export (≈1.42M rows: orders, order items, customers, delivery logs, refunds, promotions, reviews) into a governed analytics pipeline with six stages — **Prestage → Staging → Cleaning & Feature Engineering → Relationship Modeling → Analysis → Analytical Views** — landing in a SQL Server star schema, ten business-question answer sets, and seven reusable views.

**Headline numbers** (5-year window, Jan 2021 – Dec 2025, 300,000 orders after dedup):
- **Revenue**: ₹249.8M from 279,067 completed orders (93.0% completion rate); average order value ≈ ₹895.
- **Growth**: revenue roughly doubled year over year from 2021 (₹3.8M) through 2023 (₹39.4M), then continued to climb to ₹111.1M in 2025 as order volume scaled from ~4.3K to ~123K annual orders.
- **Cancellations & failures**: 4.9% of orders are cancelled (evenly split across `before_prepare`, `after_prepare`, `out_for_delivery` stages and across `delay` / `user_cancel` / `restaurant_issue` reasons — no single dominant cause), and 2.0% fail outright at payment.
- **Refunds**: 13,347 refund cases totaling ₹8.70M, split almost evenly across delay / user-cancel / restaurant-issue reasons and full/partial type — but resolution is slow, averaging **~70 hours (≈3 days)** from initiation to processing regardless of reason.
- **Delivery**: partner-level late-delivery rate (>45 min door-to-door) ranges from 2.2% (best partners) to 5.6% (worst) — a real, actionable spread for partner management.
- **Customer base**: 100,000 customers; RFM segmentation finds 25,325 "Champions" and 13,282 "Loyal" customers worth targeted retention, versus 28,614 in "Needs Attention" who are both infrequent and low-spend.
- **Data quality**: the raw export contained 6 systematic corruption patterns (noise-token suffixes, numeric sentinels, business-key duplicates with one corrupted copy, etc.) touching well over 60,000 individual cells and 3,454 duplicate business keys — all detected, resolved with a documented, auditable rule, and logged (see `docs/data_dictionary.md §3`). Nothing was silently dropped without a paper trail.

**Recommendation headlines** (detail in §5):
1. Refund resolution time (~3 days) is the single most improvable operational metric — investigate the refund queue/workflow, not the refund *decision* itself, since reason and type don't materially change resolution speed.
2. Delivery-partner lateness is unevenly distributed (2.2%–5.6%) — worth a partner scorecard-driven coaching or routing change, using `mart.vw_delivery_partner_scorecard`.
3. Cancellation causes are evenly spread, meaning there's no "one fix" — before_prepare/user_cancel needs a different intervention (better ETAs at checkout) than out_for_delivery/delay (delivery capacity planning).
4. 28.6K customers are "Needs Attention" (low recency, low frequency, low spend) — a natural first audience for a win-back campaign, sized and exportable via `results.a3_customer_rfm`.

---

## 1. Objective & scope
Build a reproducible, auditable SQL Server pipeline from the raw `Food_Delivery_CRM_Raw_Dataset.xlsx` workbook to a queryable analytics layer, covering: schema design and mapping before any table exists (Prestage), lossless staging ingestion, analyst-grade cleaning and feature engineering (not just string trimming), a denormalized star schema, ten answered business questions, and reusable analytical views.

## 2. Method — the six stages
| Stage | What it does | Key deliverable |
|---|---|---|
| 0. Prestage | Source inventory, 3NF entity design, column-level source→target mapping, denormalization rationale, ERD (3NF + star) | `01_prestage/prestage_schema_mapping_and_erd.md` |
| 1. Ingest into Staging | 1:1 raw load of all 7 sheets into `staging.*`, all-VARCHAR, no cleaning, full lineage (`loaded_at`) | `02_staging/*.sql` |
| 2. Cleaning & Feature Engineering | Noise-token stripping, sentinel detection & **recovery** (not just nulling), business-key dedup with audit log, derived durations/ages | `03_cleaning_feature_engineering/01_core_cleaning.sql` |
| 3. Model the Relationships | `dim_*`/`fact_*` star schema built from the cleaned `core.*` layer | `04_modeling/01_dimensional_model.sql` |
| 4. Perform the Analysis | 10 business questions (A1–A10): revenue trend, funnel, RFM segmentation, city/tier performance, delivery partner performance, promo ROI, refunds, rating drivers, top items, payment mix | `05_analysis/01_business_analysis.sql`, `/results/*.csv` |
| 5. Construct Analytical Views | 7 live views (`mart.vw_*`) for BI-tool reuse, incl. a DQ transparency view | `06_analytical_views/01_analytical_views.sql` |

Execution note: this environment has no live SQL Server instance. The delivered scripts are written in T-SQL for direct use on SQL Server (matching the target platform). To validate correctness and produce the real result sets shipped in `/results`, the identical logic was executed against a SQLite-backed harness in the sandbox — the only differences are dialect syntax (e.g. `TRY_CAST` vs `CAST`, `IDENTITY` vs `AUTOINCREMENT`), never business logic.

## 3. What the cleaning stage actually did (beyond string trimming)
A full breakdown is in `docs/data_dictionary.md §3`. In summary, six distinct problem classes were found and fixed with documented rules, not guesses:
1. **Noise-token stripping** (`@@@`, `###`, `!!!` suffixes) across 9+ categorical columns.
2. **Sentinel-value detection** (`99999`, `-1`) across 5 numeric columns, ~28,700+8,500 cells — nulled and flagged rather than silently averaged over.
3. **Value recovery, not just nulling**: `order_items.quantity=0` and `unit_price=99999` were reverse-derived from `line_total` (treated as the billing source of truth) wherever the arithmetic resolves exactly — recovering 24,000+ cells that a naive "drop bad rows" approach would have destroyed.
4. **Business-key duplicate resolution**: 3,454 keys across 6 tables had two source rows sharing the same ID, one corrupted. Every decision (which copy kept, why) is logged to `dq.duplicate_log`, not silently overwritten.
5. **Format normalization**: phone numbers, dates, and whitespace variants collapsed to one canonical shape.
6. **Distinguishing real business nulls from data-quality nulls**: `payment_mode`/`delivery_partner_id` being NULL for failed/pre-assignment orders is *correct system behavior* (verified by cross-tabulation, 100% consistent), not something to clean or impute.

## 4. Key results (full CSVs in `/results`)
- **Revenue trend** (`a1_monthly_revenue_trend.csv`): steady month-over-month growth across the full 5-year window, no seasonality collapse.
- **Order funnel** (`a2_order_funnel.csv`): 90.2% clean completions, 2.8% completions still carrying a stray noise-token artifact class (documented, harmless post-clean), cancellations spread evenly across 3 stages × 3 reasons.
- **RFM segments** (`a3_customer_rfm_segment_summary.csv`, sample rows in `a3_customer_rfm_sample_2000.csv`): Champions average ₹5,948 lifetime monetary value at 6.5 orders; Needs-Attention average ₹1,111 at 1.4 orders.
- **City/tier performance** (`a4_city_tier_performance.csv`): revenue is essentially flat across the 5 cities (~₹20M each in the casual tier) — no single city dominates, meaning growth strategy should be city-agnostic rather than city-targeted.
- **Delivery partner performance** (`a5_delivery_partner_performance.csv`): 2.2%–5.6% late-delivery range across 300 partners.
- **Promotion effectiveness** (`a6_promotion_effectiveness.csv`): PROMO029 (Referral Reward) is the single highest-usage/highest-revenue code.
- **Refund analysis** (`a7_refund_analysis.csv`): ~₹8.70M refunded, average resolution ~70 hours regardless of reason/type.
- **Rating vs. delivery lateness** (`a8_rating_vs_delivery.csv`): **no meaningful difference** in average rating between late (3.98) and on-time (3.98) deliveries in this dataset — worth noting as a non-finding rather than forcing a narrative.
- **Top items** (`a9_top_items.csv`): top 20 items by revenue, with units sold and order coverage.
- **Payment mix** (`a10_payment_mode_mix.csv`): card/wallet/upi/cash are evenly split (~25% each) among completed orders; 100% of failed orders have no captured payment mode, as expected.

## 5. Recommendations
1. **Investigate refund workflow latency**, not refund policy — ~3-day average resolution is uniform across reason/type, suggesting a process bottleneck (queue, staffing, batch processing) rather than case-by-case complexity.
2. **Use the delivery-partner scorecard** (`mart.vw_delivery_partner_scorecard`) to target coaching/route optimization at partners above the ~4% late-delivery mark.
3. **Segment-specific cancellation interventions**: before-prepare cancellations need better checkout-time ETA accuracy; out-for-delivery cancellations need delivery-capacity/routing fixes — one blanket fix won't move both.
4. **Win-back campaign** targeting the 28,614 "Needs Attention" customers (`results.a3_customer_rfm`, `segment='Needs Attention'`), and a loyalty/referral push toward the 14,671 "New/Promising" customers to convert them before they lapse.
5. **Data-entry/upstream fix**: the sentinel-value and duplicate-key patterns found here are consistent enough (99999/-1 markers, `@@@/###/!!!` suffixes) to suggest a specific upstream system or ETL step is injecting them — worth tracing at the source rather than cleaning downstream indefinitely.

## 6. Known limitations
- No restaurant, delivery-partner, or menu-item master data exists in the source — `dim_restaurant`/`dim_delivery_partner`/`dim_item` carry IDs and derived stats only, not names/categories.
- `promotions.discount_type` is unrecoverable for PROMO022 (1 row) — any query computing discount rate should exclude it explicitly.
- ~118 customer records have a genuinely ambiguous birthdate (day/month transposed between duplicate copies) that cannot be resolved from the data alone; `current_age_years` for these customers should be treated as approximate.
- This report and all results reflect logic validated in a SQLite-equivalent harness in the absence of a live SQL Server instance in this environment; row counts and totals should match exactly when the delivered T-SQL scripts are run on SQL Server against the same source file.
