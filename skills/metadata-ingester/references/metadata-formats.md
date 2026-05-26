# Metadata File Format Conventions

A reference for the column-header patterns and structures you'll see in real-world metadata folders. Use this when a CSV doesn't have an obvious column layout.

## Source-to-target mapping spreadsheets

The most common metadata artifact in a migration project. Single source of truth for "where did each legacy column go in the new model?"

### Typical column headers (any subset)

| Header (case-insensitive variants) | Maps to bundle field |
| --- | --- |
| `source_database`, `source_db`, `legacy_db` | Legacy database name |
| `source_schema`, `legacy_schema`, `src_schema` | Legacy schema |
| `source_table`, `legacy_table`, `src_table`, `from_table` | Legacy table |
| `source_column`, `legacy_column`, `src_column`, `from_column` | Legacy column |
| `target_database`, `new_db` | New database (often `cstone_biz` or a similar canonical name) |
| `target_schema`, `new_schema`, `dest_schema` | New schema |
| `target_table`, `new_table`, `dest_table`, `to_table`, `fact_table`, `dim_table` | New table (fact or dim) |
| `target_column`, `new_column`, `dest_column`, `to_column` | New column |
| `transformation`, `transform`, `derivation`, `logic`, `formula` | Transformation expression |
| `data_type`, `target_type`, `new_type` | Target column type |
| `nullable`, `is_nullable`, `not_null` | Nullability |
| `is_pii`, `pii`, `sensitivity`, `classification` | Sensitivity flag |
| `notes`, `comment`, `description` | Free-text notes |

### Reading rules

- A row with `target_table` matching a fact-table pattern (often prefixed `fact_` or suffixed `_f`) → goes in the fact catalog with the column-level details.
- A row with `target_table` matching a dim pattern (often `dim_` or `_d`) → goes in the dim catalog.
- Multiple rows for the same `target_table` → aggregate columns into that table's row in the catalog.
- If `transformation` is empty or `1:1` / `direct` → simple rename / cast.
- If `transformation` contains a CASE / IF / coalesce expression → preserve verbatim for the converter to consume.

## Fact catalog CSVs

### Typical column headers

| Header variants | Bundle field |
| --- | --- |
| `fact_name`, `fact_table`, `table_name` | Fact name |
| `grain`, `granularity`, `level` | Grain (one row per ...) |
| `measure`, `measures`, `additive`, `semi_additive`, `non_additive` | Measure list (sometimes one column per measure, sometimes comma-separated) |
| `foreign_keys`, `fks`, `dim_keys` | List of foreign keys to dimensions |
| `source_system`, `system_of_record`, `sor` | Originating system |
| `refresh_frequency`, `slo`, `freshness` | How often it must refresh |

If grain isn't explicit, try to infer from the source-to-target mapping (the legacy table the fact is sourced from often hints at grain).

## Dimension catalog CSVs

### Typical column headers

| Header variants | Bundle field |
| --- | --- |
| `dim_name`, `dimension_name`, `table_name` | Dim name |
| `business_key`, `bk`, `natural_key`, `nk`, `source_key` | Business key column |
| `surrogate_key`, `sk`, `surr_key` | Surrogate key column |
| `scd_type`, `slowly_changing_type`, `history_type` | SCD type (0, 1, 2, 3, or 6) |
| `attributes`, `dim_attributes` | List of attribute columns |
| `effective_date`, `start_date`, `valid_from` | SCD2 effective-date column |
| `end_date`, `expiry_date`, `valid_to` | SCD2 expiry column |
| `current_flag`, `is_current`, `active_flag` | SCD2 current-version flag |

## Data dictionary CSVs

Per-column documentation, usually one row per (table, column).

### Typical column headers

| Header variants | Bundle field |
| --- | --- |
| `table`, `table_name`, `entity` | Table name |
| `column`, `column_name`, `attribute` | Column name |
| `data_type`, `type`, `dtype` | Snowflake / Spark / SAS type |
| `length`, `precision`, `scale` | Type parameters |
| `nullable`, `not_null`, `mandatory` | Nullability |
| `description`, `definition`, `business_definition`, `meaning` | Description |
| `example_values`, `examples`, `domain` | Sample values |
| `allowed_values`, `valid_values`, `enum` | Constraint values |
| `sensitivity`, `classification`, `is_pii`, `pii_flag` | Sensitivity |
| `data_owner`, `steward` | Data owner |

## Naming standards documents

Usually a free-form PDF or a small CSV. Patterns to extract:

- **Database naming**: explicit values like `cstone_biz`, `<lob>_<env>`, etc.
- **Schema naming for facts**: e.g., `<domain>` (not `<domain>_model`). The "no `_model` suffix" rule is a common one.
- **Schema naming for dimensions**: e.g., `<domain>` or `shared` or `conformed_dims`.
- **Table prefixes**: `fact_*` for facts; `dim_*` for dimensions.
- **Column suffixes**: `_sk` for surrogate keys; `_bk` for business keys; `_dt` / `_date` for date columns; `_amt` for amounts; `_qty` for quantities.
- **Reserved words**: avoid Snowflake reserved words as column names.
- **Case conventions**: lowercase or UPPERCASE for identifiers (Snowflake convention is uppercase by default).

## ERD PDFs

ERD diagrams give you the *relationships* between facts and dims — what joins to what, and on which keys.

Extracting from a text-layer-bearing ERD PDF:

1. Pull the full text first.
2. Group lines by spatial proximity (tables are visual boxes; the box title is a table name and the lines beneath are columns).
3. Note arrows / lines between boxes — these are FK relationships.
4. If you can extract relationships explicitly, fold them into the fact catalog's "Foreign keys" column. If you can only extract tables and columns, document that the FK relationships were not machine-readable from the ERD and the user may need to provide them in a separate CSV.

If the ERD PDF is image-only (no text layer): say so and stop. Don't OCR — the accuracy isn't there for schema work.

## Business rules CSVs

A typical row: `BR-<num>, <target>, <rule expression>, <severity>, <description>`.

When the rule expression is procedural (multi-step), preserve it verbatim — don't try to compile it. The converter will translate it.

## XLSX workbooks

Treat each sheet as its own CSV. Use the sheet name as a hint to which catalog it belongs to:

- Sheet `Facts`, `Fact Tables`, `Fact Catalog` → fact catalog.
- Sheet `Dimensions`, `Dims`, `Dim Catalog` → dim catalog.
- Sheet `S2T`, `Mapping`, `Source to Target` → source-to-target mapping.
- Sheet `Data Dictionary`, `DD`, `Glossary` → column dictionary.
- Sheet `Naming Standards`, `Conventions` → naming.

A "summary" or "readme" sheet should be quoted in the Unstructured Context section of the bundle.

## What to do when nothing matches

If the metadata files in the folder don't fit any of these patterns:

1. Read the file with no assumptions; emit a "raw" section in the bundle quoting representative rows.
2. Add a "Gaps / assumptions" entry explaining that the metadata format wasn't recognized and the converter will need to infer.
3. Suggest the user describe the file's structure so future invocations can recognize it.
