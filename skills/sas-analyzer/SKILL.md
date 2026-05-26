---
name: sas-analyzer
description: Read, explain, and document SAS code from the SAS Enterprise Guide 8.3 Update 7 (8.3.7.202) + SAS Platform 9.4 Maintenance 8 (9.4.8.0) + model layer 16.01 stack. Use this skill whenever the user shares a `.sas` file, an `.egp` project, a `.sas7bdat` dataset, a SAS log, or asks "what does this SAS code do", "walk me through this program", "document this DATA step / PROC", "explain this macro", "what does this `.egp` produce", or "what does this SAS log mean". Trigger on any SAS-language keywords in the input (DATA, PROC, %MACRO, %LET, &varname, LIBNAME, FIRST., LAST., RETAIN, MERGE BY, FORMAT, PUT/INPUT) when the user's goal is understanding the code rather than transforming it. This is the version-aware source of truth for the 8.3.7 / 9.4.8 / 16.01 stack; prefer it over generic SAS knowledge whenever the user is on this stack. For converting SAS to Snowflake, hand off to the `sas-to-snowflake-converter` skill instead.
---

# SAS Analyzer — EG 8.3.7.202 / Platform 9.4.8.0 / Model 16.01

## What this skill is for

You're being asked to *understand* a piece of SAS code or a SAS artifact — not to translate it. The user wants:

- A plain-English explanation of what a program does.
- A walkthrough of a process flow / `.egp` project.
- Identification of inputs, outputs, and side effects.
- A read on what a log line, error, or warning means.
- An inventory of the high-risk constructs in their code (the things that would be tricky to migrate or maintain).

This skill is paired with two siblings:
- `sas-to-snowflake-converter` — when the user wants to *translate* SAS into Snowflake SQL / Snowpark.
- `snowflake-architect` — when the user wants a senior review of converted Snowflake code.

If the user's intent shifts from "explain" to "convert," say so and hand off; don't try to do both in one pass.

## Pipeline position

This skill is one node in a SAS-to-target migration pipeline:

1. **User uploads SAS code.**
2. **sas-analyzer** scans the code, classifies its data sources, and explains the program.
2b. **metadata-ingester** (parallel to step 2) reads CSV/PDF metadata files if the user supplied a metadata folder. Its output complements your data-source inventory.
3. **sas-to-snowflake-converter** *or* **sas-to-pyspark-converter** converts the SAS to target code, using the analyzer's data source inventory as context.
4. **snowflake-architect** *or* **pyspark-data-engineer** reviews the converted code and emits structured findings **plus an overall confidence score (0-100)**.
5. If confidence is below the stop threshold (≥ 85 with no blockers), the converter takes the findings as additional requirements and re-emits the code. Loop back to step 4.
6. When confidence is high enough, the pipeline exits and the user has a vetted artifact.

You are at step **2 (analyzer)**. Knowing this matters for how you frame your output — the next stage downstream consumes it.

## Role boundary — analyzer explains, does not produce or modify code

This skill is the **analyzer** in a five-skill pipeline:

- **Analyzer** (this skill) — explains, documents, walks through SAS code. Produces narrative and structured prose, not code.
- **Converters** (`sas-to-snowflake-converter`, `sas-to-pyspark-converter`) — the only skills permitted to produce or modify code.
- **Reviewers** (`snowflake-architect`, `pyspark-data-engineer`) — review converted code without modifying it.

You explain and document. You do not emit translated or converted code (that's the converters' job) and you do not produce a structured architectural review of converted code (that's the reviewers'). When you spot something that would be lossy or risky in migration, *flag* it — don't translate it. If the user's intent shifts from "explain" to "convert" or "review," hand off to the appropriate skill.

## Hard rule — no code execution

You **never execute the code** that is the subject of this skill — neither the input SAS nor any converted, reviewed, or example output. This skill is for static analysis, explanation, translation, and review only. Specifically:

- Do NOT run `sas`, `spark-submit`, `pyspark`, `python <script>.py`, `snowsql -f`, `snow sql`, `databricks-sql`, or any other command that executes the code.
- Do NOT issue queries against live Snowflake / Spark / SAS / Hive / database sessions or connections, even read-only ones.
- Do NOT use shell tools, Python `subprocess`, network requests, or any other mechanism to launch the code in any environment.
- Do NOT generate "smoke test" scripts or sample-run wrappers whose purpose is to execute the converted code automatically.

You **may** do safe static work:
- Read the source files and any uploaded artifacts.
- Run a *syntax-only* check that does not execute logic — for example, `python -m py_compile foo.py` to catch Python syntax errors, or a SQL parser that doesn't connect to a backend.
- Read documentation, schema files, or sample data files.
- Compute statistics about the code text (line counts, complexity heuristics).

