# High-Risk Conversion Patterns

These are the SAS constructs where naive translation goes wrong. For each, this file documents the *semantics* of the SAS construct, the Snowflake equivalent, and the failure modes to avoid.

If you find one of these in the source, slow down and consult this file before emitting the translation.

## Missing values

**SAS semantics.** Numeric missing is `.` and sorts *less than* every real number — `1 > .` is true, `min(., 5) = .`. SAS also has special missings `.A` through `.Z` and `._`. Character missing is `''` (zero-length string). Comparisons quietly include missings: `if x < 100` matches missings too.

**Snowflake equivalent.** NULL. `NULL < 100` is unknown (treated as false in WHERE). `NULLS FIRST` / `NULLS LAST` controls sort placement; the default is `NULLS LAST` in `ORDER BY ASC` and `NULLS FIRST` in `ORDER BY DESC` (opposite of SAS default).

**Translation rules.**
- `IF x = .` → `WHERE x IS NULL`
- `IF MISSING(x)` → `WHERE x IS NULL`
- `IF x < 100` (SAS, includes missings) → `WHERE x < 100 OR x IS NULL` if you suspect that was intended, otherwise just `WHERE x < 100` and note the change in Notes.
- Sorting where missings need to come first (SAS default) → add explicit `NULLS FIRST` to the `ORDER BY`.
- Special missings (`.A`..`.Z`, `._`) have no Snowflake analog — surface as a caveat. If they encode metadata (e.g., reason for missingness), recommend a sentinel column.

## BY-group processing and FIRST. / LAST.

**SAS semantics.** A DATA step with `BY id;` creates automatic boolean variables `FIRST.id` (true on the first row of each new id-group) and `LAST.id` (true on the last). Requires the input to be sorted on `id` (or indexed). With multiple BY vars, you get `FIRST.var1`, `FIRST.var2`, etc. — `FIRST.var1` is true at any change of var1; `FIRST.var2` is true at any change of var2 *within* the same var1 group.

**Snowflake equivalent.** Window functions.

```sql
-- LAST.customer_id only:
SELECT *
FROM raw.orders
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) = 1;
```

```sql
-- BOTH first and last per group, marked:
SELECT *,
  ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date)             AS rn_first,
  ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC)         AS rn_last,
  rn_first = 1 AS is_first,
  rn_last  = 1 AS is_last
FROM raw.orders;
```

For nested BY vars, partition by the outer and order by the inner; or use multiple `ROW_NUMBER()` calls with different partitioning.

**Common gotcha.** A SAS DATA step with `BY id` that does `if first.id then n=0; n+1; if last.id then output;` is producing a per-group row count — translate to `COUNT(*) OVER (PARTITION BY id)` + `QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY ...) = 1`, not by simulating the counter.

## RETAIN

**SAS semantics.** Carries a value across DATA step iterations. Without RETAIN, a variable created in the step is reset to missing each iteration. Variables read by `SET` are *implicitly* retained (this is a frequent surprise).

**Three common idioms and their Snowflake translations:**

1. **Running total within group.**
   ```sas
   data x; set y; by id; retain total 0; if first.id then total = 0; total + amount; run;
   ```
   ```sql
   SELECT *,
     SUM(amount) OVER (PARTITION BY id ORDER BY ... ROWS UNBOUNDED PRECEDING) AS total
   FROM y;
   ```

2. **Last-observation-carried-forward (LOCF).**
   ```sas
   data x; set y; by id; retain last_price; if not missing(price) then last_price = price; run;
   ```
   ```sql
   SELECT *,
     LAST_VALUE(price IGNORE NULLS) OVER (PARTITION BY id ORDER BY date) AS last_price
   FROM y;
   ```

3. **Initialize once, modify conditionally.**
   ```sas
   data x; set y; retain counter 0; if condition then counter + 1; run;
   ```
   This is a sequential state machine — translate to `SUM(CASE WHEN condition THEN 1 ELSE 0 END) OVER (ORDER BY ...)`.

