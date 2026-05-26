---
name: metadata-ingester
description: Reads CSV and PDF files from a metadata folder and produces a structured metadata bundle (fact catalog, dimension catalog, source-to-target mappings, column dictionary, naming standards, business rules) that the converter and reviewer skills consume. Use this skill whenever the user supplies a metadata folder, references CSV / PDF data dictionaries, ERD diagrams, source-to-target mapping spreadsheets, glossaries, or migration playbooks alongside SAS code. Trigger on phrases like "ingest the metadata", "process the metadata folder", "read the metadata files", "load the ERD", "load the data dictionary", "load the source-to-target mapping", "use the dim/fact catalog", "metadata in <folder>", or when the converter / reviewer asks for context that lives in metadata files. This skill is the bridge between business documentation and the technical conversion — it parses static files and emits a structured catalog. It is NOT for executing code, querying live databases, or generating new metadata.
---

# Metadata Ingester

## What this skill is for

A clean SAS → Snowflake / PySpark conversion needs more than the SAS source code. It also needs context that lives in business documentation:

- **Source-to-target mappings** — which legacy warehouse / lake tables become which new facts and dimensions.
- **Fact and dimension catalogs** — which tables are facts (with grain, measures, surrogate-key FKs) vs dimensions (with attributes, business keys, SCD type).
- **Column dictionaries** — column name → type + business description + sensitivity flag.
- **Naming standards** — the database, schema, table, column conventions the new model must follow.
- **Business rules** — derivations, validation rules, retention policies that the SAS code may implement implicitly.

This skill reads CSV and PDF files from a user-supplied metadata folder and emits a structured metadata bundle in a format the downstream converter and reviewer can consume verbatim.

## Pipeline position

This skill is **stage 1b** in the pipeline, running in parallel with the analyzer:

1. User uploads SAS code (and, optionally, points at a metadata folder).
2a. **sas-analyzer** scans the SAS for data sources + walkthrough.
2b. **metadata-ingester** (this skill) reads the metadata folder.
3. The converter consumes BOTH the analyzer's data-source inventory AND the metadata bundle — that's how it knows the new ERD shape, naming conventions, and source-to-target mapping.
4. The reviewer enforces the standards (workflow match with SAS, dimensional model, naming, SQL standards) that come from the metadata.
5. Loop until confidence ≥ 85.

If no metadata folder exists, this skill is skipped. The converter then runs with weaker context and surfaces in Notes that the new ERD / naming had to be inferred — strongly recommend the user supplies metadata.

## Hard rule — read static metadata only; never execute code

You read static metadata files. You do not:

- Execute SAS, Snowflake SQL, Snowpark, PySpark, or any other code.
- Connect to live databases, Hive metastores, or any data warehouse / lake.
- Run user-supplied scripts or macros from the metadata files (some PDFs contain example queries — do not run them).
- Call out to external APIs for "metadata enrichment".

You DO use safe file operations:

- Read CSV files with standard parsers (`pandas.read_csv`, `csv` module, etc.).
- Extract text from PDF files with offline parsers (`pdfplumber`, `pypdf`, `pdftotext`).
- Read XLSX files if encountered (`openpyxl`, `pandas.read_excel`) — the user often calls these "metadata CSVs" loosely.
- Compute statistics about the metadata corpus (file counts, row counts, column coverage).

The execution prohibition matches the rest of the pipeline; the read prohibition does not — reading metadata files is the whole point of this skill.

## What you read

### CSV files

Common shapes you'll see in a metadata folder:

| File pattern | Likely content | What to extract |
| --- | --- | --- |
| `source_to_target*.csv`, `s2t*.csv`, `mapping*.csv` | One row per legacy column, mapping to new fact/dim | Legacy table → new table, column-level lineage, transformation logic |
| `fact*.csv`, `facts*.csv` | Fact-table catalog | Fact name, grain, measures, FK columns, source system |
| `dim*.csv`, `dimensions*.csv` | Dimension catalog | Dim name, business key, surrogate key, attributes, SCD type |
| `data_dictionary*.csv`, `glossary*.csv` | Column-level docs | Column name, data type, description, sensitivity, allowed values |
| `naming_standards*.csv`, `conventions*.csv` | Naming rules | Database, schema, table, column patterns; reserved prefixes/suffixes |
| `business_rules*.csv`, `rules*.csv` | Validation / derivation rules | Rule ID, target column, formula, source columns, severity |

Don't be rigid — column headers vary. Use semantic recognition:

- A column named `fact_table` / `target_fact` / `dest_table` → fact-table identifier.
- `business_key` / `nk` (natural key) / `source_key` → BK for dimensions.
- `surrogate_key` / `sk` / `_id` → SK for dimensions.
- `grain` / `granularity` → fact grain.
- `description` / `business_description` / `definition` → business meaning.
- `is_pii` / `sensitivity` / `classification` → PII / sensitivity flag.

### PDF files

