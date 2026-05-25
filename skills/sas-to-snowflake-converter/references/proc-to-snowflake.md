# PROC-by-PROC Conversion to Snowflake

This file is the workhorse. For each common PROC / DATA-step pattern, here are the Snowflake SQL and Snowpark equivalents, with worked examples.

## Table of contents
- DATA step — basics
- DATA step — BY-group with FIRST./LAST.
- DATA step — RETAIN (running totals, LOCF)
- DATA step — MERGE BY
- PROC SQL
- PROC SORT
- PROC MEANS / PROC SUMMARY
- PROC FREQ
- PROC TRANSPOSE
- PROC FORMAT (value formats)
- PROC IMPORT / EXPORT
- Macro variables and macros

---

## DATA step — basics

SAS:
```sas
data work.orders_clean;
    set raw.orders;
    where region = 'EAST';
    revenue = qty * price;
    keep order_id customer_id revenue;
run;
```

Snowflake SQL:
```sql
CREATE OR REPLACE TABLE WORK.ORDERS_CLEAN AS
SELECT
    order_id,
    customer_id,
    qty * price AS revenue
FROM RAW.ORDERS
WHERE region = 'EAST';
```

Snowpark:
```python
orders_clean = (
    session.table("RAW.ORDERS")
    .filter(F.col("region") == "EAST")
    .with_column("revenue", F.col("qty") * F.col("price"))
    .select("order_id", "customer_id", "revenue")
)
orders_clean.write.mode("overwrite").save_as_table("WORK.ORDERS_CLEAN")
```

---

## DATA step — BY-group with FIRST./LAST.

SAS — keep last observation per customer:
```sas
proc sort data=raw.orders out=work.sorted; by customer_id order_date; run;

data work.last_order;
    set work.sorted;
    by customer_id;
    if last.customer_id;
run;
```

Snowflake SQL — use `QUALIFY` with `ROW_NUMBER()`:
```sql
CREATE OR REPLACE TABLE WORK.LAST_ORDER AS
SELECT *
FROM RAW.ORDERS
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY customer_id ORDER BY order_date DESC
) = 1;
```

Snowpark:
```python
from snowflake.snowpark.window import Window
w = Window.partition_by("customer_id").order_by(F.col("order_date").desc())
last_order = (
    session.table("RAW.ORDERS")
    .with_column("_rn", F.row_number().over(w))
    .filter(F.col("_rn") == 1)
    .drop("_rn")
)
```

---

## DATA step — RETAIN (running totals, LOCF)

SAS — running total within customer:
```sas
proc sort data=raw.txn out=work.s; by customer_id txn_date; run;
data work.running;
    set work.s;
    by customer_id;
    retain running_total 0;
    if first.customer_id then running_total = 0;
    running_total + amount;          /* sum statement */
run;
```

Snowflake SQL:
```sql
CREATE OR REPLACE TABLE WORK.RUNNING AS
SELECT *,
       SUM(amount) OVER (
           PARTITION BY customer_id
           ORDER BY txn_date
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS running_total
FROM RAW.TXN;
```

SAS — LOCF (last observation carried forward) for missing prices:
```sas
data work.locf;
    set work.prices;
    by item_id;
    retain last_price;
    if not missing(price) then last_price = price;
    output;
run;
```

Snowflake SQL:
```sql
SELECT *,
       LAST_VALUE(price IGNORE NULLS) OVER (
           PARTITION BY item_id ORDER BY price_date
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS last_price
FROM WORK.PRICES;
```

---

## DATA step — MERGE BY

SAS — overlay updates onto a base table:
```sas
data work.combined;
    merge work.base(in=a) work.updates(in=b);
    by customer_id;
    /* columns from updates overwrite base where present */
run;
```

Snowflake SQL — semantics: full outer join, b overwrites a:
```sql
CREATE OR REPLACE TABLE WORK.COMBINED AS
SELECT
    COALESCE(b.customer_id, a.customer_id) AS customer_id,
    COALESCE(b.name,        a.name)        AS name,
    COALESCE(b.status,      a.status)      AS status
    -- list every column; b takes precedence
FROM WORK.BASE   a
FULL OUTER JOIN WORK.UPDATES b
  ON a.customer_id = b.customer_id;
```

