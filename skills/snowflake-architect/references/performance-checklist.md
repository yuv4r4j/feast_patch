# Performance Checklist

Use this when reviewing query performance. Most queries don't need every check — work top-down and stop when the answer is "yes, fine."

## Predicate pushdown

- **Filters on the base table** should be in the innermost SELECT, not the outermost. Snowflake's optimizer usually pushes them down, but explicit filters in CTEs make the plan obvious to the next reviewer.
- **Filters on a view**: confirm the view doesn't use non-deterministic functions or aggregations that block pushdown. If the view ends in `GROUP BY` or `QUALIFY`, predicates on aggregated columns can't push past it.
- **Filters on the output of `PIVOT` / `UNPIVOT`** don't push through. Filter before, not after.

## Window function partitioning

- A `ROW_NUMBER() OVER (ORDER BY ...)` with no `PARTITION BY` serializes the entire result through one node. Almost never what you want — confirm the partitioning matches the logical group.
- For "top N per group" patterns, prefer `QUALIFY ROW_NUMBER() OVER (PARTITION BY group ORDER BY ...) <= N` over self-join-and-filter.
- `SUM(...) OVER (...)` without a frame clause defaults to `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` *if there's an ORDER BY*, and to the full partition otherwise. Be explicit with `ROWS BETWEEN ...` to avoid surprises.

## Join shape

- **Inequality joins / cross joins** are expensive. If a join condition is `a.x BETWEEN b.lo AND b.hi`, ensure both sides are reasonably sized; otherwise consider pre-filtering.
- **Cartesian risk**: a `JOIN ... ON 1=1` or a missing `ON` clause is sometimes intentional (single-row dimension joins), but flag it.
- **Many-to-many fan-out**: a join between two tables with duplicates on the join key multiplies rows. If the downstream `GROUP BY` is correct, fine; if not, you may be double-counting. Check.

## Clustering and pruning

- **Clustering keys** matter only for tables where:
  1. The table is large (>1TB or many billions of rows), and
  2. Queries frequently filter or join on a low-cardinality-ish column (e.g., `event_date`, `customer_segment`), and
  3. The default micro-partition layout doesn't already happen to cluster well by insertion order.
- For smaller tables or one-off workloads: skip clustering. Snowflake's automatic micro-partitioning is usually fine.
- **Recommend `CLUSTER BY` only when** you can name the specific query pattern that will benefit. "We might filter by date" is not sufficient.
- **Recommend `SEARCH OPTIMIZATION` only when**: many point-lookup queries against a large table, low selectivity per query, and you've eliminated clustering as the answer.

## Aggregation and spill

- A `GROUP BY` with very high cardinality (millions of distinct groups) on a small warehouse will spill to local disk and then to remote storage. Symptoms: long query times, "bytes spilled to local/remote storage" in query profile.
- Mitigations: increase warehouse size, pre-aggregate at finer grain, or restructure to avoid the high-cardinality group.

## Warehouse sizing

- **XS** — interactive queries on small data, ad-hoc, dashboards.
- **S to M** — most production transformations.
- **L to XL** — large joins, heavy aggregations, big merges.
- **XXL+** — only if profiling shows the previous size was clearly bottlenecked. Bigger isn't always faster; some queries don't parallelize past a certain point.
- **Multi-cluster** — for concurrency (many users hitting the same warehouse), not for query speed.

A common waste pattern is "always use Large" — usually XS or S is fine and Large is on by reflex.

## Query patterns that fight the optimizer

- **`SELECT *` from a wide table when you need 3 columns.** Project early.
- **`DISTINCT` followed by `GROUP BY`** — pick one.
- **`COUNT(DISTINCT x)`** on huge sets — consider `APPROX_COUNT_DISTINCT` if approximate is acceptable.
- **`ORDER BY` in a CTE** — the optimizer is allowed to ignore it; rely on `ORDER BY` only in the outermost SELECT.
- **Scalar subqueries in SELECT** that could be a `LEFT JOIN` — see anti-patterns file.
- **`NOT IN` with NULL-able subquery** — semantics are surprising (a NULL in the IN list makes the entire predicate NULL). Prefer `NOT EXISTS` or `LEFT JOIN ... WHERE right IS NULL`.

## Result caching and warehouse caching

- **Result cache** (24h, cluster-shared) serves identical queries instantly. Don't disable it casually.
- **Warehouse cache** (data cache local to each warehouse) speeds up repeated queries against the same data. Cold warehouses (just resumed) have empty caches — first query is slow.
- For benchmarking: clear caches (`ALTER SESSION SET USE_CACHED_RESULT = FALSE` and a fresh warehouse) — otherwise you're measuring cache hits, not the query.

## Materialization decisions

- **View** when the source is fast and the query is run infrequently or interactively.
- **Materialized view** only when (a) the underlying query is expensive, (b) it's queried frequently, and (c) the base table change rate is low enough that maintenance cost is worth it. Otherwise prefer a scheduled `CREATE OR REPLACE TABLE`.
- **Dynamic tables** — newer alternative to materialized views; use when the freshness lag is tunable and downstream consumers want eventual consistency.
- **Temporary tables** in transformations — fine for intermediate steps; auto-dropped at session end.

## What to surface in the review

When you find performance issues, the most useful framing is:

> *"This query partitions by `customer_id`. If `customer_id` has 100M distinct values, the window will spill. Consider whether the partition can be coarser (e.g., `customer_segment`), or whether you actually need the window at all — a `GROUP BY` + `JOIN` may be cheaper."*

Concrete suggestion + reason + alternative. Not just "slow."