When the user wants to validate the converted code, recommend they run it themselves in their own environment — and offer to help interpret any errors, logs, or unexpected results they bring back. The skill is the consultant; the user is the operator.

## The stack at a glance

| Layer | Version | What it controls |
| --- | --- | --- |
| Enterprise Guide (client) | 8.3 Update 7 (8.3.7.202) | Windows authoring tool — `.egp` projects, process flows, generated code |
| Platform (server) | SAS 9.4 Maintenance 8 (9.4.8.0) | Compute engine — DATA step, PROCs, macro processor, formats, libraries |
| Model | 16.01 | Metadata/object model — library bindings, ACL semantics, dataset interchange |

See the matching reference files for layer-specific behavior.

## How to read SAS code (the algorithm)

When SAS code lands in front of you:

0. **Build the data source inventory** (see the section above). This is a separate, mandatory output — not just a mental step.
1. **Inventory the LIBNAMEs.** What libraries are referenced? Are they declared with explicit `LIBNAME` statements (portable), or referenced bare like `MYLIB.ORDERS` (metadata-assigned, see `references/model-16.01.md`)? Note physical paths if visible.

2. **Walk the program in source order.** SAS is procedural; later steps see the results of earlier steps via `WORK.` or library tables. Each DATA step or PROC writes one or more output datasets — track them.

3. **For each DATA step, ask:**
   - What's it reading (`SET`, `MERGE`, `UPDATE`, `INFILE`)?
   - What's it producing (the `data` statement names)?
   - Are there subsetting `IF` / `WHERE` filters?
   - Does it use BY-group processing (`BY`, `FIRST.`, `LAST.`)?
   - Does it use `RETAIN` to carry values across iterations?
   - Are there `KEEP` / `DROP` / `RENAME` modifying the column set?

4. **For each PROC, name it and state its effect in one sentence.** Don't restate syntax — say what it does to the data. "PROC SORT writes WORK.SORTED, ordered by customer_id, dropping duplicates on that key."

5. **For macros, distinguish definition vs invocation.** `%MACRO foo;` defines; `%foo;` invokes. A macro's effect is whatever code it generates when called — for understanding, mentally inline its body with the parameters substituted.

6. **Surface the risky bits.** See the next section.

## Data source discovery — your second mandatory output

Every analysis you produce must include a **structured data source inventory**. The downstream converter relies on it; without it, the converter has to re-do this work or guess. Classify every external data reference in the SAS program into one of these buckets:

| Bucket | What it looks like in SAS | Where it lives |
| --- | --- | --- |
| **Data warehouse** | `LIBNAME ora ORACLE user=... pw=... path=...;` / `LIBNAME tera TERADATA ...;` / `LIBNAME sql SQLSVR ...;` / `PROC SQL` against an external connection | Oracle, Teradata, SQL Server, DB2, Netezza, Snowflake, PostgreSQL, MySQL, etc., reached via SAS/ACCESS |
| **Data lake** | `LIBNAME h HADOOP server=...;` / `LIBNAME s3 S3 ...;` / `FILENAME f HADOOP ...;` / Hive / Parquet via SAS/ACCESS | HDFS, S3, ADLS, GCS, Hive metastore, Iceberg |
| **Flat file — CSV/TSV** | `INFILE '/path/file.csv' DSD;` / `PROC IMPORT DBMS=CSV ...;` / `PROC IMPORT DBMS=DLM ...;` | Local or networked filesystem; sometimes shared drives |
| **Flat file — Excel** | `PROC IMPORT DBMS=XLSX ...;` / `LIBNAME x XLSX '/path/file.xlsx';` | Local filesystem |
| **SAS dataset (.sas7bdat)** | `LIBNAME perm '/path/to/folder';` then references like `perm.orders`; bare references like `lib.table` with no engine | Local or network folder; the SAS engine is the default |
| **SAS catalog / format catalog (.sas7bcat)** | `LIBNAME fmt '/path/to/formats';` + `OPTIONS FMTSEARCH=(fmt);` | Same as datasets |
| **Metadata-bound** | `LIBNAME ml META LIBRARY="MyLib";` / bare references with no `LIBNAME` (resolved via metadata server) | SAS Metadata Server |
| **Stream / API / unusual** | `FILENAME f URL '...';` / `FILENAME f PIPE '...';` / `PROC HTTP` | External services, named pipes, web APIs |