If `IN=` variables drive logic (e.g., `if a and not b`), translate to explicit `WHERE a.customer_id IS NOT NULL AND b.customer_id IS NULL` patterns. Document this — IN-flag logic is one of the most error-prone SAS constructs to migrate.

---

## PROC SQL

SAS — note `CALCULATED` and `OUTOBS=`:
```sas
proc sql outobs=100;
    create table work.top as
    select customer_id,
           sum(revenue) as total,
           calculated total / count(*) as avg_per_order
    from raw.orders
    group by customer_id
    having total > 1000
    order by total desc;
quit;
```

Snowflake SQL:
```sql
CREATE OR REPLACE TABLE WORK.TOP AS
WITH agg AS (
    SELECT customer_id,
           SUM(revenue) AS total,
           SUM(revenue) / COUNT(*) AS avg_per_order
    FROM RAW.ORDERS
    GROUP BY customer_id
    HAVING SUM(revenue) > 1000
)
SELECT * FROM agg
ORDER BY total DESC
LIMIT 100;
```

CALCULATED has no direct equivalent — repeat the expression or push to a CTE.

`MONOTONIC()` (a SAS row-number pseudo-column) → `ROW_NUMBER() OVER (ORDER BY ...)` with an explicit ordering. If there's no ordering, the SAS code is non-deterministic; surface as a caveat.

---

## PROC SORT

```sas
proc sort data=raw.orders out=work.sorted nodupkey;
    by customer_id descending order_date;
run;
```

In Snowflake, tables are unordered — `ORDER BY` applies to queries. Translate the **intent**:
- `OUT=` only → `CREATE TABLE ... AS SELECT ... ORDER BY ...` (Snowflake will sort on clustering, not storage; consider `CLUSTER BY` if downstream queries depend on it).
- `NODUPKEY` (dedupe by BY vars) → `QUALIFY ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...) = 1`.
- `NODUPRECS` (dedupe identical rows) → `SELECT DISTINCT *`.

If PROC SORT is just preparing data for a downstream `BY` DATA step, you usually don't need to translate the SORT separately — fold the ordering into the window function in the next step.

---

## PROC MEANS / PROC SUMMARY

```sas
proc means data=raw.orders n mean std min max sum nway noprint;
    class region product;
    var revenue qty;
    output out=work.stats sum= n= / autoname;
run;
```

Snowflake SQL:
```sql
CREATE OR REPLACE TABLE WORK.STATS AS
SELECT
    region,
    product,
    COUNT(*)        AS _freq_,
    SUM(revenue)    AS revenue_sum,
    SUM(qty)        AS qty_sum,
    COUNT(revenue)  AS revenue_n,
    COUNT(qty)      AS qty_n
FROM RAW.ORDERS
GROUP BY region, product;
```

Notes:
- `NWAY` means "only output the highest-level grouping" — without it, PROC MEANS produces subtotals for every subset of the CLASS variables. Translate that to `GROUP BY GROUPING SETS` or `GROUP BY ROLLUP/CUBE`.
- The `_TYPE_` and `_FREQ_` columns SAS auto-adds: `_FREQ_` = `COUNT(*)`; `_TYPE_` encodes which class variables are active in that row (bitmask). Reconstruct only if downstream code reads them.

---

## PROC FREQ

```sas
proc freq data=raw.orders;
    tables region*product / out=work.xtab;
run;
```

Snowflake SQL:
```sql
CREATE OR REPLACE TABLE WORK.XTAB AS
SELECT region, product, COUNT(*) AS count
FROM RAW.ORDERS
GROUP BY region, product;
```

For chi-square tests and other statistics in PROC FREQ — those don't translate; surface as out-of-scope.

---

## PROC TRANSPOSE

```sas
proc transpose data=raw.long out=work.wide(drop=_name_) prefix=q;
    by customer_id;
    id quarter;     /* quarter has values 1,2,3,4 */
    var revenue;
run;
```

Snowflake SQL — use `PIVOT`:
```sql
CREATE OR REPLACE TABLE WORK.WIDE AS
SELECT *
FROM (
    SELECT customer_id, quarter, revenue FROM RAW.LONG
)
PIVOT (
    SUM(revenue) FOR quarter IN (1 AS q1, 2 AS q2, 3 AS q3, 4 AS q4)
);
```

