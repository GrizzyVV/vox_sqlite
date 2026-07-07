# vox_sqlite — Technical

## Problem
HELIX's `Database` is single-connection-per-file and exclusive:
- `Database.Initialize(file)` is **once-only** — a 2nd call on the same file → `disk I/O error` (verified).
- The `.db` file is opened **exclusively** — a 2nd package cannot open a file another package holds →
  `disk I/O error` (verified: opening another package's db from vox_probe failed).

Therefore multiple resources cannot independently share one database. A single owner must hold the
connection and expose it. Cross-package `exports` are confirmed working, so a service is viable.

vox_sqlite **wraps the engine-native `Database` global** (`Initialize/Execute/Select/ExecuteAsync/
SelectAsync/Close`, positional string params, SQLite). It does not implement SQLite itself — the engine
owns the driver; vox_sqlite owns the single handle and the compat layer on top.

This single-owner broker pattern is independently validated by HELIX's native **`qb-core`**, which owns
`qbcore.db`, calls `Database.*` directly, and exposes a **`DatabaseAction`** export that satellite
resources call instead of ever touching `Database` themselves — exactly vox_sqlite's model. The pattern
is the correct answer to the once-only-init + exclusive-lock constraints, not a vox_sqlite quirk.

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
- **oxmysql compat adapter.** A second, lowercase export surface (`query`/`single`/`scalar`/`insert`/
  `update`/`execute`/`prepare`/`transaction`/`ready`) mirroring FiveM's `MySQL.*` contract, so resources
  ported off oxmysql call vox_sqlite directly (no injected shim). It layers three translations over the
  core: **named params** (`@name`/`:name` → positional `?`, quote-aware `_translate_named`), **MySQL→SQLite
  dialect** (`_dialect`: `INSERT IGNORE`, `UNIX_TIMESTAMP`, `NOW`, `CURDATE`, `CURTIME`, `ON DUPLICATE KEY
  UPDATE`), and **numeric coercion** (`_numscalar`/`_numrow`/`_numrows`).
  - *Numeric coercion — why:* native `Database.Select` returns numeric columns as **strings** while oxmysql
    returns numbers, so without coercion `row.money > x` throws (string vs number). The coercion is
    round-trip-safe (leading-zero / fixed-decimal strings are preserved). **Re-verify each HELIX build:** if
    a future build makes `Select` return real numbers, this layer can be dropped.
  - *One-arg-shift fix (2026-07-02):* the HELIX exports proxy always discards the caller's colon/`self`
    argument before forwarding, so adapter fns take `(sql, ...)` — the earlier `(_self, sql, ...)` signature
    silently one-arg-shifted every adapter call. The capitalized surface (no `self`) was never affected.

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