**When you can't translate.** Complex sequential logic with RETAIN (state machines, look-ahead) sometimes doesn't have a window-function equivalent. In that case, recommend a Snowpark UDTF or a Python loop using `df.collect()` for small data — and call it out as not idiomatic.

## MERGE with BY

**SAS semantics.** `merge a b; by id;` does **not** join. It interleaves observations by key:
- If key value is in both → emit one row, columns from `b` *overwrite* columns from `a` where they share names.
- If only in `a` → emit `a`'s row, `b`'s columns are missing.
- If only in `b` → emit `b`'s row, `a`'s columns are missing.

With `IN=` flags (`merge a(in=ina) b(in=inb)`), you can subset: `if ina and inb;` keeps inner-join rows, `if ina and not inb;` keeps left-only, etc.

**Snowflake equivalent.** `FULL OUTER JOIN` with `COALESCE(b.col, a.col)` for overlapping columns.

```sql
SELECT
  COALESCE(b.id, a.id) AS id,
  COALESCE(b.name,   a.name)   AS name,
  COALESCE(b.status, a.status) AS status
FROM a
FULL OUTER JOIN b USING (id);
```

For `IN=` logic, add `WHERE` filters:
- `if a and b;` → `WHERE a.id IS NOT NULL AND b.id IS NOT NULL` (with `JOIN ... ON` instead of `USING`)
- `if a and not b;` → `WHERE b.id IS NULL`

**Warning.** MERGE with 3+ datasets is a code smell even in SAS — confirm intent with the user. Order matters: later datasets overlay earlier ones.

## Macros and macro variables

**SAS macro semantics.** The macro processor runs *before* SAS compilation — it produces text that is then parsed as SAS code. `&var` is text substitution. `%MACRO foo(p);` defines a parameterized text template. `%IF`, `%DO`, `%LET` control text generation, not data.

**Translation strategies.**

