# PySpark Anti-Patterns

Patterns that work but shouldn't be used in production PySpark 3.4 code. Each entry: the pattern, why it's bad, the better alternative.

## 1. `.collect()` on large DataFrames

**Pattern.** `rows = big_df.collect()` then iterate in Python.

**Why bad.** Pulls all rows to the driver as Python objects. OOMs the driver, defeats Spark's parallelism, serializes downstream work.

**Better.** Keep work in the DataFrame API. If you genuinely need per-row Python logic that can't be expressed in DataFrame ops, use `mapPartitions` (each partition handled independently in parallel) or a UDF — but reach for built-ins first.

## 2. UDF when a built-in exists

**Pattern.** A Python UDF that does what `F.regexp_replace`, `F.split`, `F.date_format`, or another built-in already does.

**Why bad.** Python UDFs serialize each row to Python, run, then serialize back. ~10–100x slower than built-ins, which run in JVM code-gen. Break whole-stage codegen too.

**Better.** Search PySpark's `functions` module (`pyspark.sql.functions`) — it has 300+ functions including most string, date, math, and array operations. Use them.

## 3. `count()` to check if a DataFrame is empty

**Pattern.** `if df.count() > 0:` to guard work.

**Why bad.** Triggers a full scan + aggregation. On large data, seconds to minutes wasted.

**Better.** PySpark 3.3+ has `df.isEmpty()`. Or `df.limit(1).count() > 0`. Or restructure so the work is safe on empty inputs.

## 4. `.cache()` everywhere "just in case"

**Pattern.** Every intermediate DataFrame is cached.

**Why bad.** Each cache occupies executor memory. When memory is tight, Spark evicts (spilling to disk or recomputing), often defeating the purpose. The driver also tracks caches; many of them add overhead.

**Better.** Cache only DataFrames that are (a) used in multiple downstream actions, and (b) expensive to recompute. Always `.unpersist()` when done.

## 5. `repartition(1)` or `coalesce(1)` on large data

**Pattern.** `df.coalesce(1).write.csv("...")` to produce a single output file.

**Why bad.** Serializes the final stage to one task — loses all parallelism. On a 100GB job, the last stage runs on a single executor.

**Better.** Accept multiple output files for large data. Or write to a staging location with normal partitioning, then have a separate process consolidate. Or — if the single-file output is genuinely required — accept the slowness consciously.

## 6. `.toPandas()` without Arrow

**Pattern.** `pdf = df.toPandas()` with Arrow disabled.

**Why bad.** Each row serialized via pickle row-by-row. 10–50x slower than Arrow.

**Better.** Enable Arrow once at the start: `spark.conf.set("spark.sql.execution.arrow.pyspark.enabled", True)`. And only `toPandas()` on small results to begin with.

## 7. Reading from CSV with `inferSchema=true` in production

**Pattern.** Production ETL reads `spark.read.option("inferSchema", "true").csv(...)`.

**Why bad.** Spark scans the file twice (once for schema, once for data). For large CSVs, this is wasted I/O. Also: inferred types can change subtly if the data does.

**Better.** Provide an explicit schema: `spark.read.schema(StructType([...])).csv(...)`. Or convert CSV to Parquet at the boundary and read Parquet downstream.

## 8. Row-by-row processing via `mapPartitions` when DataFrame ops would work

**Pattern.** Using `mapPartitions(lambda partition: [do_thing_to_each_row(r) for r in partition])` when the per-row work could be expressed in `withColumn` / `select`.

**Why bad.** Forces serialization to Python, defeats codegen. Use only when the logic legitimately requires Python (e.g., calling an external library that has no Spark equivalent).

**Better.** Express in DataFrame ops if possible. If a UDF is unavoidable, prefer a **vectorized pandas UDF** (`@pandas_udf`) over a scalar UDF — batches multiple rows per Python call.

## 9. Joining without a join key (`crossJoin` by accident)

**Pattern.** `df_a.join(df_b)` with no `on=` argument, or a join condition that always evaluates true.

**Why bad.** Cartesian product. Even small DataFrames produce huge results; the job appears to hang and then OOMs.

**Better.** Always specify `on=` or a meaningful join condition. If you genuinely need a cross join, use `.crossJoin()` explicitly — that makes the intent visible.

## 10. Implicit non-determinism: relying on order without `orderBy`

**Pattern.** Code that assumes rows come out in some order without an `orderBy`.

