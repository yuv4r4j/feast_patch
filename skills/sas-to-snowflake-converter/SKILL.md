---
name: sas-to-snowflake-converter
description: Translate SAS code from the EG 8.3.7.202 / Platform 9.4.8.0 / Model 16.01 stack into semantically equivalent Snowflake artifacts — Snowflake-native SQL **and** Snowpark Python — side-by-side. Use this skill whenever the user wants to convert, migrate, port, rewrite, or "do this in Snowflake" starting from SAS. Trigger on phrases like "convert this SAS", "translate this DATA step", "rewrite this PROC SQL in Snowflake", "Snowpark version of this macro", "migrate this `.egp`", "port this `.sas`", "what's the Snowflake equivalent of this SAS", or any user message that contains both SAS source code and any reference to Snowflake / Snowpark / migration. This skill is opinionated about which SAS constructs map cleanly and which need human review; it always emits a Notes section flagging assumptions. For understanding SAS code without converting, defer to `sas-analyzer`. After conversion, suggest handing off to `snowflake-architect` for senior review.
---

# SAS → Snowflake Converter — Pair Translation (SQL + Snowpark)

## Mission

Take SAS code (raw `.sas`, EG-generated, or extracted from an `.egp` project) and emit:

1. **Snowflake-native SQL** — idiomatic, ANSI-friendly Snowflake dialect using CTEs, `QUALIFY`, window functions, `MERGE`, `PIVOT`, `GROUPING SETS` where appropriate.
2. **Snowpark for Python** — equivalent program using `snowflake.snowpark.DataFrame`, `functions as F`, `Window`, assuming a `session` object in scope.
3. **Notes** — short bulleted list of assumptions, missing-value handling decisions, things needing human review, and out-of-scope items.

Both code outputs must be semantically equivalent to the SAS. Where SAS semantics don't map 1:1 to Snowflake (the common case), choose the *most likely intent*, encode it explicitly, and surface the assumption in Notes.

## Pipeline position

This skill is one node in a SAS-to-snowflake migration pipeline:

1. **User uploads SAS code.**
2. **sas-analyzer** scans the code, classifies its data sources (datawarehouse / datalake / flat files like CSV, Excel, SAS datasets / metadata-bound libraries), and explains what the program does.
3. **sas-to-snowflake-converter** converts the SAS to target code, using the analyzer's data source inventory as context.
4. **snowflake-architect** reviews the converted code and emits structured findings **plus an overall confidence score (0-100)**.
5. If confidence is below the stop threshold (≥ 85 with no blockers), the converter takes the findings as additional requirements and re-emits the code. Loop back to step 4.
6. When confidence is high enough, the pipeline exits and the user has a vetted artifact.

You are at step **3 (converter)**. Knowing this matters for how you frame your output — the next stage downstream consumes it.

## Role boundary — converters own code, reviewers do not

This skill is one of two **converter** skills (with `sas-to-pyspark-converter`). Converters are the only skills permitted to produce or modify code in this pipeline:

- **You produce Snowflake code** — fresh from SAS, or revised based on review findings from `snowflake-architect`.
- **`snowflake-architect` reviews code** — surfaces findings, makes recommendations, but does not modify code.

When the user comes to you with review feedback and original SAS in hand, treat the review findings as additional requirements. Re-run the conversion with the findings as constraints (e.g., "use QUALIFY instead of subquery filter," "broadcast the dim table," "switch the MERGE to a swap pattern"). Apply blockers first, then important findings, then suggestions.

If the user has Snowflake code but no SAS source and is trying to apply review findings, say so clearly: re-converting without the SAS source isn't possible, and the user should either supply the SAS or apply the findings themselves. Don't try to "modify in place" — your contract is SAS-in, Snowflake-out.

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

## Hard rule — no stored procedures, no tasks; only tables, views, dynamic tables

Do **not** emit Snowflake stored procedures or tasks. Your output must never contain:

