# Snowpark Python — Best Practices for Review

Snowpark is a lazy DataFrame API that compiles to SQL on the Snowflake side. Most performance problems come from breaking the laziness (pulling data to the client) or breaking the SQL push-down (using Python operations the planner can't translate).

## Lazy evaluation discipline

Snowpark DataFrames are lazy: `.filter`, `.with_column`, `.join`, `.group_by` all build up a plan but don't execute. Execution happens on **action** methods:

- `.collect()` — pull rows to the Python client (small results only)
- `.to_pandas()` — pull rows into a pandas DataFrame (small results only)
- `.show()` — print first N rows (debugging)
- `.count()` — execute and return scalar
- `.save_as_table(...)`, `.write.*` — materialize on Snowflake
- `.cache_result()` — execute, store on Snowflake, return a new DataFrame referencing the cached result

**Findings to flag:**
- `.collect()` on a query that returns more than a few thousand rows — pulls them into Python memory, defeats the purpose of running on Snowflake.
- `.to_pandas()` followed by pandas operations that could have stayed in Snowpark — moves compute off-warehouse and bottlenecks on the client.
- Iterating over `.collect()` results to issue more queries — this is a "row-by-agonizing-row" anti-pattern; restructure as a single batch operation.

## Caching with `.cache_result()`

`cache_result()` materializes a DataFrame to a temporary Snowflake table and returns a DataFrame reading from it. It's the right tool when:

- The same DataFrame is reused in multiple downstream operations, AND
- Recomputing it would be expensive.

It's the wrong tool when:

- The DataFrame is used once. (No benefit.)
- The DataFrame is small enough that recomputation is cheap. (No benefit.)
- You're worried about consistency. (Cache doesn't solve consistency; lazy re-execution is already consistent within a session.)

Calling `.cache_result()` on every DataFrame "just in case" is a common over-correction — flag it.

## UDFs and UDTFs

- **Built-in functions first.** Snowflake has `F.length`, `F.split_part`, `F.regexp_replace`, `F.date_trunc`, `F.lag`, hundreds more. If a built-in exists, use it.
- **SQL UDF** for simple expressions that aren't built-in. Cheaper than Python UDF.
- **Python UDF** for moderately complex logic that needs Python. Vectorized when possible (`@udf` with `pandas_udf`-style batching).
- **Python UDTF** for "one row in, many rows out" — table-valued functions.
- **Stored procedure** for orchestration (multi-step, transactional logic), not for transformations. A stored proc is not a UDF.

Anti-patterns to flag:
- A Python UDF that wraps `re.match` or `str.upper` — use the built-in `F.regexp_like` / `F.upper`.
- A Python UDF that issues another Snowflake query — almost certainly wrong; redesign.
- A scalar UDF called millions of times in a SELECT — at minimum, vectorize.

## Session management

- **One Session per script.** Don't create multiple Sessions; they cost connections and bypass pooling.
- **Pass Session as a parameter** to functions rather than reading from a global. Easier to test.
- **Close Sessions explicitly** in long-running scripts to release the warehouse. In a Streamlit app, use `st.cache_resource` to memoize the Session.

## Materialization patterns

- `.write.mode("overwrite").save_as_table("LIB.TABLE")` — full refresh. The Snowpark equivalent of `CREATE OR REPLACE TABLE ... AS SELECT`.
- `.write.mode("append").save_as_table(...)` — incremental append.
- `.write.mode("errorifexists")` — strict.
- `.write.mode("ignore")` — skip if exists.

If the code uses `mode("overwrite")` in a way that risks losing data on partial failure, suggest a swap pattern: write to `..._staging`, then `ALTER TABLE ... SWAP WITH` for atomicity.

## Joins and window functions in Snowpark

- Match the join keys' types — Snowpark surfaces type mismatch errors more clearly than SQL, but it's still a common cause of unexpected NULLs.
- Use `Window.partition_by(...).order_by(...)` for window functions; chain `F.row_number().over(w)`, `F.lag(...).over(w)`, etc.
- For "latest row per group", the idiomatic Snowpark pattern is:
  ```python
  w = Window.partition_by("customer_id").order_by(F.col("ts").desc())
  latest = df.with_column("_rn", F.row_number().over(w)).filter(F.col("_rn") == 1).drop("_rn")
  ```

## Logging and debugging

- `df.explain()` shows the compiled SQL plan — extremely useful in review.
- `df.queries` shows the SQL Snowpark would run.
- For schema introspection, `df.schema` and `df.columns`.

If review finds an opaque Snowpark chain, recommend the user paste `df.explain()` output — it's the fastest way to spot push-down breaks.

## Python performance traps

- **Looping in Python over DataFrame rows** — almost always wrong.
- **List comprehensions building expressions** are fine as long as they construct lazy expressions (`F.col(...)` calls), not rows.
- **Pandas inside Snowpark UDF** — okay for vectorized UDFs, but watch the memory footprint per batch.
- **`if df.count() > 0:` to guard work** — incurs a query. Better: structure the work so it's safe on empty inputs.

## What to surface

Snowpark reviews benefit from concrete, runnable suggestions. If you find a `.collect()` that should be `.save_as_table()`, say so and give the one-line fix. If you find a UDF that could be a built-in, name the built-in.
