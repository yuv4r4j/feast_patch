# SAS 9.4 Maintenance 8 (9.4.8.0) — Platform Notes

SAS 9.4 M8 is the eighth (and effectively final) maintenance release of the 9.4 platform. Most M8 behavior is identical to earlier 9.4 releases — this file calls out what's different, what's worth knowing for conversion, and how the platform options interact with the code you're translating.

## Encoding and locale

- Default session encoding depends on how the SAS server was installed. Common values: `WLATIN1`, `UTF-8`, `EUC-JP`.
- M8 ships with broader Unicode-related fixes but does **not** change the default encoding for existing installs.
- The encoding affects string length (`LENGTH x $20;` is bytes, not characters, in non-UTF8 encodings) — when converting to Snowflake, treat character lengths as character counts (Snowflake `VARCHAR(20)` is always 20 characters in UTF-8) and flag anything that depends on byte-level slicing (`SUBSTR`, `K*` k-functions) for review.

## Options that affect translation

The `OPTIONS` statement sets session-level switches. Common ones and what they mean for your translation:

| OPTION | Effect | Snowflake equivalent / handling |
| --- | --- | --- |
| `MISSING='.';` or `MISSING=' ';` | Character used to print missings | Cosmetic; ignore in conversion |
| `YEARCUTOFF=1920;` | How 2-digit years parse | Snowflake doesn't auto-parse 2-digit years; if INPUT uses `yymmdd6.`, force `TO_DATE(col, 'YYMMDD')` and resolve the century explicitly. |
| `DATESTYLE=MDY` | Default date format on display | Cosmetic for display; doesn't affect computation |
| `FMTSEARCH=(lib1 lib2)` | Where PROC FORMAT looks up formats | When converting, you need to know where format catalogs live — surface as a caveat if FMTSEARCH includes a permanent library |
| `OBS=` / `FIRSTOBS=` | Limit rows globally | `LIMIT n` and `OFFSET n` in Snowflake; usually a debugging flag, drop it |
| `NOTHREADS` / `THREADS` | Whether PROCs run multi-threaded | Irrelevant in Snowflake |
| `VALIDVARNAME=ANY` | Allow non-standard column names | Snowflake supports quoted identifiers — preserve them with double quotes |
| `COMPRESS=YES` | Compress datasets on disk | Storage concern, no Snowflake analog |

## System PROCs and what to do with them

These typically have no business-logic meaning. Drop them or convert to comments.