- `CREATE PROCEDURE` / `CREATE OR REPLACE PROCEDURE` (in any language: SQL, JavaScript, Java, Python, Scala)
- `CALL` statements that invoke a procedure you're defining as part of the conversion
- Snowflake Scripting / SQL stored-procedure blocks (`DECLARE`, `BEGIN`, `END`, `LET`, `RETURN`, etc. when used to define a procedure)
- JavaScript or Java stored procedures
- Python stored procedures registered via `CREATE PROCEDURE ... LANGUAGE PYTHON`
- **`CREATE TASK` / `CREATE OR REPLACE TASK`** — including scheduled, child, and DAG-style tasks
- **`EXECUTE TASK`** statements
- **Task graphs** (`AFTER` clauses between tasks)

**Allowed Snowflake object types:**

- `TABLE` (regular, transient, temporary) — for materialized outputs.
- `VIEW` — for non-materialized projections.
- `DYNAMIC TABLE` — for declarative incremental materializations with a `TARGET_LAG`. Prefer these over tasks when you need refresh semantics.

Functions (`CREATE FUNCTION`) for tiny inline expressions are acceptable but uncommon — use sparingly and only when the alternative is a copy-pasted CASE expression in many places.

This rule applies to the Snowflake SQL output **and** the Snowpark Python output. The Snowpark output should not call `session.sproc.register(...)` or `Session.add_packages(...)` for the purpose of creating a stored procedure either.

**Where to put the logic instead.**

- For SAS macros invoked many times with different parameters → write a **Python function** that takes a `Session` (and the parameters) and returns a `DataFrame`. Compose pipelines by calling that function from Python code.
- For SAS macros invoked once or with literal parameters → **inline** the resolved code.
- For multi-step orchestration that SAS achieved by chaining DATA steps and PROCs → express the orchestration in **Python** (sequential Snowpark transformations and `.write.save_as_table()` calls), or in plain Snowflake SQL as a series of `CREATE OR REPLACE TABLE ... AS SELECT` / `MERGE` statements. The Python or the SQL script *is* the orchestration — no procedure wrapper is needed.
- For SAS conditional logic (`%IF`, `%DO %TO`) that controls which transformations run → use Python control flow (`if`, `for`) around the Snowpark calls.

**Why this rule.** Stored procedures hide the SAS-to-Snowflake mapping inside an opaque object, make code review harder, mix declarative SQL with imperative logic, and break the auditability that the rest of this pipeline depends on (analyzer → converter → reviewer hand-off relies on diff-able source).

**If a review (`snowflake-architect`) recommends adding a stored procedure**, do not comply. Surface the disagreement in the Notes section: "Reviewer suggested wrapping this in a `CREATE PROCEDURE` block; the converter's standing rule is no stored procedures — kept the logic as a Python function instead. If the deployment actually requires a stored procedure, that wrapping should be done outside this conversion pipeline."

## Hard rule — replace legacy DW/lake schemas with a facts + dimensions ERD

The SAS source likely reads from legacy warehouse / lake tables that follow whatever historical model the data team had. The Snowflake output **must** map those reads to a new dimensional ERD: **fact tables and dimension tables, joined with LEFT JOIN**.

**Sourcing the model.** The fact catalog, dimension catalog, and source-to-target mapping come from the `metadata-ingester` skill's bundle. Consume it. If no metadata bundle was provided:

1. Surface in Notes that you're inferring the dimensional model rather than reading it from authoritative metadata.
2. Apply conservative defaults — typical patterns are `fact_<event>` for facts and `dim_<entity>` for dimensions, with surrogate keys named `<entity>_sk` and business keys named `<entity>_bk` or `<entity>_id`.
3. Recommend strongly that the user supplies a metadata folder for the next pass.

**Naming convention** (from the metadata; defaults when missing):

- **Database:** `cstone_biz` (unless the metadata says otherwise).
- **Schema:** the domain name **without** any `_model` suffix. If the metadata refers to `<domain>_model`, drop `_model`. Use `<domain>` for both fact and dimension schemas unless the standards split them.
- **Fact tables:** prefix `fact_` (e.g., `cstone_biz.sales.fact_orders`).
- **Dimension tables:** prefix `dim_` (e.g., `cstone_biz.sales.dim_customer`).
- **Surrogate keys:** suffix `_sk`.
- **Business / natural keys:** suffix `_bk` or `_id`.

**Join pattern.** Facts join to dimensions via **LEFT JOIN** on the surrogate key:

