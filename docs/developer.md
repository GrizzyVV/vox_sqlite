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

local newId = db:Insert('INSERT INTO players (name) VALUES (?)', { name })  -- new row id, or nil
local n     = db:ExecuteCount('DELETE FROM players WHERE id = ?', { id })   -- affected rows; -1 on error

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

## Coming from another database wrapper?
Map your old data calls onto the exports above (`Query`/`Single`/`Scalar`/`Execute` + async, `Upsert`,
the schema helpers). The API surface is what changes — the SQL stays plain **SQLite** (`AUTOINCREMENT`,
`ON CONFLICT`, `?` value params).

### Coming from oxmysql (`MySQL.*`)?
vox_sqlite ships an **oxmysql-compatible adapter** so you don't have to rewrite the call sites — use the
lowercase exports directly:

```lua
local db = exports['vox_sqlite']
local rows = db:query('SELECT * FROM users WHERE id = @id', { ['@id'] = id })  -- named params OK
local one  = db:single('SELECT * FROM users WHERE id = ?', { id })
local n    = db:scalar('SELECT COUNT(*) FROM users')
local newId = db:insert('INSERT INTO logs (msg) VALUES (?)', { 'hi' })  -- insertId
local hit   = db:update('UPDATE users SET cash = ? WHERE id = ?', { 500, id })  -- affected rows
db:transaction({ { query = 'UPDATE a SET x=?', values = { 1 } }, { query = 'UPDATE b SET y=?', values = { 2 } } })
```

The adapter (`query`/`single`/`scalar`/`insert`/`update`/`execute`/`prepare`/`transaction`/`ready`) handles
named params (`@name`/`:name` → `?`), MySQL→SQLite dialect rewrites (`INSERT IGNORE`, `NOW()`,
`UNIX_TIMESTAMP()`, `ON DUPLICATE KEY UPDATE`, …), single-table-or-varargs params, and numeric coercion
(native `Select` returns numbers as strings; the adapter coerces them back). Mix the lowercase adapter and
the capitalized native surface freely — same owned connection.
