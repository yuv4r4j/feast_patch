# SAS Enterprise Guide 8.3 Update 7 (8.3.7.202)

EG 8.3.7 is the Windows authoring client that talks to a SAS 9.4 server. It does not execute SAS itself — it generates code and submits it to the workspace server. Knowing this changes how you read EG-originated artifacts.

## Artifacts you may see

### `.egp` — Enterprise Guide Project file
A `.egp` is actually a ZIP archive containing XML manifests plus the embedded code and task settings. Layout (relevant pieces):
- `project.xml` — graph of nodes (programs, data tables, queries, tasks), their ordering, and connections (process flow edges).
- `Programs/Program N.sas` — the SAS source for each code node.
- `Tasks/...` — XML serialization of point-and-click tasks (PROC wrappers like Summary Statistics, One-Way Frequencies). EG re-generates the SAS on each run from these task settings.
- `Queries/...` — visual Query Builder definitions. Compile down to PROC SQL at run time.
- `Logs/...` — last-run logs, if the user saved them with the project.

If a user uploads a `.egp` for conversion, unzip it and translate the **generated SAS** rather than trying to parse the XML — that's what the SAS server actually runs.

### Generated-code conventions in EG 8.3.7
EG 8.3.7 emits a recognizable preamble and per-task wrappers. Common tells:

```sas
/* Generated Code (IMPORT) */
%_eg_conditional_dropds(WORK.IMPORT);
PROC IMPORT OUT=WORK.IMPORT
    DATAFILE="..."
    DBMS=XLSX REPLACE;
RUN;
```

- `%_eg_conditional_dropds(...)` — macro EG injects to clean up its WORK datasets before recreating them. Drop these when translating; they're orchestration, not business logic.
- `_EG_CONDITIONAL_DROPDS`, `_eg_WhereClause`, `_eg_PrtJobid` style names — EG infrastructure, ignore.
- Code blocks bracketed by `/* Generated Code (NAME) */ ... /* End of Generated Code */` — each block corresponds to one node in the process flow. Preserve those node boundaries in your conversion output so the user can map back.

### Process flow semantics
Nodes in an EG process flow run in order; an arrow from A to B means "B runs after A and consumes A's output." This is essentially a DAG. When converting to Snowflake / Snowpark, preserve the DAG by emitting one CTE (or one Snowpark DataFrame variable) per node. Name them after the node's output dataset (`WORK.ORDERS_CLEAN`, `WORK.SUMMARY`) so the migration is auditable.

If a process flow contains parallel branches, they can become independent CTEs / DataFrames that later merge — no special handling needed.

## Server profile and library resolution
EG 8.3.7 connects via a *server profile* that points at a SAS Workspace Server. Library references in the generated code may resolve via:
- Local `LIBNAME ...` statements in the program (most portable).
- Pre-assigned libraries defined in the user's metadata (won't appear in the .sas; you'll see `libname.tablename` references with no preceding `LIBNAME`).

If you see table references like `MYLIB.ORDERS` with no `LIBNAME MYLIB ...` anywhere in the file, that library was metadata-assigned — surface that as a caveat: "MYLIB is a metadata-assigned library; its physical location/schema in Snowflake must be supplied separately."

## 8.3.7-specific gotchas

- **Git integration**: EG 8.3 ships with native Git support. The `.egp` is treated as a binary blob — diffs are unreadable. Users sometimes commit *only* the exported `.sas` files for that reason. If the user has both, the .sas files are the ground truth.
- **Code formatting**: EG 8.3.7's auto-format can rewrite indentation but does not change semantics. Don't be thrown by inconsistent indentation across versions of the same program.
- **Encoding**: 8.3.7 defaults to UTF-8 for generated programs but the workspace server may still be running WLATIN1 or another encoding. If the SAS log shows transcoding warnings, that's why. In Snowflake, everything is UTF-8 — flag any encoding-dependent logic (`KCOMPRESS`, `KSCAN`) as needing review.
- **Task code drift**: When a user edits the generated code of an EG task, EG marks the task as "customized" and stops regenerating. If the program has hand-edited generated blocks, treat them as authoritative.

## What this means for conversion

- Translate the .sas files, not the .egp XML.
- Preserve node boundaries as CTE/DataFrame boundaries in the output.
- Strip EG infrastructure macros (`%_eg_*`) — they have no Snowflake analog and aren't business logic.
- Flag metadata-resolved libraries explicitly.
- Treat customized task blocks as authoritative source.
