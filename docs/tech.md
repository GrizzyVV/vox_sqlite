# vox_sqlite — Technical

## The problem
HELIX's `Database` is single-connection-per-file and exclusive:

- `Database.Initialize(file)` is **once-only** — a second call on the same file returns `disk I/O error`.
- The `.db` file is opened **exclusively** — a second resource cannot open a file another resource
  already holds (also `disk I/O error`).

So multiple resources **cannot** independently share one database. A single owner must hold the
connection and expose it to the rest. Cross-resource `exports` work, which makes a shared service viable.

## The design
- **One owner.** vox_sqlite calls `Database.Initialize(DatabaseFile)` exactly once, guarded by a flag that
  is set **regardless of outcome**, so it can never retry (retrying is the failure mode).
- **Exports surface.** All access is through `exports['vox_sqlite']:*`. No other resource should call
  `Database.*` directly — doing so re-triggers the exclusive-lock error.
- **Row normalization.** `Database.Select` returns rows whose `.Columns` is a UE object; direct field
  access errors, so each row is converted with `row.Columns:ToTable()` and returned as a plain Lua
  `{ column = value }` table. Iteration supports both `rs:Get(i)`/`rs:Length()` and `rs[i]`/`#rs`.
- **Async** maps to HELIX `SelectAsync` / `ExecuteAsync`, normalizing rows in the callback.
- **Upsert** builds SQLite `INSERT ... ON CONFLICT(key) DO UPDATE SET col = excluded.col` (SQLite has no
  MySQL `ON DUPLICATE KEY UPDATE`).
- **JSON blobs** via `JSON.stringify` / `JSON.parse`.

## Files
- `vox_sqlite/shared/config.lua` — `VoxSQLiteConfig` (`DatabaseFile`, `Verbose`).
- `vox_sqlite/server/main.lua` — the service + exports.

## Verified behaviour (HELIX UE 5.7.4)
- Boots and registers its exports; `Database.Initialize` succeeds once with no error.
- **Cross-resource write:** a separate resource created and seeded a table via
  `exports['vox_sqlite']:Execute`.
- **Cross-resource read:** a third resource read the same rows back via `exports['vox_sqlite']:Query`.
- No `disk I/O error` on the shared file.

## Constraints
- Server-side only (the database lives on the server).
- Load order: vox_sqlite must precede consumers; `exports['vox_sqlite']` is nil until it has loaded.
- One world ↔ one database file (the file is exclusively locked while the game runs).
