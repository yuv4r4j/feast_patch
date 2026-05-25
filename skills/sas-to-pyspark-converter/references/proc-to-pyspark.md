# PROC-by-PROC Conversion to PySpark 3.4.1

Worked examples for the common SAS patterns. Each section has SAS source, the PySpark DataFrame translation, and (where useful) a Spark SQL form.

## Table of contents
- DATA step — basics
- DATA step — BY-group with FIRST./LAST.
- DATA step — RETAIN
- DATA step — MERGE BY
- PROC SQL
- PROC SORT
- PROC MEANS / PROC SUMMARY
- PROC FREQ
- PROC TRANSPOSE
- PROC FORMAT
- PROC IMPORT / EXPORT
- Macros

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

PySpark:
```python
orders_clean = (
    spark.table("raw.orders")
    .filter(F.col("region") == "EAST")
    .withColumn("revenue", F.col("qty") * F.col("price"))
    .select("order_id", "customer_id", "revenue")
)
orders_clean.write.mode("overwrite").saveAsTable("work.orders_clean")
```

Spark SQL:
```sql
CREATE OR REPLACE TABLE work.orders_clean AS
SELECT order_id, customer_id, qty * price AS revenue
FROM raw.orders
WHERE region = 'EAST';
```

---

## DATA step — BY-group with FIRST./LAST.

SAS — keep last order per customer:
```sas
proc sort data=raw.orders out=work.sorted; by customer_id order_date; run;
data work.last_order; set work.sorted; by customer_id; if last.customer_id; run;
```

PySpark:
```python
from pyspark.sql.window import Window

w = Window.partitionBy("customer_id").orderBy(F.col("order_date").desc())
last_order = (
    spark.table("raw.orders")
    .withColumn("_rn", F.row_number().over(w))
    .filter(F.col("_rn") == 1)
    .drop("_rn")
)
```

Spark SQL (Spark 3.4 supports QUALIFY):
```sql
CREATE OR REPLACE TABLE work.last_order AS
SELECT *
FROM raw.orders
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) = 1;
```

---

## DATA step — RETAIN

### Running total within group

SAS:
```sas
proc sort data=raw.txn out=work.s; by customer_id txn_date; run;
data work.running;
    set work.s; by customer_id;
    retain running_total 0;
    if first.customer_id then running_total = 0;
    running_total + amount;
run;
```

PySpark:
```python
w = (
    Window.partitionBy("customer_id")
          .orderBy("txn_date")
          .rowsBetween(Window.unboundedPreceding, Window.currentRow)
)
running = (
    spark.table("raw.txn")
    .withColumn("running_total", F.sum("amount").over(w))
)
```

### LOCF — last non-missing carried forward

SAS:
```sas
data work.locf;
    set work.prices; by item_id;
    retain last_price;
    if not missing(price) then last_price = price;
    output;
run;
```

PySpark:
```python
w = (
    Window.partitionBy("item_id")
          .orderBy("price_date")
          .rowsBetween(Window.unboundedPreceding, Window.currentRow)
)
locf = (
    spark.table("work.prices")
    .withColumn("last_price", F.last(F.col("price"), ignorenulls=True).over(w))
)
```

---

## DATA step — MERGE BY

SAS:
```sas
data work.combined;
    merge work.base(in=a) work.updates(in=b);
    by customer_id;
run;
```

PySpark (b's columns overlay a's where both present):
```python
base    = spark.table("work.base")
updates = spark.table("work.updates")
combined = (
    base.alias("a")
        .join(updates.alias("b"), on="customer_id", how="full_outer")
        .select(
            "customer_id",
            F.coalesce(F.col("b.name"),   F.col("a.name")).alias("name"),
            F.coalesce(F.col("b.status"), F.col("a.status")).alias("status"),
        )
)
combined.write.mode("overwrite").saveAsTable("work.combined")
```

