# Catalyst, Tungsten, and AQE — How Spark 3.4 Plans and Executes

This file is the lens for reading PySpark plans and predicting where things will go wrong. The performance-checklist and anti-patterns files give specific findings; this file is the model of how Spark decides what to do.

## The two-phase planning model

1. **Catalyst** (logical → optimized logical → physical plan). Rule-based + cost-based optimizer. Decides join order, predicate pushdown, projection pruning, constant folding.
2. **Tungsten** (physical execution). Whole-stage code generation, columnar processing, memory-managed off-heap data structures.

You read the plan via `df.explain()` or `df.explain(mode="extended")` / `"formatted"`. In a review, when something looks expensive, ask for the plan.

## Adaptive Query Execution (AQE) — what it does in 3.4

AQE is **on by default** in 3.4. It runs after each shuffle exchange and can:

1. **Coalesce shuffle partitions.** If the post-shuffle data is small, reduce partition count to avoid tiny-task overhead. Controlled by `spark.sql.adaptive.coalescePartitions.enabled` (true) and `spark.sql.adaptive.advisoryPartitionSizeInBytes` (default 64MB).
2. **Convert sort-merge join to broadcast join.** If a side ends up small after filtering, AQE can switch to broadcast at runtime — even if the static estimate said sort-merge. Controlled by `spark.sql.adaptive.localShuffleReader.enabled` and the broadcast threshold (default 10MB).
3. **Skew join handling.** Detects skewed partitions (one task processing 10x median) and splits them. Controlled by `spark.sql.adaptive.skewJoin.enabled` (true) and skew factor / size thresholds.

**Implication for review.** Many "old wisdom" manual hints (`broadcast()`, `repartition()`) are now redundant or counter-productive in 3.4 because AQE handles them adaptively. Recommend manual hints only when:

- The job has many short stages and the per-stage AQE overhead matters.
- The data sizes vary across runs and you want to pin the plan deterministically.
- You can name a specific AQE limit being hit (e.g., broadcast threshold).

When in doubt, *don't* recommend manual hints — they fight AQE.

## Wide vs narrow transformations

- **Narrow** — each output partition depends on one input partition. No shuffle. Examples: `filter`, `select`, `withColumn`, `map`, `union`, `coalesce(n)` to fewer partitions.
- **Wide** — output partitions depend on multiple input partitions. Shuffle required. Examples: `groupBy`, `join` (except broadcast or storage-partitioned), `distinct`, `repartition`, `orderBy`, `Window` without aligned partitioning.

In review: count the shuffle stages by reading `.explain()`. Each `Exchange` node is a shuffle. Excessive shuffles are usually the performance issue.

## Predicate pushdown

Catalyst pushes filters as close to the source as possible. It will *not* push across:

- A non-deterministic function (`rand()`, `current_timestamp()` is deterministic per query but `monotonically_increasing_id()` is not).
- Some UDFs (deterministic UDFs are pushable; non-deterministic ones are not).
- Aggregations (a filter on aggregated result can't push past the aggregation).
- Joins with arbitrary conditions (pushable past joins on the column being joined; not past projections that compute a join key).

In review: if a filter that "should" be cheap is causing a full scan, check whether something is blocking pushdown.

## Projection pruning

Catalyst removes unread columns from the read. `select(...)` and column references determine what's needed. If the source format supports column-level reads (Parquet, ORC, Delta), pruning is automatic.

Anti-pattern: `df = spark.read.parquet("...")` then never project — Catalyst will read every column. Always project early in the chain, or rely on the final `select` to be visible to the optimizer.

## Dynamic Partition Pruning (DPP)

Enabled by default in 3.4. For a star-schema join (large fact, small dimension), if the dimension's filter restricts to a few partition keys, DPP injects that filter into the fact-table scan at runtime — pruning fact partitions even though the filter wasn't explicit on the fact table.

Requires:
- The fact table is partitioned by the join key (e.g., `event_date`).
- The join is between the partitioned column on both sides.
- The optimizer can detect the relationship (it usually can).

In review: if you see a large fact table being scanned in full when a join with a small dimension should have pruned it, check the partitioning. If the fact isn't partitioned by the join key, DPP can't help.

## Whole-stage codegen

Catalyst compiles narrow chains of operations into a single Java method ("whole-stage codegen"). This is most of Tungsten's speed advantage. Things that *break* codegen:

- UDFs (Python UDFs in particular — they require serialization to Python, much slower).
- Some `Window` configurations.
- Aggregations with `collect_list` / `collect_set` on huge groups.

In review: if a stage looks slow and is doing simple work, check `.explain(mode="codegen")` to confirm codegen is engaged.

## Shuffle partition count

`spark.sql.shuffle.partitions` defaults to 200. For most workloads on modern clusters this is too few (under-utilizes parallelism) or too many (small-task overhead). AQE coalesces post-shuffle, so the default is more forgiving in 3.4 — but the *initial* shuffle still uses this value.

In review:
- For large jobs (>1TB intermediate), bumping to 400–1000 often helps.
- For small jobs (<100GB), the default is fine.
- Setting it per query (`spark.sql.shuffle.partitions = 400`) is appropriate; setting it cluster-wide rarely is.

## Join strategies in Spark 3.4

In order of cost (cheapest first):

1. **Broadcast hash join** — small side broadcast to all executors. Used when one side fits in `spark.sql.autoBroadcastJoinThreshold` (default 10MB). AQE can pick this dynamically.
2. **Shuffle hash join** — both sides shuffled, build hash table on smaller side. Less common in 3.4; sort-merge is usually preferred.
3. **Sort-merge join** — both sides shuffled and sorted. Default for large-large joins.
4. **Broadcast nested-loop join** — for non-equi joins. Expensive.
5. **Cartesian product** — no join key. Almost always wrong.

AQE may switch strategies at runtime. In review, you usually accept whatever join the planner chose unless `.explain()` shows something unreasonable.

## Reading `.explain(mode="formatted")`

The formatted plan output has two parts:

1. **Tree** at top — each node is an operation, numbered.
2. **Details** below — node-by-node breakdown with arguments.

Look for:
- `Exchange` — shuffle. Count them.
- `BroadcastExchange` — broadcast. Usually fast.
- `SortMergeJoin` / `BroadcastHashJoin` / `ShuffledHashJoin` — join strategy.
- `HashAggregate` / `ObjectHashAggregate` — group-by execution.
- `Filter` and `Project` — pushed where they should be?
- `Scan parquet` (or other) with `PushedFilters: [...]` — confirms predicate pushdown worked.

When reviewing, asking the user for the plan output is often the highest-leverage thing — most performance bugs are visible there.

## What to surface in review

When something is going wrong at the planning layer, the most useful framing:

> *"The `customer_orders` join is currently sort-merge (visible as `SortMergeJoin` in the plan). The right side appears to be a small dimension table (`< 50MB`). AQE should switch this to broadcast at runtime, but if you're seeing this stay sort-merge in practice, force it with `F.broadcast(customers_df)` — that's a one-line fix that pins the plan."*

Concrete observation + likely cause + concrete fix + caveat. Not just "consider broadcast."
