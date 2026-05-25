# High-Risk Conversion Patterns — SAS to PySpark 3.4.1

The constructs whose naive translation goes wrong. PySpark differs from Snowflake on enough of these to warrant its own reference file — most notably MERGE semantics (Spark needs Delta/Iceberg) and window function nuances.

## Missing values

**SAS.** Numeric missing `.` sorts less than any number; comparisons quietly include missings.

**PySpark.** `null` (Spark uses null in both SQL and DataFrame contexts). `null < 100` is `null`, which is falsy in filters. `orderBy` puts nulls last by default for ascending, first for descending — opposite of SAS.

**Rules.**
- `if x = .` → `.filter(F.col("x").isNull())`
- `if missing(x)` → `.filter(F.col("x").isNull())`
- `if x < 100` (SAS, includes missings) → `.filter((F.col("x") < 100) | F.col("x").isNull())` if you suspect that's the intent, else just `.filter(F.col("x") < 100)` and note the change.
- For null-aware sort: `.orderBy(F.col("x").asc_nulls_first())` to match SAS default sort order.
- Special missings (`.A`..`.Z`, `._`) have no Spark analog — flag in Notes.

## BY-group processing and FIRST. / LAST.

**SAS.** `BY id;` with FIRST.id / LAST.id flags require pre-sorted input.

**PySpark.** Window functions.

```python
from pyspark.sql.window import Window

w = Window.partitionBy("customer_id").orderBy(F.col("order_date").desc())
last_per_customer = (
    df.withColumn("_rn", F.row_number().over(w))
      .filter(F.col("_rn") == 1)
      .drop("_rn")
)
```

For both first and last marked:

```python
w_first = Window.partitionBy("customer_id").orderBy("order_date")
w_last  = Window.partitionBy("customer_id").orderBy(F.col("order_date").desc())
result = (
    df.withColumn("is_first", F.row_number().over(w_first) == 1)
      .withColumn("is_last",  F.row_number().over(w_last)  == 1)
)
```

**Gotcha.** Window with no `orderBy` is allowed for `F.sum`/`F.count` (frame = full partition) but is *not* allowed for `F.row_number`, `F.lag`, `F.lead` — PySpark throws. Always include an `orderBy` for ranking functions.

**Determinism.** If the SAS source relies on row order without an explicit BY (e.g., reading a flat file), Spark won't preserve that order — you'd need to add an explicit ordering column upstream and surface that as a caveat.

## RETAIN

Three common idioms:

1. **Running total within group.**
   ```python
   w = Window.partitionBy("id").orderBy("date").rowsBetween(Window.unboundedPreceding, Window.currentRow)
   df = df.withColumn("running_total", F.sum("amount").over(w))
   ```

2. **LOCF.**
   ```python
   w = Window.partitionBy("id").orderBy("date").rowsBetween(Window.unboundedPreceding, Window.currentRow)
   df = df.withColumn("last_price", F.last(F.col("price"), ignorenulls=True).over(w))
   ```
   The `ignorenulls=True` parameter to `F.last` is the LOCF trick — without it you get the literal last row's value (including nulls).

3. **Conditional running counter.**
   ```python
   w = Window.orderBy("ts").rowsBetween(Window.unboundedPreceding, Window.currentRow)
   df = df.withColumn("counter", F.sum(F.when(F.col("condition"), 1).otherwise(0)).over(w))
   ```

**When you can't translate.** Truly sequential state-machine logic with look-ahead may not have a window-function form. Options: (a) `mapPartitions` with a Python iterator (loses partition pruning), (b) accept the limitation and recommend keeping that piece in a different tool, or (c) restructure the algorithm. Flag clearly.

## MERGE with BY

**SAS.** `merge a b; by id;` interleaves and overlays b's columns onto a's.

**PySpark.** Spark doesn't have a built-in MERGE for `parquet` / generic tables; only Delta Lake, Iceberg, and Hudi support `MERGE INTO`. For SAS MERGE BY semantics use a full outer join + coalesce:

```python
combined = (
    a.join(b, "id", "full_outer")
     .select(
         F.coalesce(b.name,   a.name).alias("name"),
         F.coalesce(b.status, a.status).alias("status"),
         # ... every column; b overlays a
     )
)
```

For SAS `IN=` flag logic (only-in-a, only-in-b, both), translate to `WHERE` filters on the joined result.

**Note.** If the user is on Databricks / Delta Lake / Iceberg / Hudi, you can also offer the `MERGE INTO` form for upsert-style cases — note the format requirement explicitly.

## Macros and macro variables