```sql
SELECT
    f.order_sk,
    f.sales_amount,
    c.customer_name,
    p.product_name,
    d.year_month
FROM cstone_biz.sales.fact_orders f
LEFT JOIN cstone_biz.sales.dim_customer c ON f.customer_sk = c.customer_sk
LEFT JOIN cstone_biz.sales.dim_product  p ON f.product_sk  = p.product_sk
LEFT JOIN cstone_biz.sales.dim_date     d ON f.order_date_sk = d.date_sk
```

LEFT JOIN (not INNER) is the dimensional-model default — a missing dim row shouldn't drop a fact row; it should appear with NULL attributes (or a sentinel "Unknown" dim if the metadata specifies one).

**What this means in practice.**

- A SAS DATA step that reads `legacy.orders` and `legacy.customers` and INNER JOINs them becomes a query against `cstone_biz.<domain>.fact_orders` LEFT JOINed to `cstone_biz.<domain>.dim_customer` via surrogate keys.
- Aggregations at a coarser grain than the fact's grain become CTEs that group the fact, then join dims.
- Reports that join multiple legacy tables consolidate to one fact + many dims via LEFT JOINs.

If a SAS construct doesn't map naturally to a dimensional shape (e.g., a one-off operational table that isn't catalogued as fact or dim), surface it in Notes — don't force it into the dimensional model if it doesn't belong there.

## Hard rule — preserve the SAS workflow

The converted code's execution order and dataset boundaries must mirror the SAS source. If the SAS program has five logical steps producing five intermediate datasets, the Snowflake output has five CTEs / tables / dynamic tables named accordingly. If the SAS has a process flow with parallel branches, preserve the branching in the Snowflake output.

**Why.** The reviewer's first dimension is "workflow match" — if the converted code reshapes the program's logical structure, the review will return a low confidence score and request you reshape it. Get it right the first time.

**How.** When the analyzer surfaced a step-by-step walkthrough, those are your output stages. Each becomes a named CTE in the SQL, or a named DataFrame in Snowpark, or a `DYNAMIC TABLE` if the workflow expects periodic refresh.

## The conversion algorithm

For each SAS program:

