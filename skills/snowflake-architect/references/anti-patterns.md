# Snowflake Anti-Patterns

A reference catalog of patterns that work but shouldn't be used in idiomatic Snowflake code. Each entry: the pattern, why it's bad, the better alternative.

## 1. Cursors and row-by-row processing

**Pattern.** Stored procedure using `OPEN cur; LOOP; FETCH cur INTO ...; <do something>; END LOOP;` to process a result set row by row.

**Why bad.** Snowflake is a columnar MPP warehouse — single-row work serializes the entire query and bypasses the optimizer. A loop of 1M iterations is ~10000x slower than the set-based equivalent.

**Better.** Reformulate as a single `INSERT INTO ... SELECT ...` or `MERGE ... USING (SELECT ...) ON ... WHEN MATCHED ...`. If the logic truly requires per-row branching, it can almost always be expressed with `CASE` / `IFF` in a single statement.

## 2. Scalar subquery in SELECT (when a join would do)

**Pattern.**
```sql
SELECT
  o.order_id,
  (SELECT name FROM customers c WHERE c.id = o.customer_id) AS customer_name
FROM orders o;
```

**Why bad.** The optimizer often rewrites it to a join, but not always — and the cost of the rewrite is opaque. Joins are clearer to readers and predictable to optimize.

**Better.**
```sql
SELECT o.order_id, c.name AS customer_name
FROM orders o
LEFT JOIN customers c ON c.id = o.customer_id;
```

## 3. `ORDER BY` in `CREATE TABLE AS`

**Pattern.**
```sql
CREATE OR REPLACE TABLE big_table AS
SELECT * FROM source ORDER BY event_date;
```

**Why bad.** Snowflake tables are unordered — micro-partitions are not guaranteed to honor the source order. The `ORDER BY` adds compute cost and gives the developer false confidence.

**Better.** If you want the data physically clustered for query pruning, use `CLUSTER BY (event_date)` instead. If you actually want sorted *output*, do the `ORDER BY` at query time.

## 4. `SELECT *` in production code

**Pattern.** Production transformation reads `SELECT *` from a wide table.

**Why bad.** Adds cost for unused columns. Breaks silently when the upstream schema changes (added columns silently propagate; renamed columns break downstream). Makes the schema dependency invisible in code review.

**Better.** Explicit column list. If many columns and the schema is stable, accept the readability cost. If the schema is volatile, the explicit list is your safety net.

**Exception.** Ad-hoc exploration in a notebook is fine.

## 5. `NOT IN` with a NULL-able subquery

**Pattern.**
```sql
SELECT * FROM a WHERE a.x NOT IN (SELECT b.x FROM b);
```

**Why bad.** If any `b.x` is NULL, the whole predicate is NULL (treated as false), and you get zero rows — silently. This is one of the most expensive bugs in SQL.

**Better.**
```sql
SELECT * FROM a WHERE NOT EXISTS (SELECT 1 FROM b WHERE b.x = a.x);
-- or
SELECT a.* FROM a LEFT JOIN b ON b.x = a.x WHERE b.x IS NULL;
```

## 6. Boolean as `'Y'/'N'` string

**Pattern.** Storing booleans as `VARCHAR(1)` with `'Y'` and `'N'`.

**Why bad.** Snowflake has a `BOOLEAN` type. The string version is bigger, slower to filter, and easy to typo (`'y'`, `' Y'`).

**Better.** `BOOLEAN`. If migrating from a system that uses Y/N, do the conversion at the load boundary.

## 7. Date stored as `VARCHAR`

**Pattern.** Date columns stored as `VARCHAR` like `'2024-01-15'`.

**Why bad.** Loses type safety. Comparisons work because of implicit casts but are slower. Sort order is lexicographic, which happens to coincide with date order for ISO format — but not for `'01/15/2024'`.

**Better.** `DATE`. Convert at load.

## 8. Wide aggregations without filtering first

**Pattern.**
```sql
SELECT region, COUNT(*) FROM huge_events WHERE event_date >= CURRENT_DATE - 7 GROUP BY region;
```

This is fine *if* `event_date` prunes well. If `huge_events` is unclustered and the optimizer can't prune by `event_date`, the query scans everything.

**Why bad.** Without pruning, you're paying for a full scan when 1% of the data is needed.

**Better.** Cluster by `event_date` (or `DATE_TRUNC('day', event_ts)`), or pre-filter via a date-partitioned upstream view. Check the query profile for partition pruning before assuming the optimizer did it.

