# Changelog

All notable changes to `vox_sqlite`. Follows [Semantic Versioning](https://semver.org/).

## [1.2.0] — 2026-07-07

Reconciliation release: the changelog had lagged the shipped code. This entry documents the
full surface that was already in `server/main.lua` but undocumented — chiefly the
oxmysql-compatible `MySQL.*` adapter. No native SQL behaviour changed in this release.

### Added — oxmysql-compatible adapter (the FiveM `MySQL.*` surface)
vox_sqlite now OWNS a lowercase compat surface so resources converted off oxmysql call
`exports.vox_sqlite:query/single/scalar/...` directly — no injected shim:
- **`query` / `single` / `scalar`** — SELECT helpers returning the oxmysql shapes (array / row / value).
- **`insert`** — returns `insertId` (`last_insert_rowid()`).
- **`update` / `execute`** — return the affected-row count (`changes()`).
- **`prepare`** — single statement or batched param-sets (array-of-arrays).
- **`transaction`** — runs a list of `{ query, values }` statements, returns overall success.
- **`ready`** — invokes the callback and reports readiness.

### Added — dialect + parameter translation (inside the adapter)
- **Named-parameter translation** (`@name` / `:name` → positional `?`), quote/backtick aware,
  so oxmysql named-param calls run on SQLite unchanged.
- **MySQL→SQLite dialect rewrite**: `INSERT IGNORE` → `INSERT OR IGNORE`, `UNIX_TIMESTAMP()` →
  `strftime('%s','now')`, `NOW()` → `CURRENT_TIMESTAMP`, `CURDATE()`/`CURTIME()` → `date`/`time('now')`,
  and `INSERT ... ON DUPLICATE KEY UPDATE` → `INSERT OR REPLACE`.
- **oxmysql varargs contract**: accepts both a single `{ p1, p2 }` params table and trailing
  `(sql, p1, p2, ...)` varargs.

### Added — numeric return-contract coercion
- **`_numscalar` / `_numrow` / `_numrows`** coerce stringified numeric columns back to Lua numbers
  (round-trip-safe: leading-zero and fixed-decimal strings are preserved). Required because native
  `Database.Select` returns numeric columns as strings while oxmysql returns numbers — so converted
  code like `row.money > x` no longer throws. Re-verify each HELIX build; see the code comment.

### Fixed
- **Adapter one-arg-shift** (probe-caught 2026-07-02): the HELIX exports proxy always discards the
  caller's colon/`self` argument before forwarding, so the previous `(_self, sql, ...)` signatures
  meant every adapter call arrived one arg short (SQL landed in `_self`) and silently returned nil/false.
  Adapter functions now take `(sql, ...)` directly. The capitalized `Query`/`Execute`/... surface was
  never affected (it took no `self`), which is why schema installs worked while the adapter was broken.

## [1.1.0]

### Added
- **`Insert(sql, params)`** — runs an INSERT and returns the new row id via SQLite's
  `last_insert_rowid()` (or `nil` on error). For tables with an `AUTOINCREMENT` / `INTEGER PRIMARY KEY`.
- **`ExecuteCount(sql, params)`** — runs an UPDATE/DELETE and returns the affected-row count via
  SQLite's `changes()` (or `-1` on error).

Both are additive — existing `Query`/`Single`/`Scalar`/`Execute`/`Upsert`/schema helpers are unchanged.
They cover the two write contracts (`insertId` / `affectedRows`) that resources migrating off a MySQL
wrapper expect. Verified in-engine on HELIX.

## [1.0.0]

- Initial release: single-owner SQLite connection shared via `exports`; `Query`/`Single`/`Scalar`/
  `Execute` + async variants, `Upsert`, JSON blob helpers, schema helpers
  (`CreateTable`/`TruncateTable`/`DropTable`/`TableExists`), identifier validation. MIT.