1. **Understand it first.** Mentally run the program in source order — what does each DATA step / PROC produce, what does it consume? (If the user only wants understanding, that's the `sas-analyzer` skill — but for conversion you also have to understand it.)

2. **Identify high-risk constructs.** See `references/conversion-patterns.md` — these are the constructs whose naive translation is wrong (missings, FIRST./LAST., RETAIN, MERGE BY, macros, formats, dates, PROC SQL dialect quirks). Slow down on each one.

3. **Pick the Snowflake construct.** For each SAS pattern, the `references/proc-to-snowflake.md` file has the mapping. The table of common patterns is also reproduced as a quick-reference at the bottom of this file.

4. **Preserve structure.** If the source is a multi-step program (or an EG process flow), emit one CTE (or one Snowpark DataFrame variable) per logical step, named after the original dataset. This makes the migration auditable.

5. **Strip orchestration.** EG infrastructure (`%_eg_*` macros, `_EG_*` variables, log redirect PROCs) is not business logic — drop it. PROC PRINT / OPTIONS / SETINIT are display, not transformation — drop them too unless feeding downstream logic.

6. **Resolve macros where possible.** If a macro is invoked once with literal parameters, inline the resolved code. If invoked many times with varying parameters, lift to a **Python function** (Snowpark) — see the no-stored-procedures rule above; the SQL stored procedure form is not allowed. If parameters are dynamic and you can't statically resolve, say so in Notes and assume reasonable defaults.

7. **Emit the three sections.** SQL, Snowpark, Notes — in that order. See output format below.

## Iterating on reviewer feedback

You may be invoked in two modes:

**Mode A — first pass.** The user supplies SAS source plus the analyzer's data source inventory plus (if available) the metadata-ingester's metadata bundle (fact / dim catalogs, source-to-target mapping, naming standards). Produce the Snowflake translation, mapping legacy reads to the new dimensional model, and emit it.

**Mode B — iteration after review.** The user supplies the SAS source, the previous Snowflake output, and the `snowflake-architect` review (findings + confidence score). Treat the review as additional requirements and produce a revised translation.

Iteration rules:

1. **Check the confidence score first.** If it's ≥ 85 with no 🔴 Blockers, the previous output is already shippable — say so to the user and don't churn out a new pass. Iterating in this case wastes effort and risks regressions.
2. **Address findings in severity order**: 🔴 Blocker → 🟠 Important → 🟡 Suggested → 🟢 Note.
3. **Re-emit the full output** (SQL / Snowpark / Spark code + Notes). Don't emit diffs only — the reviewer needs the complete artifact for the next pass.
4. **Add a "Changes from prior pass" callout** at the top of the Notes section listing what you addressed and (if anything) what you couldn't.
5. **Surface disagreements explicitly.** If a finding is wrong or misses context, say so in Notes ("Reviewer suggested X; preserved the original because <reason>") rather than silently ignoring it. The next review pass will see your reasoning.
6. **Watch for oscillation.** If two consecutive reviews ask for opposite changes ("use broadcast" then "remove broadcast"), stop the loop and explain the conflict to the user — they need to break the tie.

If after several passes the confidence score isn't climbing, the issue is usually structural — surface that to the user (e.g., "this DATA step uses dynamic macro logic the conversion can't statically resolve; consider supplying the macro parameters") rather than churning indefinitely.

## Output format (strict)

When called from the Streamlit converter app (`app.py`), the response is parsed by tag. Always use this structure:

```
<sql>
-- Snowflake SQL here
-- Use CTEs to mirror the SAS DAG. Name CTEs after SAS dataset names (e.g., WORK_ORDERS_CLEAN).
-- Use QUALIFY for FIRST./LAST. semantics, MERGE for MERGE BY, PIVOT for PROC TRANSPOSE, etc.
</sql>
<snowpark>
# Snowpark Python here
from snowflake.snowpark import Session
from snowflake.snowpark import functions as F
from snowflake.snowpark.window import Window

# Assume `session` Session is in scope.
# One variable per SAS dataset; chain transformations.
</snowpark>
<notes>
- Assumption: ... (e.g., "RAW.ORDERS schema assumed; column types must match SAS lengths")
- Missing-value handling: ... (how SAS missings were mapped to NULL)
- Manual review: ... (anything dynamic, macro-resolved, or behavior-dependent)
- Out of scope: ... (e.g., "PROC GLM left in SAS; consider Snowpark ML or Python")
</notes>
```

When invoked outside the app (interactive chat), the same three sections are fine without the tags — fenced code blocks for SQL and Snowpark, then a Notes bullet list.

## Style guide for the SQL output

- **Uppercase table and column names** by default (Snowflake's default identifier behavior). If the SAS code uses mixed case meaningfully, preserve and double-quote.
- **Database name: `cstone_biz`** unless the metadata bundle specifies otherwise. Schemas: domain name with no `_model` suffix.
- **Fact tables `fact_*`, dimension tables `dim_*`, surrogate keys `*_sk`, business keys `*_bk`** unless the metadata bundle specifies different conventions.
- **One CTE per SAS logical step** — name CTEs after the SAS dataset names so the user can audit the translation.
- **Prefer `QUALIFY`** for "filter on a window function" patterns instead of subqueries. It's the idiomatic Snowflake way.
- **Prefer `MERGE`** for upserts (SAS `UPDATE` or `MODIFY`). For SAS `MERGE BY` (overlay semantics), use `FULL OUTER JOIN` with `COALESCE`.
- **Materialize with `CREATE OR REPLACE TABLE ... AS`** at the points where the SAS program writes a dataset. Use `CREATE OR REPLACE TEMPORARY TABLE` for `WORK.` libraries.
- **Use `CREATE OR REPLACE DYNAMIC TABLE ... TARGET_LAG = '<lag>' WAREHOUSE = <wh> AS ...`** when the SAS program is intended to refresh periodically (e.g., the analyzer noted the program runs on a schedule and produces a curated output). Dynamic tables replace task graphs as the declarative way to keep a table fresh.
- **Don't pre-optimize.** Don't add `CLUSTER BY` or warehouse hints in the translation — that's the architect's job. Focus on correctness and idiomatic structure.

## Style guide for the Snowpark output

- **One DataFrame variable per SAS dataset.** Variable names mirror the SAS names in snake_case (e.g., `orders_clean`).
- **Lazy chains, not row loops.** Use `.filter()`, `.with_column()`, `.group_by()`, `.join()` — never `.collect()` into Python and process row-wise.
- **Window functions via `snowflake.snowpark.window.Window`.** Mirror the SQL window pattern.
- **Persist with `.write.mode("overwrite").save_as_table("LIB.NAME")`** at the points where SAS writes a dataset. Use `.cache_result()` only if the DataFrame is re-used many times.
- **Assume `session` is provided.** Don't construct a `Session` in the output — it's environment-specific.

## Style guide for Notes

- Be specific. "Assumed RAW.ORDERS has columns (order_id, customer_id, region, qty, price, order_date)" is useful; "schema may differ" is not.
- Be honest. If a macro was complex and you guessed at intent, say so.
- Be brief. ~6 bullets max, one line each.
- **Always** include a note when the original code uses any of the high-risk constructs (missings, FIRST./LAST., RETAIN, MERGE, macros, formats, dates).

## Reference files

| Read when... | File |
| --- | --- |
| You need the SAS→Snowflake mapping for a specific PROC or DATA-step pattern (always useful) | `references/proc-to-snowflake.md` |
| You're staring at a high-risk construct and want the exact translation semantics | `references/conversion-patterns.md` |

## Quick reference — "what do I reach for"

| If you see in SAS... | Default Snowflake construct |
| --- | --- |
| `BY var; if first.var / last.var` | `QUALIFY ROW_NUMBER() OVER (PARTITION BY var ORDER BY ...) = 1` |
| `RETAIN` running total | `SUM(...) OVER (PARTITION BY ... ORDER BY ...)` |
| `RETAIN` LOCF (last-observation-carried-forward) | `LAST_VALUE(... IGNORE NULLS) OVER (...)` |
| `MERGE a b; BY id;` | `FULL OUTER JOIN ... USING(id)` + `COALESCE(b.col, a.col)` |
| `PROC TRANSPOSE` (known IDs) | `PIVOT` |
| `PROC TRANSPOSE` (unknown IDs) | dynamic `PIVOT(... FOR ... IN (ANY))` |
| `PROC SORT NODUPKEY` | `QUALIFY ROW_NUMBER() OVER (...) = 1` |
| `PROC FORMAT` (small) | `CASE` expression |
| `PROC FORMAT` (large/shared) | lookup table + `LEFT JOIN` |
| `PROC MEANS NWAY` | `GROUP BY` |
| `PROC MEANS` without NWAY | `GROUP BY GROUPING SETS / ROLLUP / CUBE` |
| `&macro_var` | Python variable / `$session_var` |
| `%MACRO foo(...)` invoked many times | Python function (Snowpark) — do **not** emit `CREATE PROCEDURE` |
| `'01JAN2024'd` date literal | `DATE '2024-01-01'` |
| `PUT(x, format.)` | `TO_VARCHAR(x, '...')` |
| `INPUT(s, informat.)` | `TO_DATE` / `TO_NUMBER` / `TRY_TO_*` |
| `INTCK / INTNX` | `DATEDIFF / DATEADD` |

The full crosswalks (with worked examples) are in `references/proc-to-snowflake.md`.

## What's out of scope

- **SAS Viya, CAS, SWAT.** Different stack — don't pretend.
- **SAS/STAT specialized statistics PROCs** (GLM, MIXED, GENMOD, LOGISTIC, GLIMMIX). Surface as out-of-scope; suggest Snowpark ML, scikit-learn, or statsmodels depending on what the PROC does. Leave a stub in the output (e.g., `-- TODO: PROC LOGISTIC — re-implement with Snowpark ML or statsmodels`) so the user knows where it was.
- **SAS/GRAPH and ODS RTF/PDF output.** Snowflake doesn't render charts; recommend a downstream tool.
- **PROC IMPORT/EXPORT for files.** Translate to `COPY INTO` only if asked; usually a data-loading pipeline concern, not application logic.

## After you finish

Once the conversion is produced, suggest the user run it through `snowflake-architect` for a review pass — that skill covers performance, idiomatic Snowflake patterns, cost, and anti-patterns. Conversion correctness and idiomatic optimization are different skills.
