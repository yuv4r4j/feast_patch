# SAS Object/Metadata Model 16.01

"Model 16.01" refers to the SAS metadata/object model version associated with the 9.4 M8 line. The model is what describes "things that exist": libraries, tables, jobs, users, ACLs, server connections. It's the schema that the SAS Metadata Server uses; it's also (loosely) what determines what an `.sas7bdat` file claims about itself.

This file is the smallest of the four because the model rarely matters for code translation — but when it does matter, it matters a lot.

## Where the model version actually shows up

1. **Metadata Server**. If the deployment uses the SAS Metadata Server, that server runs a specific repository model version. M8 ships with model 16.01 (also referred to as "model release 16.01"). Older clients can usually read it; client/server skew is mostly tolerated for read.
2. **`.sas7bdat` headers**. Every SAS dataset stores a "Created by SAS release" string. Datasets created on 9.4 M8 list a 9.04.01M8 release string. Downstream tools that parse `.sas7bdat` (Python `pandas.read_sas`, R `haven`, the `pyreadstat` library) rely on this header.
3. **EG project XML**. The .egp embeds a model version in its manifest so EG knows how to deserialize it. Mostly invisible to users.

## ACL semantics (when LIBNAME ... META is used)

`LIBNAME mylib META LIBRARY="MyLib";` resolves the library through the metadata server, applying the user's metadata permissions:

- **ReadMetadata** / **WriteMetadata** — control whether the user sees / edits the *definition* of the library, not the data.
- **Read** / **Write** / **Create** / **Delete** — control data-level operations.
- Permissions can be denied at user, group, or role level; the most specific wins.
- Authorization decisions are evaluated by the metadata server and cached; if a user's permissions change while their SAS session is live, they often need to reconnect.

**Implication for migration**: Snowflake RBAC is role-based and (mostly) additive — there's no concept of "deny." When translating metadata-defined ACLs, document the permission set as a target role definition and have a human review whether any explicit denies need to become *not granting* a role.

## What a `.sas7bdat` actually contains

Useful when the user uploads `.sas7bdat` and asks "what's in this":

- **Header**: magic bytes, file format version, "created by SAS release" string, page size, row count, column count, dataset label, "created on" datetime.
- **Column metadata**: name, type (`num`/`char`), length (in bytes), label, format, informat, offset/order in row.
- **Data**: row-oriented, paged. Compression options: none, RLE (`COMPRESS=CHAR`), or binary (`COMPRESS=BINARY`).
- **Indexes**: if present, stored alongside but separate. Lost on most external read tools.
- **Audit info**: if dataset audit is on, an audit log is in a sibling file.

For migration: extract with `pyreadstat.read_sas7bdat(path)` — it returns a pandas DataFrame plus a metadata object (column labels, formats). The formats are *names* only; if the data was formatted with a custom format, the format catalog (`.sas7bcat`) must be exported separately. If the user has only `.sas7bdat` and not the matching catalog, formatted values are unrecoverable — the raw values still load.

## Format catalog (`.sas7bcat`) interchange

A format catalog defines the value→label mappings created by `PROC FORMAT`. When migrating value formats to Snowflake lookup tables:

1. Run `PROC FORMAT LIBRARY=mylib.formats CNTLOUT=work.fmt_export;` on SAS to dump the catalog to a regular dataset.
2. Export that dataset (CSV / Parquet).
3. Load to Snowflake as a lookup table; the columns are `FMTNAME`, `START`, `END`, `LABEL`, `TYPE`. Convert via `LEFT JOIN fmt_export ON value BETWEEN start AND end WHERE fmtname = '...'`.

If you don't have access to the SAS server, this cannot be done from the `.sas7bdat` alone.

## Things to flag to the user

- **Metadata-bound libraries**: if you see `LIBNAME ... META`, the library is meaningless without the metadata server. Ask the user for the physical location (host/path/schema) and the table list.
- **Encrypted datasets**: M8 supports AES encryption on `.sas7bdat`. If `pyreadstat` errors with "encrypted", you need the password — there is no workaround.
- **Custom integer types**: SAS only has one numeric type (8-byte float). Integer-looking columns in `.sas7bdat` are *floats* — when loading to Snowflake, cast explicitly to `NUMBER(p, 0)` to avoid spurious decimal noise.
- **Character lengths in bytes**: in WLATIN1 (or any non-UTF8) source, `LENGTH x $20;` means 20 bytes; in UTF-8 Snowflake `VARCHAR(20)` means 20 characters. For ASCII-only data this doesn't matter; for multi-byte content, size up the Snowflake column.

## Bottom line

For code translation, you usually don't need to think about the model version at all. The cases where it bites you are: metadata-resolved library references, format catalogs that exist only on the SAS side, and `.sas7bdat` interchange where you need to know what tools can read what.