**Why bad.** Spark partitions and shuffles freely; row order is not preserved across most operations.

**Better.** Add an explicit `orderBy` where order matters. If the original data has no natural ordering key, add a `monotonically_increasing_id()` early in the pipeline (note: not contiguous and not stable across runs — document this).

## 11. Mixing `spark.sql` and DataFrame API for the same logic

**Pattern.** Some steps in `spark.sql(""" ... """)`, others in the DataFrame API, in the same pipeline.

**Why bad.** Hard to read, hard to test, hard to refactor. Both compile to the same plan, so there's no performance reason to mix.

**Better.** Pick one per pipeline. DataFrame API is usually better for programmatically composed transformations; `spark.sql` is better for set-based queries written by SQL-fluent people. Stick with the choice.

## 12. Hard-coding paths, database names, or environment-specific values

**Pattern.** `spark.read.parquet("/mnt/prod/data/orders")` inside a pipeline.

**Why bad.** Breaks across environments (dev / staging / prod). Onboarding is harder. Tests are harder.

**Better.** Parameterize via a config dict, environment variables, or a job-level configuration system.

## 13. `dropDuplicates()` without specifying columns

**Pattern.** `df.dropDuplicates()` to dedupe.

**Why bad.** Compares whole rows including nullable columns and floating-point columns — surprising results when columns drift. Also a full shuffle.

**Better.** `df.dropDuplicates(["id"])` — specify the columns. If you mean "keep the latest", use a window + row_number.

## 14. Catching exceptions inside transformations

**Pattern.** A UDF that wraps logic in `try/except: pass`.

**Why bad.** Hides errors. The output silently has fewer or wrong rows. Lazy evaluation means the error appears at a confusing later stage.

**Better.** Log the exception explicitly (to stderr or a side table), or use `F.try_*` Spark functions (`try_to_date`, `try_to_number`) which return null on failure.

## 15. `df.write.mode("overwrite")` on a partitioned table without `partitionOverwriteMode`

**Pattern.** `df.write.mode("overwrite").partitionBy("date").saveAsTable("t")` overwriting the whole table when you meant to overwrite one partition.

**Why bad.** Drops every partition, replaces with what `df` contains. If `df` only had this week's data, last week's is gone.

**Better.** Set `spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")` (or per write: `.option("partitionOverwriteMode", "dynamic")`). Then `overwrite` only overwrites partitions present in `df`.

## 16. Treating `.show()` like `print()`

**Pattern.** Production pipeline sprinkled with `df.show()` for debugging.

**Why bad.** Each `.show()` triggers a query. Stages run repeatedly; logs balloon. Slow and expensive.

**Better.** Remove `.show()` from production code; use it interactively in notebooks. For monitoring, write small stats DataFrames to a metrics table.

## 17. `groupBy("col").agg(F.collect_list(...))` on high-cardinality groups

**Pattern.** Collecting list of values per group when the groups have many values (millions).

**Why bad.** Each group's list lives in memory; one big group OOMs the executor.

**Better.** Question whether you need the list. If yes, consider sampling (`F.collect_list` followed by truncation), pre-aggregating, or using a different output structure.

## 18. Reading and writing the same table in one job

**Pattern.** `spark.read.table("t").<transforms>.write.mode("overwrite").saveAsTable("t")`.

**Why bad.** Spark's lazy evaluation means the read happens after the write starts — the read may see partial/empty results, especially on object-store-backed tables. Common cause of silent data loss.

**Better.** Write to a staging table, swap atomically. For Delta/Iceberg, the format's transactional guarantees handle it; for Parquet, use a swap.

## 19. Driver-side aggregation (manual accumulation pattern)

**Pattern.**
```python
totals = {}
for row in df.collect():
    totals[row.key] = totals.get(row.key, 0) + row.value
```

**Why bad.** Defeats the entire purpose of Spark. Driver-side compute.

**Better.** `df.groupBy("key").agg(F.sum("value"))`. If the result is small, then `.toPandas()` or `.collect()` *after* aggregation.

## 20. `if df.first():` to peek

**Pattern.** `if df.first():` or `df.first().name` to grab one row.

**Why bad.** `first()` triggers a job (similar to `.head()`). For a peek, fine; for a pattern repeated across the pipeline, costly.

**Better.** Restructure the logic to not require peeks. Or cache the DataFrame if you'll peek and then use it again.

---

When reviewing, name the pattern by number (e.g., "see anti-pattern #4") — keeps the review compact.
