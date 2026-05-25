# PySpark 3.4.1 Performance Checklist

Specific patterns to check during review. Companion to `catalyst-and-aqe.md` (which explains the model) and `anti-patterns.md` (which catalogs what to avoid).

## Partitioning on read

- **Source partitioning matters.** A Parquet table partitioned by `event_date` will prune partitions for `WHERE event_date = '...'`. If the filter is on something else, no pruning — full scan.
- **`spark.read.parquet("/path/*/*")`** without a partition column means Spark discovers partitions from the path; that's usually correct but slow on object stores with many files. Use Hive metastore or Delta if possible.
- **`mergeSchema=true`** is expensive — only use when schemas differ across files.

## Partitioning on compute (during transformations)

- **`repartition(n)`** — full shuffle to `n` partitions. Use to *increase* parallelism or rebalance skew. Expensive — only when needed.
- **`repartition(n, "col")`** — hash-partition by `col`. Useful before a `Window` that partitions by the same column (avoids a second shuffle).
- **`coalesce(n)`** — narrow transformation that reduces partition count without a shuffle. Use to *decrease* before a write to control output file count. Don't `coalesce(1)` on large data — it serializes the final stage.

When to recommend an explicit `repartition`:
- Before a `Window` on a non-default key.
- Before a `join` where AQE isn't behaving (rare in 3.4).
- After a heavy filter (`filter().repartition()` rebalances skewed partitions).

When *not* to recommend:
- "Just in case" — there's a cost.
- Before reading a small table — pointless.

## Partitioning on write

- `df.write.partitionBy("event_date").saveAsTable(...)` — write data partitioned by event_date. Enables pruning for downstream consumers.
- Use `partitionBy` columns with reasonable cardinality (date is great, customer_id might create too many partitions).
- **`bucketBy`** — bucket the data into N files per partition based on a column. Useful for repeated joins on that column (storage-partitioned joins skip the shuffle). Niche; recommend only when query patterns justify it.

## Broadcasts

- **AQE handles most.** Manual `F.broadcast(small_df)` is for: pinning the plan, sizes that fluctuate across runs, or when AQE's adaptive switch happens too late.
- Broadcast threshold: 10MB default (`spark.sql.autoBroadcastJoinThreshold`). Don't broadcast tables much larger than that — executor memory pressure.
- **Anti-pattern**: broadcasting a freshly-filtered DataFrame whose size you don't know. Materialize and check (`df.count()` or write a stat) before broadcasting.

## Skew

- **Detection.** If one task in a stage takes 10x longer than the median, you have skew. Visible in Spark UI's Stages tab (look at task time distribution).
- **AQE.** Spark 3.4's `spark.sql.adaptive.skewJoin.enabled` (default true) splits skewed partitions automatically.
- **Manual.** If AQE isn't catching it: salt the join key. Pre-aggregate the skewed side. Filter the skewed values out and handle separately.
- Common skew sources: nulls in the join key (all nulls go to one partition); a single popular value (e.g., one product accounting for 30% of rows).

## Caching and persistence

- **`.cache()`** — alias for `.persist(StorageLevel.MEMORY_AND_DISK)`. Stores the DataFrame in executor memory; spills to disk if memory is tight.
- **`.persist(level)`** — fine-grained control. `MEMORY_ONLY` (fastest if it fits), `MEMORY_AND_DISK_SER` (serialized, smaller), `DISK_ONLY` (last resort).
- **`.unpersist()`** — release. Forget this and you tie up cluster memory for the session.

When to cache:
- A DataFrame is used in multiple downstream actions (e.g., counted, joined, and written).
- An expensive computation is materialized and re-read.

When *not* to cache:
- One downstream use — no benefit.
- The DataFrame is small enough that recomputation is cheap.
- The intermediate is going to be written anyway (the write materializes it).

Anti-pattern: `.cache()` everywhere "just in case." Cache discipline is one of the most common review findings.

## `.collect()`, `.toPandas()`, `.show()`

- **`.collect()`** — pulls all rows to the driver as Python objects. OOMs the driver if the data is large. Acceptable for: small results (a few thousand rows), tests, dimension tables loaded once.
- **`.toPandas()`** — same risk plus the conversion cost. Use with **Arrow** enabled (`spark.conf.set("spark.sql.execution.arrow.pyspark.enabled", True)`) for ~10x speedup.
- **`.show(n)`** — pulls n rows for display. Fine for debugging, never in production code.
- **`.count()`** — triggers a full scan. Use sparingly; if you only need "does any row exist," use `df.limit(1).count() > 0` or `df.isEmpty()` (PySpark 3.3+).

## File format choices

| Format | When to use |
| --- | --- |
| **Parquet** | Default. Columnar, compressed, predicate-pushdown. |
| **Delta Lake** | When you need ACID transactions, MERGE INTO, time travel, schema evolution. Not built into vanilla Spark — requires the Delta package. |
| **Iceberg** | Similar to Delta. Strong for analytics catalog use cases. |
| **ORC** | Like Parquet, common in Hive ecosystems. Functionally similar. |
| **CSV** | Only for source/sink at the system boundary. Never internal. |
| **JSON** | Source/sink only. Slow to read, no schema. |
| **Avro** | Row-oriented; better than Parquet for write-heavy streaming. Worse for analytics. |

## Small-file problem

After many writes (especially streaming or `coalesce(n)` with large n), a table may have many small files. This hurts read performance.

- For Parquet: write with controlled `coalesce(n)` or `repartition(n)`. Rule of thumb: target 128MB–1GB per file.
- For Delta: use `OPTIMIZE table_name` to compact.
- For Iceberg: `CALL system.rewrite_data_files`.

## Schema enforcement

- **`spark.read.schema(my_schema).parquet(...)`** is faster than relying on `mergeSchema=true` or inference.
- **`inferSchema=true` on CSV** does a separate scan to figure out types. Costly for large files; always provide a schema for production.
- **For Delta**: schema is stored; `mergeSchema` is opt-in via option per write.

## Configuration tuning (advice for the user, not changes to apply)

These are session-level configs that often help. In a review, recommend them with context — don't blanket-recommend.

| Config | When to recommend |
| --- | --- |
| `spark.sql.shuffle.partitions = 400` (or higher) | Large jobs (intermediate >1TB) |
| `spark.sql.adaptive.skewJoin.skewedPartitionFactor` | Heavy skew, default isn't catching it |
| `spark.sql.autoBroadcastJoinThreshold` | Raising allows larger broadcasts (be careful with memory) |
| `spark.sql.files.maxPartitionBytes = 128MB` (default) | Bump up for many small files; bump down for fewer-larger-tasks behavior |
| `spark.sql.execution.arrow.pyspark.enabled = true` | If using `.toPandas()` or pandas UDFs |
| `spark.serializer = org.apache.spark.serializer.KryoSerializer` | Marginal speedup; usually a default already in modern deployments |

## What to surface in review

A useful performance finding has:

1. **Observation** (what you see in the code or plan).
2. **Cause** (why it matters — predicate not pushing, shuffle too wide, broadcast too big).
3. **Fix** (specific code change).
4. **Caveat** (if any — "if the data is X size or smaller, this is fine").

Without all four, the user can't decide whether to act. Reviews that just say "this is slow" are not useful.