For the upsert variant (if the user's target table is Delta or Iceberg), the alternative is `MERGE INTO`:
```sql
-- Requires Delta Lake or Iceberg target
MERGE INTO work.target t
USING work.updates u
ON t.customer_id = u.customer_id
WHEN MATCHED THEN UPDATE SET t.name = u.name, t.status = u.status
WHEN NOT MATCHED THEN INSERT (customer_id, name, status) VALUES (u.customer_id, u.name, u.status);
```

`MERGE INTO` is not supported on plain Parquet / Hive tables in Spark 3.4 — note this requirement explicitly.

---

## PROC SQL

SAS:
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

PySpark:
```python
top = (
    spark.table("raw.orders")
    .groupBy("customer_id")
    .agg(
        F.sum("revenue").alias("total"),
        F.count("*").alias("n_orders"),
    )
    .withColumn("avg_per_order", F.col("total") / F.col("n_orders"))
    .filter(F.col("total") > 1000)
    .orderBy(F.col("total").desc())
    .limit(100)
)
top.write.mode("overwrite").saveAsTable("work.top")
```

Spark SQL:
```sql
CREATE OR REPLACE TABLE work.top AS
WITH agg AS (
    SELECT customer_id,
           SUM(revenue) AS total,
           SUM(revenue) / COUNT(*) AS avg_per_order
    FROM raw.orders
    GROUP BY customer_id
    HAVING SUM(revenue) > 1000
)
SELECT * FROM agg
ORDER BY total DESC
LIMIT 100;
```

`CALCULATED` has no direct equivalent — repeat the expression or use a CTE / chained `withColumn`.

---

## PROC SORT

```sas
proc sort data=raw.orders out=work.sorted nodupkey;
    by customer_id descending order_date;
run;
```

PySpark — translate the *intent*:

- `OUT=` only → `.orderBy(...)` then `.saveAsTable(...)`. Note that Spark output order is not guaranteed to be preserved on read.
- `NODUPKEY` → window row_number == 1.
- `NODUPRECS` → `.dropDuplicates()`.

For NODUPKEY:
```python
w = Window.partitionBy("customer_id").orderBy(F.col("order_date").desc())
sorted_ = (
    spark.table("raw.orders")
    .withColumn("_rn", F.row_number().over(w))
    .filter(F.col("_rn") == 1)
    .drop("_rn")
)
```

If PROC SORT is just preparing data for a downstream BY-step, you usually don't translate the sort separately — fold the ordering into the window function in the next step.

---

## PROC MEANS / PROC SUMMARY

```sas
proc means data=raw.orders n mean std min max sum nway noprint;
    class region product;
    var revenue qty;
    output out=work.stats sum= n= / autoname;
run;
```

PySpark:
```python
stats = (
    spark.table("raw.orders")
    .groupBy("region", "product")
    .agg(
        F.count("*").alias("_freq_"),
        F.sum("revenue").alias("revenue_sum"),
        F.sum("qty").alias("qty_sum"),
        F.count("revenue").alias("revenue_n"),
        F.count("qty").alias("qty_n"),
    )
)
stats.write.mode("overwrite").saveAsTable("work.stats")
```

**Without NWAY** (subtotals at every class subset), use `.rollup` or `.cube`:

```python
# ROLLUP — hierarchy (region, product), (region), ()
stats = (
    spark.table("raw.orders")
    .rollup("region", "product")
    .agg(F.sum("revenue").alias("revenue_sum"))
)
# CUBE — all subsets
stats = (
    spark.table("raw.orders")
    .cube("region", "product")
    .agg(F.sum("revenue").alias("revenue_sum"))
)
```

PROC MEANS' `_TYPE_` column encodes which class vars were active (bitmask). Reconstruct only if downstream code reads it: `F.when(F.col("region").isNotNull(), 1).otherwise(0) + F.when(F.col("product").isNotNull(), 2).otherwise(0)`.

---

## PROC FREQ

```sas
proc freq data=raw.orders;
    tables region*product / out=work.xtab;
run;
```

PySpark:
```python
xtab = (
    spark.table("raw.orders")
    .groupBy("region", "product")
    .agg(F.count("*").alias("count"))
)
xtab.write.mode("overwrite").saveAsTable("work.xtab")
```

For chi-square or other statistics in PROC FREQ — those don't translate cleanly. Either compute in pandas after a `.toPandas()` if the data is small, or use `pyspark.ml.stat.ChiSquareTest` for the statistical test.

---

## PROC TRANSPOSE

```sas
proc transpose data=raw.long out=work.wide(drop=_name_) prefix=q;
    by customer_id;
    id quarter;       /* values 1,2,3,4 */
    var revenue;
run;
```

PySpark (known ID values — fastest):
```python
wide = (
    spark.table("raw.long")
    .groupBy("customer_id")
    .pivot("quarter", [1, 2, 3, 4])
    .agg(F.first("revenue"))
    .toDF("customer_id", "q1", "q2", "q3", "q4")
)
```

PySpark (unknown ID values — slower, requires extra scan):
```python
wide = (
    spark.table("raw.long")
    .groupBy("customer_id")
    .pivot("quarter")
    .agg(F.first("revenue"))
)
```

When the ID values are large in cardinality (>1000), pivot performance degrades — consider a different output schema (e.g., keep long, use ARRAY/MAP).

For the reverse (wide → long): use `stack()` in SQL or build an unpivot expression:
```python
long = wide.select(
    "customer_id",
    F.expr("stack(4, 'q1', q1, 'q2', q2, 'q3', q3, 'q4', q4) as (quarter, revenue)")
)
```

---

## PROC FORMAT

```sas
proc format;
    value $regionf 'E'='East' 'W'='West' other='Unknown';
run;

data work.labeled;
    set raw.orders;
    region_label = put(region, $regionf.);
run;
```

PySpark (inline CASE for small formats):
```python
labeled = (
    spark.table("raw.orders")
    .withColumn("region_label",
        F.when(F.col("region") == "E", "East")
         .when(F.col("region") == "W", "West")
         .otherwise("Unknown")
    )
)
```

For large or shared formats, dump the catalog (`PROC FORMAT CNTLOUT=`) and broadcast-join:
```python
fmt = spark.table("work.region_format")    # columns: code, label
labeled = (
    spark.table("raw.orders")
    .join(F.broadcast(fmt), F.col("region") == fmt.code, "left")
    .withColumn("region_label", F.coalesce(fmt.label, F.lit("Unknown")))
    .drop("code", "label")
)
```

---

## PROC IMPORT / EXPORT

SAS:
```sas
proc import datafile='/path/orders.csv' out=raw.orders dbms=csv replace;
    getnames=yes;
run;
```

PySpark:
```python
orders = (
    spark.read
         .option("header", True)
         .option("inferSchema", True)
         .csv("/path/orders.csv")
)
orders.write.mode("overwrite").saveAsTable("raw.orders")
```

For production loads, prefer providing a schema explicitly (`spark.read.schema(my_schema).csv(...)`) over `inferSchema` — it's faster and avoids type-drift.

For Excel: PySpark doesn't read XLSX natively; use the `spark-excel` package or convert to CSV/Parquet upstream.

---

## Macros and macro variables

SAS:
```sas
%let cutoff = 2024-01-01;
%let region = EAST;

data work.recent;
    set raw.orders;
    where order_date >= "&cutoff"d and region = "&region";
run;
```

PySpark:
```python
cutoff = "2024-01-01"
region = "EAST"

recent = (
    spark.table("raw.orders")
    .filter(
        (F.col("order_date") >= F.to_date(F.lit(cutoff)))
        & (F.col("region") == region)
    )
)
```

For parameterized macros invoked many times → Python function:
```python
def monthly_summary(spark: SparkSession, source_table: str, month: str) -> DataFrame:
    return (
        spark.table(source_table)
        .filter(F.date_format("order_date", "yyyy-MM") == month)
        .groupBy("customer_id")
        .agg(F.sum("revenue").alias("total_revenue"))
    )

# call:
jan = monthly_summary(spark, "raw.orders", "2024-01")
feb = monthly_summary(spark, "raw.orders", "2024-02")
```

For conditional macro logic (`%IF`, `%DO`) that can't be resolved at translation time → convert to runtime logic with `F.when` or build the DataFrame chain conditionally in Python.

---

## Quick reference

| If you see... | Default PySpark construct |
| --- | --- |
| `BY var; if first.var / last.var` | `Window.partitionBy(var).orderBy(...)` + `F.row_number().over(w) == 1` |
| `RETAIN` running total | `F.sum(...).over(Window.partitionBy(...).orderBy(...).rowsBetween(unboundedPreceding, currentRow))` |
| `RETAIN` LOCF | `F.last(col, ignorenulls=True).over(...)` |
| `MERGE a b; BY id;` | `a.join(b, "id", "full_outer")` + `F.coalesce(b.col, a.col)`. Or `MERGE INTO` if target is Delta/Iceberg. |
| `PROC TRANSPOSE` known IDs | `.groupBy(...).pivot("col", values).agg(...)` |
| `PROC TRANSPOSE` unknown IDs | `.groupBy(...).pivot("col").agg(...)` |
| `PROC SORT NODUPKEY` | window row_number == 1 |
| `PROC FORMAT` small | `F.when(...).when(...).otherwise(...)` |
| `PROC FORMAT` large | broadcast-join lookup DataFrame |
| `PROC MEANS NWAY` | `.groupBy(...).agg(...)` |
| `PROC MEANS` w/o NWAY | `.rollup(...).agg(...)` or `.cube(...).agg(...)` |
| `&macro_var` | Python variable |
| `%MACRO foo(...)` invoked many times | Python function |
| date literal `'01JAN2024'd` | `F.to_date(F.lit("2024-01-01"))` |
| `PUT(x, format.)` | `F.date_format` for dates / `F.format_string` for numerics |
| `INPUT(s, informat.)` | `F.to_date`, `F.to_timestamp`, `.cast` |
| `INTCK / INTNX` | `F.datediff`, `F.months_between`, `F.add_months`, `F.date_add` |
| `WHERE x = .` | `.filter(F.col("x").isNull())` |
