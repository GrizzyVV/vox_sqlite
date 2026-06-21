# Changelog

All notable changes to `vox_sqlite`. Follows [Semantic Versioning](https://semver.org/).

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
