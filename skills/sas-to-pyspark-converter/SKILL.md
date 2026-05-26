---
name: sas-to-pyspark-converter
description: Translate SAS code from the EG 8.3.7.202 / Platform 9.4.8.0 / Model 16.01 stack into semantically equivalent PySpark 3.4.1 code using the DataFrame API. Use this skill whenever the user wants to convert, migrate, port, or rewrite SAS to PySpark / Spark / Databricks, or asks for a "Spark version" or "PySpark equivalent" of SAS code. Trigger on phrases like "convert this SAS to PySpark", "translate this DATA step to Spark", "rewrite this PROC SQL in PySpark", "Spark equivalent", "Databricks version", "migrate this `.egp` to Spark", "port this `.sas` to PySpark", or any user message that contains SAS source plus a reference to PySpark / Spark / Databricks / Delta. Outputs both DataFrame-API and Spark-SQL forms when both are useful, plus a Notes section flagging assumptions. For understanding the SAS, defer to `sas-analyzer`. After conversion, suggest handing off to `pyspark-data-engineer` for senior review.
---

# SAS → PySpark 3.4.1 Converter

## Mission

Take SAS code and emit:

1. **PySpark DataFrame API code** — idiomatic `pyspark.sql.DataFrame` chains using `pyspark.sql.functions as F` and `pyspark.sql.window.Window`, assuming a `spark: SparkSession` in scope.
2. **Spark SQL** (when useful) — the SQL form for the same logic, runnable via `spark.sql(""" ... """)`. Include this when the SAS source is SQL-shaped (PROC SQL) or when the user explicitly asks for it; otherwise the DataFrame form is enough.
3. **Notes** — short bulleted list of assumptions, missing-value handling, things needing human review, and out-of-scope items.

Both forms must be semantically equivalent to the SAS source. Where SAS semantics don't map 1:1 to Spark, choose the most likely intent, encode it explicitly, and surface the assumption.

## Pipeline position

This skill is one node in a SAS-to-pyspark migration pipeline:

1. **User uploads SAS code.**
2. **sas-analyzer** scans the code, classifies its data sources (datawarehouse / datalake / flat files like CSV, Excel, SAS datasets / metadata-bound libraries), and explains what the program does.
3. **sas-to-pyspark-converter** converts the SAS to target code, using the analyzer's data source inventory as context.
4. **pyspark-data-engineer** reviews the converted code and emits structured findings **plus an overall confidence score (0-100)**.
5. If confidence is below the stop threshold (≥ 85 with no blockers), the converter takes the findings as additional requirements and re-emits the code. Loop back to step 4.
6. When confidence is high enough, the pipeline exits and the user has a vetted artifact.

You are at step **3 (converter)**. Knowing this matters for how you frame your output — the next stage downstream consumes it.

## Role boundary — converters own code, reviewers do not

This skill is one of two **converter** skills (with `sas-to-snowflake-converter`). Converters are the only skills permitted to produce or modify code in this pipeline:

- **You produce PySpark code** — fresh from SAS, or revised based on review findings from `pyspark-data-engineer`.
- **`pyspark-data-engineer` reviews code** — surfaces findings, makes recommendations, but does not modify code.

When the user comes to you with review feedback and the original SAS in hand, treat the review findings as additional requirements. Re-run the conversion with the findings as constraints (e.g., "broadcast the dim table," "switch to `partitionOverwriteMode=dynamic`," "drop the `.collect()` and use `mapPartitions`"). Apply blockers first, then important findings, then suggestions.

If the user has PySpark code but no SAS source and is trying to apply review findings, say so clearly: re-converting without the SAS source isn't possible, and the user should either supply the SAS or apply the findings themselves. Don't try to "modify in place" — your contract is SAS-in, PySpark-out.

## Hard rule — no code execution

You **never execute the code** that is the subject of this skill — neither the input SAS nor any converted, reviewed, or example output. This skill is for static analysis, explanation, translation, and review only. Specifically:

- Do NOT run `sas`, `spark-submit`, `pyspark`, `python <script>.py`, `snowsql -f`, `snow sql`, `databricks-sql`, or any other command that executes the code.
- Do NOT issue queries against live Snowflake / Spark / SAS / Hive / database sessions or connections, even read-only ones.
- Do NOT use shell tools, Python `subprocess`, network requests, or any other mechanism to launch the code in any environment.
- Do NOT generate "smoke test" scripts or sample-run wrappers whose purpose is to execute the converted code automatically.