PDFs in metadata folders are typically one of:

- **ERD diagrams** — visual model. Extract text first (`pdfplumber` does decent text extraction); look for the table names, relationships, and any cardinality notes. If the PDF is purely visual without a text layer, note that the ERD is a diagram-only PDF and you have only the table names visible in OCR (most modern PDFs have a text layer).
- **Data dictionaries** — same content as the CSV dictionary, just formatted. Extract table-section by table-section.
- **Business requirements / migration playbooks** — narrative text. Extract verbatim and section-index so the converter can quote the relevant passages.
- **Naming standards / governance docs** — extract the rules verbatim.

For PDFs, prefer fidelity over compression — surface the text as it appears, with section / heading structure preserved.

### XLSX files

Some "metadata folders" use `.xlsx` instead of `.csv`. Treat each sheet as a CSV; the sheet name often indicates the role (`facts`, `dimensions`, `mappings`).

## What you emit — the metadata bundle

The downstream converter and reviewer expect this structured output. Emit it as one markdown document with these sections, in this order:

```markdown
# Metadata Bundle

## Source files
- <relative path>: <one-line description>
- ...

## Naming standards
- Database: <value>
- Schema for facts: <value>
- Schema for dimensions: <value>
- Fact-table prefix: <value or "none">
- Dimension-table prefix: <value or "none">
- Surrogate-key suffix: <value, typically "_sk" or "_id">
- Business-key suffix: <value, typically "_bk" or "_nk">
- Other rules: <as found>

## Fact catalog
| Fact name | Grain | Measures | Foreign keys (→ dim) | Source system | Notes |
| --- | --- | --- | --- | --- | --- |
| fact_sales | one row per order line | sales_amount, qty | dim_customer, dim_product, dim_date | legacy.orders + legacy.order_lines | ... |
| ...

## Dimension catalog
| Dim name | Business key | Surrogate key | Key attributes | SCD type | Source system | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| dim_customer | customer_id | customer_sk | name, segment, region | Type 2 | legacy.customers | ... |
| ...

## Source-to-target mapping
| Legacy table | Legacy column | New table | New column | Transformation | Notes |
| --- | --- | --- | --- | --- | --- |
| legacy.orders | order_amt | fact_sales | sales_amount | rename, cast NUMBER(18,2) | ... |
| ...

## Column dictionary
| Table | Column | Type | Description | Sensitivity |
| --- | --- | --- | --- | --- |
| fact_sales | sales_amount | NUMBER(18,2) | Net order amount in USD | none |
| ...

## Business rules
| ID | Target | Rule | Source columns | Severity |
| --- | --- | --- | --- | --- |
| BR-001 | fact_sales.sales_amount | sales_amount = order_amt * (1 - discount_pct) | legacy.orders.order_amt, legacy.orders.discount_pct | error |
| ...

## Unstructured context (from PDF narratives)
> Verbatim quotes / passages from PDF docs, section-titled.

## Gaps / assumptions
- <things you couldn't find that the converter/reviewer should know about>
```

Be exhaustive within the metadata folder. Don't invent rows that aren't there; if a fact table appears in one CSV but not in another, surface that asymmetry in "Gaps / assumptions".

## How the converter and reviewer use this

- **Converter** uses the fact/dim catalogs and the source-to-target mapping to choose target tables, columns, and transformations. It uses the naming standards section to name databases, schemas, tables, columns correctly on the first pass.
- **Reviewer** uses the same bundle to grade the conversion: does the output use the right fact/dim names, the right schema, the right SCD treatment, the right surrogate keys, the right LEFT JOIN structure for dimensions?

So your bundle is contract-shaped. If the converter gets a malformed or partial bundle, it produces partial or guessed output. If you can't find what you need, fail loudly with a "Gaps / assumptions" entry — don't fabricate.

## Reference files

| Read when... | File |
| --- | --- |
| You need detailed format conventions for source-to-target mapping spreadsheets, fact / dim catalogs, or naming-standards docs | `references/metadata-formats.md` |

## What's out of scope

- **Generating new metadata.** You read existing metadata; you don't propose new fact tables or rename existing ones.
- **Validating metadata against live systems.** You can flag inconsistencies *within* the metadata folder (a column appears in dictionary but not in mapping) but not against the warehouse.
- **Executing example queries** that appear in PDF playbooks. Read them as text; don't run them.
- **OCR on diagram-only PDFs without text layers.** If the PDF is pure image, say so and ask the user to supply a text version.

## When to stop and ask the user

- Metadata folder is empty or contains only file types you can't read.
- The metadata appears to describe a different SAS source than the one the user uploaded (legacy table names don't match).
- The fact/dim catalog conflicts with itself (same table listed as both fact and dim, or two facts claim the same grain).
- The naming standards document conflicts with the data dictionary (one says schema is `dim`, the other says `dimensions`).

In each case, surface the conflict, give your best inference, and let the user decide.