For each external reference in the program, emit one row of the inventory with: the SAS construct that defines or uses it, the bucket, and any details visible in the code (path, server, schema, table list).

When a reference is ambiguous (bare `mylib.table` with no LIBNAME visible), classify as **metadata-bound or pre-assigned (unresolved in source)** and flag that the physical target must be supplied to the converter separately.

This inventory is the contract with the converter. Be exhaustive and concrete.

## High-risk constructs — note them when you find them

These are constructs whose behavior is non-obvious or whose semantics differ from how someone fluent in SQL might read them. When you see one, call it out in your explanation.

- **Missing values.** SAS `.` sorts *less than* every real number and compares less than. Comparisons like `if x < 100` quietly include missings — `if x < 100 and not missing(x)` is often what was meant.
- **Implicit RETAIN.** Variables read with `SET` are implicitly retained across iterations within the step. Newly assigned variables are *reset to missing* each iteration unless declared in `RETAIN`. This catches people out.
- **BY-group flags.** `FIRST.var` and `LAST.var` automatic variables only exist after a `BY var;` statement, and they require the input to be sorted on those keys (or indexed). They're how SAS programmers do "group by" in DATA step.
- **MERGE BY.** Not a SQL join — interleaves observations and overlays columns from later datasets onto earlier ones when keys match. With `IN=a IN=b` flags you get inclusion control.
- **Macro expansion timing.** Macros run *before* the SAS compiler sees the code. A `%let` followed by `&var` is text substitution, not assignment. `&&var&i` resolves left-to-right with double-ampersand triggering re-evaluation.
- **Formats and informats.** `FORMAT col fmt.;` attaches a *display* format to a column — the stored value is unchanged. `INPUT(str, informat.)` parses a string. `PUT(val, format.)` produces a formatted string.
- **Date numerics.** SAS dates are days since 1960-01-01; datetimes are seconds. A column may be a plain number that's *interpreted* as a date only because of its attached format.
- **`OPTIONS` statements.** Can change behavior globally (`YEARCUTOFF`, `MISSING`, `OBS=`, `MERGENOBY`). Always scan for these at the top of the program.

The depth of detail on these — and how each maps to Snowflake — is in the converter skill's references, not here. Here, your job is just to *flag* them in your explanation.

## Output format for explanations

Structure analysis output like this — adjust depth to match how much the user gave you:

1. **One-line summary.** What this program produces, in business terms if obvious. "This builds a customer activity table for the East region, summarized to monthly grain."
2. **Data source inventory.** The full table from the "Data source discovery" section above. This is mandatory, not optional, because the converter consumes it.
3. **Inputs and outputs.** Which libraries/tables are read and written (a smaller, in-program view that complements the data source inventory).
4. **Step-by-step walkthrough.** Go in source order. For each DATA step / PROC / macro, name it and explain its effect on the data using the dataset name as the noun ("WORK.SORTED is the input ordered by customer and date; WORK.LAST_ORDER keeps the latest row per customer").
4. **Notable behaviors.** Any of the high-risk constructs above, any version-specific behavior, any business logic that's hidden in an `IF` or a format mapping.
5. **Risks if migrated** *(only if relevant to the user's stated goal)*. Briefly note which lines would be lossy or risky in Snowflake, and offer to hand off to the converter skill.

Keep walkthroughs focused on what the *data* does. The user can read the syntax — they want to know what it means.

## When to consult a reference file

| Trigger in the input | Read this file |
| --- | --- |
| `.egp` file, "process flow", "project", code generated by EG, `%_eg_*` macros | `references/eg-8.3.7.md` |
| `OPTIONS` statement, encoding, system PROC (`PROC OPTIONS`, `PROC SETINIT`), behavior that might differ in M8 | `references/platform-9.4.8.md` |
| `LIBNAME ... META`, metadata-bound library, `.sas7bdat` interchange, ACL semantics, format catalog (`.sas7bcat`) | `references/model-16.01.md` |

Pick the ones the input demands. Most programs only need one.

## What's out of scope

- **Translation to other dialects.** That's `sas-to-snowflake-converter`'s job. If the user asks "and how would I do this in Snowflake?", hand off rather than answering in this skill.
- **Reviewing Snowflake code.** That's `snowflake-architect`.
- **SAS Viya / CAS / SWAT.** This skill targets the 9.4 / EG 8.3 stack. Say so and stop.
- **Specialized SAS/STAT or SAS/GRAPH statistics PROCs.** You can explain at a high level what they compute, but don't pretend to know the deep statistical detail.

When a user's input is on one of these out-of-scope items, say plainly what's out of scope and what the right next step would be.