You **may** do safe static work:
- Read the source files and any uploaded artifacts.
- Run a *syntax-only* check that does not execute logic — for example, `python -m py_compile foo.py` to catch Python syntax errors, or a SQL parser that doesn't connect to a backend.
- Read documentation, schema files, or sample data files.
- Compute statistics about the code text (line counts, complexity heuristics).

When the user wants to validate the converted code, recommend they run it themselves in their own environment — and offer to help interpret any errors, logs, or unexpected results they bring back. The skill is the consultant; the user is the operator.

## Hard rule — preserve the SAS workflow and use a dimensional model

The PySpark output must mirror the SAS program's logical structure (same number of steps, same dataset boundaries, same branching). Each SAS step maps to a named PySpark DataFrame variable; the variable names should track the SAS dataset names.

If the `metadata-ingester` skill produced a metadata bundle, consume it. It contains:

- **Fact catalog** — fact-table names, grains, measures, dim-FK lists.
- **Dimension catalog** — dim-table names, business / surrogate keys, attributes, SCD type.
- **Source-to-target mapping** — which legacy lake/warehouse tables become which facts and dimensions.
- **Naming standards** — table and column naming conventions for the new model.

Use the catalog to replace legacy lake / warehouse reads with reads from the new fact and dimension tables. Facts join to dimensions via **LEFT JOIN** on surrogate keys:

```python
fact     = spark.table("<catalog>.<schema>.fact_orders")
dim_cust = spark.table("<catalog>.<schema>.dim_customer")
dim_prod = spark.table("<catalog>.<schema>.dim_product")

result = (
    fact.alias("f")
        .join(dim_cust.alias("c"), F.col("f.customer_sk") == F.col("c.customer_sk"), "left")
        .join(dim_prod.alias("p"), F.col("f.product_sk")  == F.col("p.product_sk"),  "left")
)
```

If no metadata bundle is supplied, infer the dimensional shape with conservative defaults (`fact_<event>`, `dim_<entity>`, `*_sk` surrogate keys) and surface the inference in Notes — strongly recommend the user supply metadata for the next pass.

**Catalog and schema names.** For PySpark, the catalog/schema convention is environment-dependent (Unity Catalog on Databricks, Iceberg catalog on Spark, Hive metastore on classic Hadoop). Read the metadata's naming standards if present; otherwise leave the catalog/schema as a parameter (`<catalog>.<schema>`) for the user to fill in.

**No tasks / stored procs analog in PySpark.** Spark doesn't have stored procedures, so the analogous rule is: do not wrap transformations in SQL UDFs or Spark stored procedures (Spark Connect has limited SP support; avoid). Use Python functions returning DataFrames; orchestrate in Python.

## Target environment assumptions (PySpark 3.4.1)

The translation targets Spark 3.4.1 features:

- **Adaptive Query Execution (AQE)** is on by default — don't recommend manual broadcast hints unless profiling shows AQE missed.
- **Dynamic Partition Pruning** is on by default.
- **Pandas API on Spark** (`pyspark.pandas`) is available but prefer the DataFrame API in conversions — it's more transparent.
- **Spark Connect** exists (3.4 was its first stable release) but assume classic Spark unless told otherwise.
- **`MERGE INTO`** is not native to Spark SQL for built-in formats — it requires Delta Lake, Iceberg, or Hudi. If the SAS uses `MERGE` / `UPDATE` semantics, note the Delta/Iceberg requirement explicitly.
- **DataFrame writers** default to `parquet`. For Hive-cataloged tables use `.saveAsTable()`; for paths use `.save(path)`.

## The conversion algorithm

1. **Understand the SAS.** Trace each DATA step / PROC; identify inputs, outputs, and the high-risk constructs.
2. **Identify high-risk constructs.** See `references/conversion-patterns.md` — missings, FIRST./LAST., RETAIN, MERGE BY, macros, formats, dates.
3. **Pick the PySpark construct.** See `references/proc-to-pyspark.md` for the SAS→PySpark mapping for every common PROC.
4. **Preserve structure.** One DataFrame variable per SAS dataset, named after the original (snake_case). Chain transformations lazily; materialize only at write points.
5. **Strip orchestration.** EG infrastructure (`%_eg_*`), `PROC PRINT`, `PROC OPTIONS`, `PROC PRINTTO` — drop them.
6. **Resolve macros where possible.** Macro invoked once with literals → inline. Invoked many times → Python function returning a DataFrame.
7. **Emit the sections.** PySpark DataFrame code, optionally Spark SQL, then Notes.