| Source pattern | Snowflake target |
| --- | --- |
| `%let cutoff = 2024-01-01;` used once | Python variable (Snowpark) or `SET cutoff = '2024-01-01';` (SQL) |
| `%MACRO foo; (body) %MEND; %foo;` invoked once | Inline the body |
| `%MACRO foo(p1, p2); ... %MEND;` invoked many times | Snowpark Python function returning a DataFrame (do **not** emit `CREATE PROCEDURE` — see SKILL.md's no-stored-procedures rule) |
| `%IF &month = 12 %THEN ...` controlling which code gets generated | Resolve at translation time if `&month` is known; otherwise convert to runtime `CASE` / `IFF` |
| `%DO i = 1 %TO 12; ... %END;` generating 12 copies of code | Python for-loop generating 12 transforms, or one query with `WHERE month IN (1..12)` |
| `&&var&i` (double ampersand, indirect reference) | Python dict lookup, or pre-resolve at translation time |

**When parameters are dynamic.** Resolve the most likely values, generate the translation for them, and put a Note: "Macro `foo` invoked with parameter `&month` resolved as `12`; if invoked with other values the translation must be regenerated."

## Formats and informats

**SAS format semantics.** A format is a display rule — `format col yymmdd10.;` makes the column print as `2024-01-15` but stores the underlying number. `PUT(value, format.)` returns the formatted string. `INPUT(string, informat.)` parses a string into a typed value.

**Translation by format type:**

| SAS format kind | Snowflake approach |
| --- | --- |
| Built-in date/time format (`date9.`, `mmddyy10.`, `datetime20.`, etc.) | `TO_VARCHAR(col, 'fmt')` — see format crosswalk in `sas-analyzer/references/platform-9.4.8.md` |
| Built-in numeric (`comma12.`, `dollar12.2`, `percent8.2`, `z8.`) | `TO_VARCHAR(col, 'fmt')` with Snowflake numeric format string |
| User-defined value format (`proc format; value $regionf 'E'='East' ...;`) | Inline `CASE` if small; lookup table + `LEFT JOIN` if large |
| User-defined range format (`value salaryf low-30000='Low' 30001-60000='Mid' 60001-high='High'`) | `CASE WHEN col BETWEEN ... THEN ... END`, or lookup table with start/end columns |
| Informat — parsing | `TO_DATE`, `TO_TIMESTAMP`, `TO_NUMBER`, `TRY_TO_*` — prefer the `TRY_` variants for resilience |

**For shared format catalogs**: dump with `PROC FORMAT CNTLOUT=` on the SAS side, load to Snowflake as a lookup table, join. Document this as a one-time migration step.

## Date and datetime arithmetic

**SAS semantics.** Dates are integers (days since 1960-01-01); datetimes are floats (seconds since 1960-01-01 00:00:00). Date literals: `'01JAN2024'd`, `'01JAN2024:09:30:00'dt`. Functions: `TODAY()`, `DATETIME()`, `INTCK('month', a, b)` (count intervals), `INTNX('month', d, 1)` (advance interval).

**Snowflake semantics.** `DATE` and `TIMESTAMP_*` types are native. No SAS epoch.

**Translation rules.**
- Date literals → `DATE '2024-01-01'` / `TIMESTAMP '2024-01-01 09:30:00'`. Don't preserve the SAS epoch number.
- `INTCK('month', a, b)` → `DATEDIFF('month', a, b)`. Caveat: `INTCK` counts boundary crossings by default (`'discrete'`); pass `'continuous'` for full intervals. `DATEDIFF` is discrete by default. If the SAS code uses `'continuous'`, adjust the Snowflake math.
- `INTNX('month', d, 1)` → `DATEADD('month', 1, d)`. With alignment `'same'` (preserve day-of-month), watch for shorter target months — use `LAST_DAY` logic.
- `TODAY()` / `DATE()` → `CURRENT_DATE`
- `DATETIME()` → `CURRENT_TIMESTAMP`
- `DATEPART(dt)` → `DATE(dt)`
- `TIMEPART(dt)` → `TIME(dt)`
- Implicit comparisons of numeric dates → cast both sides to `DATE` in Snowflake.

## PROC SQL dialect quirks

**`CALCULATED`** — references a column alias in the same SELECT list. Not standard SQL.
```sas
select x, x*2 as y, calculated y + 1 as z from t;
```
Snowflake: repeat the expression, or use a CTE.
```sql
SELECT x, x*2 AS y, x*2 + 1 AS z FROM t;
-- or
WITH s AS (SELECT x, x*2 AS y FROM t)
SELECT *, y + 1 AS z FROM s;
```

**`OUTOBS=`** — output row limit. Translates to `LIMIT n`.

**`INOBS=`** — input row limit (read at most n from each table). No exact Snowflake equivalent; use `LIMIT` in a subquery if absolutely needed, but usually this is a SAS-debugging artifact and can be dropped.

**`MONOTONIC()`** — pseudo-column for row order. Translates to `ROW_NUMBER() OVER (ORDER BY ...)`. Note: PROC SQL `MONOTONIC()` without `ORDER BY` is non-deterministic — surface as a caveat.

**`DICTIONARY.` tables** — SAS's information_schema. Translate to Snowflake's `INFORMATION_SCHEMA` views (`TABLES`, `COLUMNS`, etc.).

**Implicit RIGHT JOIN ordering** — SAS PROC SQL is usually fine, but some patterns differ; favor explicit `LEFT JOIN` over `RIGHT JOIN` in the translation for clarity.

## Implicit numeric → character coercion

SAS does implicit type conversion in many contexts (with a NOTE in the log). Snowflake is stricter — you'll get errors or unexpected results.

When you see `where char_col = 5`, translate as `WHERE TO_NUMBER(char_col) = 5` (or `WHERE char_col = '5'` if you suspect the numeric was the typo).

## What to do when none of these patterns fit

If the SAS code uses a construct you can't confidently translate:

1. Emit a stub in both SQL and Snowpark: `-- TODO: <description of what SAS did>`.
2. Add a Note explaining what the construct does and why it didn't translate.
3. Suggest a path forward — usually one of: re-implement in Snowpark Python with `.collect()` and Python logic; leave it in SAS and call from Snowflake; abandon the construct if it's not essential.

Don't fabricate a translation that's almost-right but actually wrong. The user can debug honest gaps; they can't debug confidently-wrong translations.
