# vox_sqlite — Developer

How other resources use the shared database. Server-side; call after vox_sqlite has loaded
(list it **first** in `config.json`).

## Exports
```lua
local db = exports['vox_sqlite']

local rows  = db:Query('SELECT * FROM players WHERE online = ?', { 1 })  -- array of plain tables
local one   = db:Single('SELECT * FROM players WHERE id = ?', { id })    -- first row or nil
local n     = db:Scalar('SELECT COUNT(*) FROM players')                   -- first col of first row
local ok    = db:Execute('UPDATE players SET cash = ? WHERE id = ?', { 500, id })

db:QueryAsync('SELECT * FROM big', {}, function(rows) end)
db:ExecuteAsync('DELETE FROM logs WHERE ts < ?', { cutoff }, function(ok) end)

db:Upsert('players', { 'id' }, { id = id, name = name, cash = 500 })      -- SQLite upsert
local blob = db:Encode({ items = {} })                                    -- JSON for TEXT columns
local data = db:Decode(blob)
local ready = db:IsReady()

-- Schema helpers
db:CreateTable('players', { 'id TEXT PRIMARY KEY', 'name TEXT', 'cash INTEGER DEFAULT 0' })
local has = db:TableExists('players')
db:TruncateTable('players')   -- empties + resets AUTOINCREMENT
db:DropTable('players')
```

## Rules
- `params` is always a table; use `?` placeholders.
- SQL is **SQLite** (`AUTOINCREMENT`, `ON CONFLICT`, …) — not MySQL.
- `Query` returns rows as **plain Lua tables** (the `Columns:ToTable()` conversion is done for you).
- Never call `Database.Initialize` / `Database.*` yourself — go through vox_sqlite, or you'll hit the
  exclusive-lock `disk I/O error`.
- Call at runtime (event handlers), not at top-level script load, unless your resource is guaranteed to
  load after vox_sqlite.
- **Security:** values are safe via `?` params; the name-taking helpers (`Upsert`, `CreateTable`,
  `TruncateTable`, `DropTable`, `TableExists`) validate identifiers and reject anything that isn't a plain
  `[A-Za-z0-9_]` name. Never pass player input as a table/column name, and never string-build SQL from user input.

## Migrating from oxmysql (FiveM)
| oxmysql | vox_sqlite |
|---|---|
| `MySQL.query(q, p, cb)` | `db:QueryAsync(q, p, cb)` (or sync `db:Query(q, p)`) |
| `MySQL.single(q, p, cb)` | `db:Single(q, p)` |
| `MySQL.scalar(q, p, cb)` | `db:Scalar(q, p)` |
| `MySQL.update/insert(q, p)` | `db:Execute(q, p)` |
| `ON DUPLICATE KEY UPDATE` | `db:Upsert(table, keyCols, data)` |
| `json.encode/decode` | `db:Encode` / `db:Decode` |

Remember to convert the SQL dialect (MySQL → SQLite) — vox_sqlite standardizes the call shape, not the SQL.