| PROC | What it does | Conversion |
| --- | --- | --- |
| `PROC OPTIONS` | Lists current option values | Drop |
| `PROC SETINIT` | Shows licensed products + expiry | Drop |
| `PROC CONTENTS` | Dataset metadata | If used for documentation, replace with a Snowflake `DESCRIBE TABLE` query; if it feeds downstream logic via `OUT=`, translate the OUT dataset query |
| `PROC DATASETS` | Rename/copy/delete datasets in a library | Translate to `ALTER TABLE RENAME`, `CREATE TABLE AS SELECT`, `DROP TABLE`. Watch for `MODIFY ... LABEL=`, which sets dataset/column labels — Snowflake supports column comments via `COMMENT ON COLUMN`. |
| `PROC PRINTTO` | Reroutes log/output | Drop |
| `PROC PRINT` | Pretty-prints a dataset | Drop (it's a display PROC) |

## Date/time/datetime formats and the M8 crosswalk

SAS format names vs Snowflake `TO_VARCHAR` format strings (most common):

| SAS format | Example | Snowflake equivalent |
| --- | --- | --- |
| `date9.` | `15JAN2024` | `TO_VARCHAR(d, 'DDMONYYYY')` (Snowflake) |
| `mmddyy10.` | `01/15/2024` | `TO_VARCHAR(d, 'MM/DD/YYYY')` |
| `yymmdd10.` | `2024-01-15` | `TO_VARCHAR(d, 'YYYY-MM-DD')` or just cast — that's the default |
| `datetime20.` | `15JAN2024:09:30:00` | `TO_VARCHAR(ts, 'DDMONYYYY:HH24:MI:SS')` |
| `time8.` | `09:30:00` | `TO_VARCHAR(t, 'HH24:MI:SS')` |
| `dollar12.2` | `$1,234.56` | `TO_VARCHAR(n, '$999,999.99')` |
| `comma12.` | `1,234,567` | `TO_VARCHAR(n, '999,999,999')` |
| `percent8.2` | `12.34%` | `TO_VARCHAR(n, '999.99%')` |
| `best12.` | numeric best-fit | Cast/`TO_VARCHAR(n)` with no format |
| `z8.` | zero-padded `00012345` | `LPAD(TO_VARCHAR(n), 8, '0')` |

When the format is custom (defined by `PROC FORMAT`), see the format strategy in the main SKILL.md.

## SAS functions → Snowflake function crosswalk

A non-exhaustive list of common functions and their Snowflake equivalents:

| SAS | Snowflake |
| --- | --- |
| `SUBSTR(s, p, n)` | `SUBSTR(s, p, n)` — same |
| `SUBSTRN(s, p, n)` | `SUBSTR(s, p, n)` (SUBSTRN handles negatives; Snowflake doesn't — handle with `IFF` if needed) |
| `SCAN(s, n, delim)` | `SPLIT_PART(s, delim, n)` |
| `TRANWRD(s, old, new)` | `REPLACE(s, old, new)` |
| `COMPRESS(s, chars)` | `TRANSLATE(s, chars, '')` or `REGEXP_REPLACE` |
| `COMPRESS(s, chars, 'kd')` (keep digits) | `REGEXP_REPLACE(s, '[^0-9]', '')` |
| `INDEX(s, sub)` | `POSITION(sub IN s)` |
| `LENGTH(s)` / `LENGTHN(s)` | `LENGTH(s)` (Snowflake counts characters) |
| `STRIP(s)` | `TRIM(s)` |
| `LOWCASE(s)` / `UPCASE(s)` | `LOWER(s)` / `UPPER(s)` |
| `CATX(sep, a, b, c)` | `ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(a, b, c), sep)` |
| `INTCK('month', a, b)` | `DATEDIFF('month', a, b)` |
| `INTNX('month', d, 1)` | `DATEADD('month', 1, d)` |
| `DATEPART(dt)` | `DATE(dt)` |
| `TIMEPART(dt)` | `TIME(dt)` |
| `TODAY()` / `DATE()` | `CURRENT_DATE` |
| `DATETIME()` | `CURRENT_TIMESTAMP` |
| `INPUT(s, informat.)` | `TO_DATE` / `TO_TIMESTAMP` / `TO_NUMBER` / `TRY_TO_*` |
| `PUT(x, format.)` | `TO_VARCHAR(x, '...')` |
| `IFN(cond, a, b)` / `IFC(cond, a, b)` | `IFF(cond, a, b)` |
| `COALESCE(a, b, ...)` | `COALESCE(a, b, ...)` — same |
| `MISSING(x)` | `x IS NULL` |
| `ROUND(x, unit)` | `ROUND(x / unit) * unit` if unit ≠ 1 (Snowflake `ROUND(x, n)` is digits) |

`INTCK` and `INTNX` have alignment options (`'continuous'`, `'discrete'`, `'same'`, `'begin'`, `'end'`) — most translate to straightforward `DATEDIFF`/`DATEADD`, but the `'same'` alignment of `INTNX` (preserve day-of-month) needs `LAST_DAY` logic when the target month is shorter. Surface as a caveat.

## What's new / changed in M8 specifically

- Broader OS support (RHEL 9, Windows Server 2022, Oracle Linux 9).
- Encryption library updates (OpenSSL bumped; FIPS-140-2 module retired in M7→M8 transition).
- Bug fixes across PROC SQL, PROC FedSQL, and the macro processor.
- No PROC syntax was *added or removed* in M8 vs M7 in the core 9.4 language — code that ran on M5–M7 generally runs unchanged on M8.

This means: **if a user reports their code "ran fine on M7 but broke on M8," the most likely cause is encryption, not language.** Don't change the SAS itself; suggest checking server config.

## Things to ask about (or flag) when you don't know

- The session encoding (UTF-8 vs WLATIN1) — affects string ops.
- Where format catalogs live (`FMTSEARCH=`).
- Whether libraries are local LIBNAMEs or metadata-assigned.