## 9. Excessive transient/temp table proliferation

**Pattern.** A pipeline that creates 30 transient tables, each used by one downstream step.

**Why bad.** Each materialization is a write+read round-trip; many of them serialize the pipeline. Materialize when reuse justifies it; otherwise CTEs are cheaper.

**Better.** Use CTEs for one-shot intermediate steps. Materialize only at meaningful boundaries (output tables, expensive intermediates reused multiple times, debugging checkpoints).

## 10. Reading `LIMIT N` to "make a query fast"

**Pattern.** Adding `LIMIT 1000` to a slow query thinking it'll speed up the work.

**Why bad.** `LIMIT` is applied *after* the query plan runs (or at most pushed down through trivial transformations). On an aggregated query, `LIMIT` doesn't change the compute. It only changes the rows returned to the client.

**Better.** Fix the actual cost driver. Use `LIMIT` to control client-side row count, not warehouse-side compute.

## 11. Hardcoded warehouse names / role names in code

**Pattern.** `USE WAREHOUSE ETL_WH_PROD;` inside a transformation script.

**Why bad.** Couples the script to environment-specific objects. Breaks in dev/staging. Makes onboarding harder.

**Better.** Parameterize via environment variables, a config file, or session context set before the script runs.

## 12. Secrets in code

**Pattern.** Snowflake credentials, API keys, account locators committed to the repo.

**Why bad.** Self-explanatory.

**Better.** Snowflake secrets (`CREATE SECRET ...`), environment variables, `~/.snowsql/config`, or a secret manager.

## 13. `CREATE TABLE` + `INSERT` instead of `CREATE TABLE AS`

**Pattern.**
```sql
CREATE TABLE x (id INT, name STRING);
INSERT INTO x SELECT id, name FROM source;
```

**Why bad.** Two statements where one would do, manually maintained schema, no metadata propagation.

**Better.**
```sql
CREATE OR REPLACE TABLE x AS SELECT id, name FROM source;
```

(Exception: if you specifically need to lock down the schema with type constraints that differ from the SELECT inference, the two-statement form is correct.)

## 14. Time travel as a backup strategy

**Pattern.** "We don't need backups because time travel exists."

**Why bad.** Time travel is short-lived (default 1 day, max 90 on Enterprise) and not a substitute for backups. A bad migration that runs unnoticed for a week will exhaust the time-travel window.

**Better.** Time travel for "oops I just dropped a table"; real backups (`@external_stage` exports, secondary accounts, replication) for disaster recovery.

## 15. Unbounded warehouses with no auto-suspend

**Pattern.** A warehouse left running with `AUTO_SUSPEND` set to never or 1 hour.

**Why bad.** Compute cost while idle. A development warehouse running overnight can quietly eat the budget.

**Better.** `AUTO_SUSPEND = 60` (one minute) is fine for most use cases. The resume cost is one billing minute; the savings on idle time dwarf it.

## 16. `MERGE` written as `DELETE` + `INSERT`

**Pattern.**
```sql
DELETE FROM target WHERE id IN (SELECT id FROM staging);
INSERT INTO target SELECT * FROM staging;
```

**Why bad.** Two statements, not atomic, fights the optimizer.

**Better.** Single `MERGE` statement with `WHEN MATCHED THEN UPDATE` and `WHEN NOT MATCHED THEN INSERT`.

## 17. Unguarded `CREATE OR REPLACE` on tables others depend on

**Pattern.** `CREATE OR REPLACE TABLE prod.customers AS SELECT ...;`

**Why bad.** `CREATE OR REPLACE TABLE` drops and recreates — any open transactions, dependent views with grants, or downstream sessions get disrupted. For high-traffic tables, this can cause downtime.

**Better.** Write to `prod.customers_new`, then `ALTER TABLE ... SWAP WITH` for an atomic switch. Or use `INSERT OVERWRITE` if the schema doesn't change.

## 18. Implicit cross-database / cross-schema references without `USE` discipline

**Pattern.** `SELECT * FROM customers` (no schema/database prefix) inside a script that may run with different `current_schema`.

**Why bad.** Behavior depends on the caller's session state. Hard to debug; works in dev, breaks in prod.

**Better.** Fully qualify (`db.schema.table`) for production code, or explicitly set context with `USE SCHEMA` at script start.

---

When reviewing, name the pattern by number when relevant — it makes the review compact and easy to look up later.
