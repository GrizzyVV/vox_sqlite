# vox_sqlite — Technical

## Problem
HELIX's `Database` is single-connection-per-file and exclusive:
- `Database.Initialize(file)` is **once-only** — a 2nd call on the same file → `disk I/O error` (verified).
- The `.db` file is opened **exclusively** — a 2nd package cannot open a file another package holds →
  `disk I/O error` (verified: opening another package's db from vox_probe failed).

Therefore multiple resources cannot independently share one database. A single owner must hold the
connection and expose it. Cross-package `exports` are confirmed working, so a service is viable.

## Design
- **One owner.** vox_sqlite calls `Database.Initialize(DatabaseFile)` exactly once, guarded by an
  `initialized` flag that is set **regardless of success** so it can never retry (the failure mode).
- **Exports surface.** All access is via `exports('vox_sqlite', '<fn>', ...)`. No other resource should
  ever call `Database.*` directly.
- **Row normalization.** `Database.Select` returns a list whose `row.Columns` is a UE object; direct
  field access errors, so `rowsToTables()` calls `row.Columns:ToTable()` per row and returns a plain Lua
  array of `{ column = value }` tables. Iteration handles both `rs:Get(i)`/`rs:Length()` and `rs[i]`/`#rs`.
- **Async** maps to HELIX `SelectAsync` / `ExecuteAsync` (both confirmed present), normalizing rows in the
  callback.
- **Upsert** builds SQLite `INSERT ... ON CONFLICT(key) DO UPDATE SET col = excluded.col` (there is no
  MySQL `ON DUPLICATE KEY UPDATE`).
- **JSON blobs** via `JSON.stringify/parse` (capital J).

## Files
- `shared/config.lua` — `VoxSQLiteConfig` (`DatabaseFile`, `Verbose`).
- `server/main.lua` — the service + exports.

## Validation (2026-06-20, UE 5.7.4)
- vox_sqlite boots: `[vox_sqlite] connected (db=server.db) — exports ready`, all 10 exports registered.
- **Cross-package write:** vox_loadscreen created/seeded `vox_characters` via `exports['vox_sqlite']:Execute`.
- **Cross-package read:** vox_probe read the rows back via `exports['vox_sqlite']:Query` (2 rows).
- No `disk I/O error` on the shared file.

## Constraints / notes
- Server-side only.
- Load order: must precede consumers; `exports['vox_sqlite']` is nil until loaded.
- One world ↔ one db file (exclusive lock).