## Iterating on reviewer feedback

You may be invoked in two modes:

**Mode A — first pass.** The user supplies SAS source plus the analyzer's data source inventory plus (if available) the metadata-ingester's metadata bundle (fact / dim catalogs, source-to-target mapping). Produce the PySpark translation, mapping legacy reads to the new dimensional model, and emit it.

**Mode B — iteration after review.** The user supplies the SAS source, the previous PySpark output, and the `pyspark-data-engineer` review (findings + confidence score). Treat the review as additional requirements and produce a revised translation.

Iteration rules:

1. **Check the confidence score first.** If it's ≥ 85 with no 🔴 Blockers, the previous output is already shippable — say so to the user and don't churn out a new pass. Iterating in this case wastes effort and risks regressions.
2. **Address findings in severity order**: 🔴 Blocker → 🟠 Important → 🟡 Suggested → 🟢 Note.
3. **Re-emit the full output** (SQL / Snowpark / Spark code + Notes). Don't emit diffs only — the reviewer needs the complete artifact for the next pass.
4. **Add a "Changes from prior pass" callout** at the top of the Notes section listing what you addressed and (if anything) what you couldn't.
5. **Surface disagreements explicitly.** If a finding is wrong or misses context, say so in Notes ("Reviewer suggested X; preserved the original because <reason>") rather than silently ignoring it. The next review pass will see your reasoning.
6. **Watch for oscillation.** If two consecutive reviews ask for opposite changes ("use broadcast" then "remove broadcast"), stop the loop and explain the conflict to the user — they need to break the tie.

If after several passes the confidence score isn't climbing, the issue is usually structural — surface that to the user (e.g., "this DATA step uses dynamic macro logic the conversion can't statically resolve; consider supplying the macro parameters") rather than churning indefinitely.

## Output format

```python
# PySpark 3.4.1 DataFrame API
from pyspark.sql import SparkSession, DataFrame
from pyspark.sql import functions as F
from pyspark.sql.window import Window

# Assumes `spark: SparkSession` is in scope.

# One DataFrame variable per SAS dataset.
orders_clean = (
    spark.table("raw.orders")
    .filter(F.col("region") == "EAST")
    .withColumn("revenue", F.col("qty") * F.col("price"))
    .select("order_id", "customer_id", "revenue")
)
orders_clean.write.mode("overwrite").saveAsTable("work.orders_clean")
```

If a Spark SQL form is meaningful (PROC SQL source, or large set-based query):

```sql
-- Spark SQL form
CREATE OR REPLACE TABLE work.orders_clean AS
SELECT order_id, customer_id, qty * price AS revenue
FROM raw.orders
WHERE region = 'EAST';
```

Then Notes:

```
- Assumption: input table raw.orders exists in the catalog
- Missing values handling: ...
- Manual review: ...
- Delta requirement: <if applicable, e.g. MERGE INTO requires Delta Lake table format>
```

When called from the Streamlit converter app, use tagged sections so the parser can extract them:

```
<pyspark>
# DataFrame code
</pyspark>
<spark_sql>
-- Spark SQL form (optional)
</spark_sql>
<notes>
- bullets
</notes>
```

## Style guide for the DataFrame output

- **lowercase identifiers** by default (Spark is case-insensitive but lowercases by convention). Use backticks for non-standard names.
- **One DataFrame variable per SAS dataset.** Variable names mirror the SAS names in snake_case.
- **Lazy chains, not row loops.** `.filter`, `.withColumn`, `.groupBy`, `.join` — never `.collect()` into Python for transformation.
- **Window functions via `pyspark.sql.window.Window`.** Mirror the SAS BY-group with `Window.partitionBy(...).orderBy(...)`.
- **Persist with `.write.mode("overwrite").saveAsTable("lib.name")`** at SAS dataset write points. For path-based outputs use `.save("/path")`.
- **Use `F.col("name")` consistently** rather than mixing string column refs and `df.col` — it's more uniform and easier to extend.
- **Don't pre-optimize.** Avoid putting `broadcast()`, `repartition()`, `.cache()`, `coalesce()` in the translation — that's the reviewer's job.

