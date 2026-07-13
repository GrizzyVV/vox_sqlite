# vox_sqlite

A tiny, free **single-database service for HELIX** servers. One resource owns the SQLite connection;
every other resource shares it through `exports`. Drop it in, load it first, and stop fighting the
database.

> Verified on HELIX (UE 5.7.4 / Lua 5.4). **v1.2.0** — see [CHANGELOG](CHANGELOG.md).

## Which should I use — vox_sqlite or vox_postgres?

**vox_sqlite** (this resource) and **[vox_postgres](https://github.com/GrizzyVV/vox_postgres)** are
**companions, not competitors** — most RP servers use **both**.

| | **vox_sqlite** (this resource) | [vox_postgres](https://github.com/GrizzyVV/vox_postgres) |
|---|---|---|
| **Backend** | HELIX-native SQLite (local file) | External PostgreSQL via Supabase (over `HTTP.Request`) |
| **Speed** | sub-millisecond; ~28k writes/sec batched | ~100–300 ms per op (internet round-trip) |
| **Reach** | the game server only | shared — a website, dashboard, or another server can read/write it too |
| **Best for** | the **hot path**: player saves, inventory, economy, jobs — anything frequent | **external data**: MDT, web dashboards, cross-server, analytics |
| **Setup** | drop-in, zero config | a Supabase project + one Edge Function |

**Rule of thumb**
- **Default to vox_sqlite** for anything the game server reads/writes often — it's fast, stable, and local. This is your primary database.
- **Reach for [vox_postgres](https://github.com/GrizzyVV/vox_postgres)** only when data must live *outside* the game server (a website showing player stats, a cross-server economy, analytics). Don't run the hot path through it — every call is a network round-trip.
- **Use both** when you need both layers: SQLite as the primary store, Postgres for the external/shared layer.

<sub>Benchmarked in-engine: SQLite ~28,000 writes/sec (batched) vs Postgres-over-HTTP ~200/sec (bulk). Postgres buys external access, not speed.</sub>

## Why you need this

vox_sqlite is a thin **broker over the engine-native `Database` global** (HELIX ships
`Database.Initialize/Execute/Select/ExecuteAsync/SelectAsync/Close`). It does **not** hand-roll
its own SQLite — the engine owns the driver. What it adds is single-ownership and a compat layer,
because HELIX's `Database` has two behaviours that bite as soon as you have more than one resource:

1. **`Database.Initialize(file)` must be called exactly once per file.** Call it a second time on the
   same file and you get `disk I/O error`.
2. **The `.db` file is opened exclusively.** A second resource **cannot** open a database another
   resource already has open — same `disk I/O error`.

So you can't just have each resource open the shared database itself. **One** resource has to own the
connection and hand it out. That's `vox_sqlite`: it initializes once and exposes the database to every
other resource via `exports`. This single-owner broker pattern is the same one HELIX's native `qb-core`
uses — it owns `qbcore.db`, calls `Database.*` directly, and exposes a `DatabaseAction` export that
satellite resources go through instead of touching `Database` themselves.

It also smooths over the rough edges: result rows come back as **plain Lua tables** (HELIX's
`row.Columns` needs `:ToTable()` and errors on direct field access), plus helpers for JSON blobs and
SQLite upserts. And for resources being ported off FiveM's oxmysql, it ships an
**oxmysql-compatible `MySQL.*` adapter** (see [oxmysql compatibility](#oxmysql-compatibility) below).

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

-- New-row id (AUTOINCREMENT PK) and affected-row count
local newId = exports['vox_sqlite']:Insert(
    'INSERT INTO logs (msg) VALUES (?)', { 'hello' })           -- last_insert_rowid()
local removed = exports['vox_sqlite']:ExecuteCount(
    'DELETE FROM logs WHERE ts < ?', { cutoff })                -- changes() (affected rows)

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
| `Insert(sql, params)` | `number\|nil` | INSERT → new row id (`last_insert_rowid()`); nil on error |
| `ExecuteCount(sql, params)` | `number` | UPDATE / DELETE → affected rows (`changes()`); `-1` on error |
| `QueryAsync(sql, params, cb)` | — | `cb(rows)` |
| `ExecuteAsync(sql, params, cb)` | — | `cb(ok)` |
| `Upsert(table, keyCols, data)` | `boolean` | SQLite `ON CONFLICT` upsert |
| `CreateTable(name, columnDefs, ifNotExists?)` | `boolean` | `CreateTable('players', { 'id TEXT PRIMARY KEY', 'cash INTEGER DEFAULT 0' })` |
| `TruncateTable(name)` | `boolean` | empties the table + resets AUTOINCREMENT |
| `DropTable(name)` | `boolean` | `DROP TABLE IF EXISTS` |
| `TableExists(name)` | `boolean` | — |
| `Encode(v)` / `Decode(s)` | `string` / `any` | JSON blob helpers |
| `IsReady()` | `boolean` | is the connection open |

`params` is always a table (use `?` placeholders). SQL is plain SQLite — `AUTOINCREMENT`, `ON CONFLICT`,
etc. (not MySQL syntax).

## oxmysql compatibility

Porting a resource that used FiveM's **oxmysql** (`MySQL.query`, `MySQL.single`, …)? vox_sqlite owns a
lowercase, oxmysql-shaped adapter so converted code calls the exports **directly** — no injected shim:

```lua
local rows = exports['vox_sqlite']:query('SELECT * FROM users WHERE id = @id', { ['@id'] = id })
local one  = exports['vox_sqlite']:single('SELECT * FROM users WHERE id = ?', { id })
local n    = exports['vox_sqlite']:scalar('SELECT COUNT(*) FROM users')
local newId = exports['vox_sqlite']:insert('INSERT INTO logs (msg) VALUES (?)', { 'hi' })  -- insertId
local hit   = exports['vox_sqlite']:update('UPDATE users SET cash = ? WHERE id = ?', { 500, id })
```

| Adapter export | oxmysql shape |
|---|---|
| `query(sql, params, cb?)` | array of rows |
| `single(sql, params, cb?)` | first row |
| `scalar(sql, params, cb?)` | first value |
| `insert(sql, params, cb?)` | `insertId` (`last_insert_rowid()`) |
| `update` / `execute(sql, params, cb?)` | affected rows (`changes()`) |
| `prepare(sql, sets, cb?)` | single statement or batched param-sets |
| `transaction(queries, cb?)` | runs `{ query, values }` list; returns overall success |
| `ready(cb?)` | fires callback, reports readiness |

What the adapter handles for you:

- **Named params** — `@name` / `:name` are rewritten to positional `?` (quote/backtick aware).
- **MySQL → SQLite dialect** — `INSERT IGNORE`, `UNIX_TIMESTAMP()`, `NOW()`, `CURDATE()`, `CURTIME()`, and
  `ON DUPLICATE KEY UPDATE` are rewritten to their SQLite equivalents.
- **Params both ways** — a single `{ p1, p2 }` table **or** trailing `(sql, p1, p2, ...)` varargs.
- **Numeric coercion** — native `Database.Select` returns numeric columns as **strings**; the adapter
  coerces them back to numbers so `row.money > x` works like it did on oxmysql (round-trip-safe).

The capitalized native surface (`Query`/`Execute`/…) and this lowercase adapter share the same owned
connection — mix them freely.

## Notes

- **Server-side.** The database lives on the server; call these from server scripts.
- **Load order matters.** `exports['vox_sqlite']` is nil until vox_sqlite has loaded — list it first, and
  prefer calling at runtime (event handlers) over top-level script load.
- One server, one database file. The file is locked while the game runs.

## Security

- **Values are parameterized.** Always pass data as `?` placeholders + a params table — it's never
  concatenated into SQL, so player input can't inject. ✅
- **Identifiers are validated.** SQLite can't parameterize table/column *names*, so the helpers that take
  a name (`Upsert`, `CreateTable`, `TruncateTable`, `DropTable`, `TableExists`) validate it against
  `^[A-Za-z_][A-Za-z0-9_]*$` and refuse anything else. **Never** pass player input as a table/column name.
- **Server-side only.** Clients can't call these exports, so players never touch the database directly.
- Your own SQL is your responsibility: keep using `?` for values; don't build query strings from user input.

## Docs
- [`docs/developer.md`](docs/developer.md) — full usage, rules, and migration guidance.
- [`docs/tech.md`](docs/tech.md) — how it works and why (the HELIX constraints it solves).

## License

MIT — see [LICENSE](LICENSE). Free to use, modify, and ship. Made by Grizzy / MetaVoxel. 🖤
