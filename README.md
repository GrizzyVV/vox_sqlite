# vox_sqlite

A tiny, free **single-database service for HELIX** servers. One resource owns the SQLite connection;
every other resource shares it through `exports`. Drop it in, load it first, and stop fighting the
database.

> Verified on HELIX (UE 5.7.4 / Lua 5.4).

## Why you need this

HELIX's `Database` has two behaviours that bite as soon as you have more than one resource:

1. **`Database.Initialize(file)` must be called exactly once per file.** Call it a second time on the
   same file and you get `disk I/O error`.
2. **The `.db` file is opened exclusively.** A second resource **cannot** open a database another
   resource already has open — same `disk I/O error`.

So you can't just have each resource open the shared database itself. **One** resource has to own the
connection and hand it out. That's `vox_sqlite`: it initializes once and exposes the database to every
other resource via `exports`.

It also smooths over the rough edges: result rows come back as **plain Lua tables** (HELIX's
`row.Columns` needs `:ToTable()` and errors on direct field access), plus helpers for JSON blobs and
SQLite upserts.

## Install

1. Copy the `vox_sqlite/` folder into your world's `scripts/` directory.
2. Add it to `scripts/config.json` **before** any resource that uses it:

```json
{
  "packages": [
    "vox_sqlite",
    "your_resource"
  ]
}
```

3. (Optional) set your database filename in `vox_sqlite/shared/config.lua`:

```lua
VoxSQLiteConfig = {
    DatabaseFile = "server.db",  -- stored at Persist/<worldId>/server.db
    Verbose = true,
}
```

## Usage

From any **server** script, after vox_sqlite has loaded:

```lua
-- SELECT -> array of plain row tables
local players = exports['vox_sqlite']:Query('SELECT * FROM players WHERE online = ?', { 1 })
for _, p in ipairs(players) do
    print(p.name, p.cash)
end

-- One row / one value
local me   = exports['vox_sqlite']:Single('SELECT * FROM players WHERE id = ?', { id })
local count = exports['vox_sqlite']:Scalar('SELECT COUNT(*) FROM players')

-- Write
exports['vox_sqlite']:Execute(
    'CREATE TABLE IF NOT EXISTS players (id TEXT PRIMARY KEY, name TEXT, cash INTEGER)')
exports['vox_sqlite']:Execute(
    'INSERT INTO players (id, name, cash) VALUES (?, ?, ?)', { id, 'Grizzy', 500 })

-- Async (won't block the game thread)
exports['vox_sqlite']:QueryAsync('SELECT * FROM big_table', {}, function(rows)
    print('rows:', #rows)
end)

-- SQLite upsert helper (there is no MySQL ON DUPLICATE KEY)
exports['vox_sqlite']:Upsert('players', { 'id' }, { id = id, name = 'Grizzy', cash = 500 })

-- JSON blobs (store tables in TEXT columns)
local blob = exports['vox_sqlite']:Encode({ inventory = {} })
local data = exports['vox_sqlite']:Decode(blob)
```

## API

| Export | Returns | Notes |
|---|---|---|
| `Query(sql, params)` | `table[]` | SELECT → array of row tables (never nil) |
| `Single(sql, params)` | `table\|nil` | first row |
| `Scalar(sql, params)` | `any\|nil` | first column of first row |
| `Execute(sql, params)` | `boolean` | INSERT / UPDATE / CREATE / DELETE |
| `QueryAsync(sql, params, cb)` | — | `cb(rows)` |
| `ExecuteAsync(sql, params, cb)` | — | `cb(ok)` |
| `Upsert(table, keyCols, data)` | `boolean` | SQLite `ON CONFLICT` upsert |
| `Encode(v)` / `Decode(s)` | `string` / `any` | JSON blob helpers |
| `IsReady()` | `boolean` | is the connection open |

`params` is always a table (use `?` placeholders). SQL is plain SQLite — `AUTOINCREMENT`, `ON CONFLICT`,
etc. (not MySQL syntax).

## Notes

- **Server-side.** The database lives on the server; call these from server scripts.
- **Load order matters.** `exports['vox_sqlite']` is nil until vox_sqlite has loaded — list it first, and
  prefer calling at runtime (event handlers) over top-level script load.
- One server, one database file. The file is locked while the game runs.

## Docs
- [`docs/developer.md`](docs/developer.md) — full usage, rules, and an oxmysql→vox_sqlite migration table.
- [`docs/tech.md`](docs/tech.md) — how it works and why (the HELIX constraints it solves).

## License

MIT — see [LICENSE](LICENSE). Free to use, modify, and ship. Made by Grizzy / MetaVoxel. 🖤