If the ID values are not known ahead of time, use `PIVOT(SUM(revenue) FOR quarter IN (ANY))` (Snowflake supports dynamic PIVOT) and document that the column set is data-driven.

Reverse (wide → long): `UNPIVOT`.

---

## PROC FORMAT (value formats)

```sas
proc format;
    value $regionf
        'E' = 'East'
        'W' = 'West'
        other = 'Unknown';
run;

data work.labeled;
    set raw.orders;
    region_label = put(region, $regionf.);
run;
```

Snowflake SQL — inline as `CASE` if small, lookup table if large:
```sql
CREATE OR REPLACE TABLE WORK.LABELED AS
SELECT *,
       CASE region
           WHEN 'E' THEN 'East'
           WHEN 'W' THEN 'West'
           ELSE 'Unknown'
       END AS region_label
FROM RAW.ORDERS;
```

For large or shared formats, extract `PROC FORMAT CNTLOUT=` to a Snowflake table and `LEFT JOIN`.

---

## PROC IMPORT / EXPORT

```sas
proc import datafile='/path/orders.csv' out=raw.orders dbms=csv replace;
    getnames=yes;
run;
```

In Snowflake the analog is staging + `COPY INTO`:
```sql
COPY INTO RAW.ORDERS
FROM @my_stage/orders.csv
FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1);
```

But you usually don't translate IMPORT/EXPORT — they're load/unload, not business logic. Flag for the data team.

---

## Macro variables and macros

```sas
%let cutoff = 2024-01-01;
%let region = EAST;

data work.recent;
    set raw.orders;
    where order_date >= "&cutoff"d and region = "&region";
run;
```

Snowpark — macro vars become Python variables:
```python
cutoff = "2024-01-01"
region = "EAST"

recent = (
    session.table("RAW.ORDERS")
    .filter(
        (F.col("order_date") >= F.to_date(F.lit(cutoff)))
        & (F.col("region") == region)
    )
)
```

Snowflake SQL — use session variables or Jinja-style parameters depending on how the user runs SQL:
```sql
SET cutoff = '2024-01-01';
SET region = 'EAST';

CREATE OR REPLACE TABLE WORK.RECENT AS
SELECT * FROM RAW.ORDERS
WHERE order_date >= TO_DATE($cutoff)
  AND region = $region;
```

For `%MACRO foo(...);` definitions invoked many times → convert to a Python function returning a DataFrame. Stored procedures (`CREATE PROCEDURE`) are explicitly disallowed — see the no-stored-procedures rule in SKILL.md.

If the macro generates code conditionally (`%IF`, `%DO %TO`) and the parameters aren't known at translation time, that's the hardest case — you usually have to convert to runtime logic in Snowpark and accept that the translation is now an interpreter for the macro's intent rather than a 1:1 port.

---

## Quick reference: what to reach for

| If you see... | Default Snowflake construct |
| --- | --- |
| `BY var; if first.var / last.var` | `QUALIFY ROW_NUMBER() OVER (PARTITION BY var ORDER BY ...) = 1` |
| `RETAIN` running total | `SUM(...) OVER (PARTITION BY ... ORDER BY ...)` |
| `RETAIN` LOCF | `LAST_VALUE(... IGNORE NULLS) OVER (...)` |
| `MERGE a b; BY id;` | `FULL OUTER JOIN ... USING(id)` + `COALESCE(b.col, a.col)` |
| `PROC TRANSPOSE` (known IDs) | `PIVOT` |
| `PROC TRANSPOSE` (unknown IDs) | dynamic `PIVOT(... FOR ... IN (ANY))` |
| `PROC SORT NODUPKEY` | `QUALIFY ROW_NUMBER() OVER (...) = 1` |
| `PROC FORMAT` (small) | `CASE` expression |
| `PROC FORMAT` (large/shared) | lookup table + `LEFT JOIN` |
| `PROC MEANS NWAY` | `GROUP BY` |
| `PROC MEANS` no NWAY | `GROUP BY GROUPING SETS / ROLLUP / CUBE` |
| `&macro_var` | Python variable / `$session_var` |
| `%MACRO foo(...)` invoked many times | Python function (Snowpark) — do **not** emit `CREATE PROCEDURE` |