| SAS pattern | PySpark target |
| --- | --- |
| `%let var = value;` used once | Python variable |
| `%MACRO foo; (body) %MEND; %foo;` invoked once | Inline the body |
| `%MACRO foo(p1, p2); ... %MEND;` invoked many times | Python function `def foo(p1, p2) -> DataFrame` |
| `%IF ... %THEN ...` (compile-time conditional) | Resolve at translation time, or convert to runtime `F.when` if dynamic |
| `%DO i = 1 %TO 12;` generating 12 copies | Python loop building 12 DataFrames, or `.unionByName` if they're combined |
| `&&var&i` (indirect reference) | Python dict / list lookup |

PySpark macros becoming Python functions is natural — keep parameters typed where helpful and document what DataFrame schema the function expects.

## Formats and informats

PySpark format functions are different from Snowflake's `TO_VARCHAR` style. Quick reference:

| SAS format | PySpark target |
| --- | --- |
| `date9.` (`15JAN2024`) | `F.date_format("d", "ddMMMyyyy")` |
| `mmddyy10.` (`01/15/2024`) | `F.date_format("d", "MM/dd/yyyy")` |
| `yymmdd10.` (`2024-01-15`) | `F.date_format("d", "yyyy-MM-dd")` |
| `datetime20.` | `F.date_format("ts", "ddMMMyyyy:HH:mm:ss")` |
| `dollar12.2` (`$1,234.56`) | `F.format_string("$%,.2f", F.col("n"))` |
| `comma12.` | `F.format_string("%,d", F.col("n"))` |
| `percent8.2` | `F.format_string("%.2f%%", F.col("n") * 100)` |
| `z8.` (zero-pad) | `F.lpad(F.col("n").cast("string"), 8, "0")` |

User-defined value formats: small ones → `F.when(...).when(...).otherwise(...)`; large/shared ones → broadcast a lookup DataFrame and join.

Informats: `F.to_date`, `F.to_timestamp`, `F.col(s).cast(t)` — note PySpark's date pattern syntax is Java SimpleDateFormat-style (`yyyy-MM-dd`, not `YYYY-MM-DD`).

## Date/datetime arithmetic

- Date literals → `F.lit("2024-01-01").cast("date")` or `F.to_date(F.lit("2024-01-01"))`.
- `TODAY()` / `DATE()` → `F.current_date()`
- `DATETIME()` → `F.current_timestamp()`
- `INTCK('month', a, b)` → `F.months_between(b, a).cast("int")` (note argument order: end first, then start in `months_between`)
- `INTCK('day', a, b)` → `F.datediff(b, a)`
- `INTNX('month', d, n)` → `F.add_months(d, n)`
- `INTNX('day', d, n)` → `F.date_add(d, n)`
- `DATEPART(dt)` → `F.col("dt").cast("date")`
- `TIMEPART(dt)` → `F.date_format("dt", "HH:mm:ss").cast("string")` (Spark has no native TIME type)

**No native TIME type.** SAS time values must be represented as strings or seconds-since-midnight. Flag this in Notes.

## PROC SQL dialect quirks

PySpark SQL is closer to ANSI than PROC SQL — but a few translation rules:

- **`CALCULATED`** (reference an alias in the same SELECT list) → repeat the expression, or use a subquery / CTE.
- **`OUTOBS=`** → `LIMIT n`.
- **`MONOTONIC()`** → `F.monotonically_increasing_id()` (in DataFrame API) or `ROW_NUMBER() OVER (ORDER BY ...)` (in SQL). Note `monotonically_increasing_id` is partition-dependent and not contiguous.
- **`DICTIONARY.` tables** → `spark.catalog.listTables`, `listColumns`, `listDatabases` (in Spark 3.4 these return DataFrames).

## Implicit type coercion

SAS coerces numeric and character types implicitly. PySpark does some implicit casts but not all — be explicit:

- `F.col("char_col").cast("int") == 5` rather than `F.col("char_col") == 5`.
- For comparisons of mixed-typed columns, decide on a target type first.

## DataFrame action discipline (not strictly a conversion concern, but worth noting)

When translating a SAS program that performs many writes, the PySpark equivalent should:

- Build all transformations as lazy chains.
- Materialize (`saveAsTable` / `save`) only at the SAS dataset write points.
- Avoid `.count()` / `.show()` / `.collect()` mid-pipeline — those are actions that force execution.
- Use `.cache()` only when a DataFrame is reused multiple times downstream. (The reviewer skill will flag misuse.)

## What to do when none of these patterns fit

Same rule as the Snowflake converter:

1. Emit a stub: `# TODO: <description of what SAS did>`.
2. Add a Note explaining what the construct does and why it didn't translate.
3. Suggest a path: re-implement with `mapPartitions` / Python UDF / pandas UDF / keep in original tool.

Don't fabricate. Honest gaps are debuggable; confident-but-wrong translations are not.
