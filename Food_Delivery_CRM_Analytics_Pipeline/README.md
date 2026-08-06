# Food Delivery CRM Analytics Pipeline — Deliverable Package

Source: `Food_Delivery_CRM_Raw_Dataset.xlsx` (orders, order_items, customers, delivery_logs, refunds, promotions, customer_reviews)
Target platform: Microsoft SQL Server (T-SQL)

## Read this first
- **`docs/final_report_and_executive_summary.md`** — start here for findings & recommendations.
- **`docs/data_dictionary.md`** — every table/column, plus the full data-quality findings log.
- **`01_prestage/prestage_schema_mapping_and_erd.md`** — schema design, source→target mapping, normalization rules, and the ERD (3NF + star schema) *before* any table was built.

## Folder map (run in this order on SQL Server)
```
01_prestage/                          design docs only, no SQL to run
02_staging/
   01_create_staging_schema.sql       schemas + staging.* DDL
   02_load_staging_data.sql           BULK INSERT template
03_cleaning_feature_engineering/
   01_core_cleaning.sql               core.* — cleaning, sentinel recovery, dedup + audit log
04_modeling/
   01_dimensional_model.sql           dw.dim_* / dw.fact_* star schema
05_analysis/
   01_business_analysis.sql           A1–A10 business questions → results.*
06_analytical_views/
   01_analytical_views.sql            mart.vw_* reusable views
results/                              CSV exports of every analysis query, ready to open
docs/                                 data dictionary + final report/executive summary
```

## How the results were produced
No live SQL Server instance was available in the sandbox used to build this package. The T-SQL scripts above are the primary deliverable and are written for direct use on SQL Server. To validate the logic and generate the real numbers in `/results`, an identical pipeline (same rules, same order of operations) was executed against a SQLite-backed harness from the same source file — the only differences are dialect syntax, never business logic. Running the T-SQL scripts on an actual SQL Server instance against the same workbook should reproduce these row counts and totals exactly.

## Headline numbers
- 300,000 orders (post-dedup) / 100,000 customers / ₹249.8M completed revenue / 93.0% completion rate
- 3,454 duplicate business keys resolved and logged (`dq.duplicate_log`)
- 6 distinct data-quality problem classes found and fixed with documented rules (see data dictionary §3)

Full detail: `docs/final_report_and_executive_summary.md`.