## Style guide for the Spark SQL output

- Use `CREATE OR REPLACE TABLE ... AS SELECT` for materialized outputs. For temp views use `CREATE OR REPLACE TEMPORARY VIEW`.
- Use `QUALIFY` (Spark 3.4 supports it) for "filter on window function" patterns.
- For MERGE semantics: state the Delta / Iceberg requirement; emit `MERGE INTO` syntax with a comment that the target table must be Delta or Iceberg.
- Stick to standard Spark SQL; avoid Databricks-only extensions unless the user said they're on Databricks.

## Style guide for Notes

- Be specific. "Assumed raw.orders has columns (order_id, customer_id, region, qty, price, order_date)" is useful.
- **Always** flag when the SAS uses any of the high-risk constructs (missings, FIRST./LAST., RETAIN, MERGE, macros, formats, dates).
- **Always** flag when the conversion requires Delta / Iceberg (any MERGE / UPDATE / DELETE that's transactional).
- Be brief — ~6 bullets max.

## Reference files

| Read when... | File |
| --- | --- |
| You need the SAS→PySpark mapping for a specific PROC or DATA-step pattern | `references/proc-to-pyspark.md` |
| You're staring at a high-risk construct and want the exact translation semantics | `references/conversion-patterns.md` |

## Quick reference

| If you see in SAS... | Default PySpark construct |
| --- | --- |
| `BY var; if first.var / last.var` | `Window.partitionBy(var).orderBy(...)` + `F.row_number().over(w) == 1` |
| `RETAIN` running total | `F.sum(...).over(Window.partitionBy(...).orderBy(...))` with `rowsBetween(Window.unboundedPreceding, Window.currentRow)` |
| `RETAIN` LOCF | `F.last(col, ignorenulls=True).over(...)` with appropriate window |
| `MERGE a b; BY id;` | `a.join(b, "id", "full_outer")` + `F.coalesce(b.col, a.col)` |
| `PROC TRANSPOSE` (known IDs) | `.groupBy(...).pivot("col", [values]).agg(...)` |
| `PROC TRANSPOSE` (unknown IDs) | `.groupBy(...).pivot("col").agg(...)` (slower, requires extra pass) |
| `PROC SORT NODUPKEY` | Window row_number == 1 |
| `PROC FORMAT` small | `F.when(...).when(...).otherwise(...)` |
| `PROC FORMAT` large/shared | Broadcast a lookup DataFrame + join |
| `PROC MEANS NWAY` | `.groupBy(...).agg(...)` |
| `PROC MEANS` without NWAY (subtotals) | `.rollup(...).agg(...)` or `.cube(...).agg(...)` |
| `&macro_var` | Python variable |
| `%MACRO foo(...)` invoked many times | Python function returning DataFrame |
| `'01JAN2024'd` date literal | `F.lit("2024-01-01").cast("date")` |
| `PUT(x, format.)` | `F.date_format(x, "...")` for dates; `F.format_string(...)` for numbers |
| `INPUT(s, informat.)` | `F.to_date(s, "...")`, `F.to_timestamp(...)`, `F.col(s).cast("int")` |
| `INTCK / INTNX` | `F.datediff`, `F.add_months`, `F.date_add`, `F.date_sub` |
| `WHERE x = .` | `.filter(F.col("x").isNull())` |
| Implicit char↔num coercion | Explicit `.cast(...)` |

The full crosswalks with worked examples are in `references/proc-to-pyspark.md`.

## What's out of scope

- **Streaming sources.** This skill assumes batch. Streaming conversions are different enough to warrant a separate skill.
- **SAS/STAT statistical PROCs.** Suggest a Python re-implementation using `statsmodels`, `scikit-learn`, or Spark ML (`pyspark.ml`).
- **SAS/GRAPH.** Spark doesn't render charts.
- **PROC IMPORT/EXPORT.** Translate to `spark.read.*` / `df.write.*` only if asked.

## After conversion

Suggest the user run the output through the `pyspark-data-engineer` skill for senior review — Catalyst plan inspection, shuffle minimization, partition strategy, broadcast hints, anti-pattern check.
