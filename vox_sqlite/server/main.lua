-- vox_sqlite — the single SQLite database service for a HELIX server.
--
-- WHY THIS EXISTS (verified on UE 5.7.4):
--   * `Database.Initialize(file)` must be called EXACTLY ONCE per file — a second call
--     on the same file fails with `disk I/O error`.
--   * HELIX opens the .db file EXCLUSIVELY — a second package cannot open a file another
--     package already holds (also `disk I/O error`).
--   Together that means resources CANNOT each open the same shared database. So one
--   resource must own the connection and expose it to the rest. vox_sqlite is that owner:
--   it initializes once and serves every other resource through `exports`.
--
-- USAGE (from any other server script):
--   local rows = exports['vox_sqlite']:Query('SELECT * FROM players WHERE id = ?', { id })
--   exports['vox_sqlite']:Execute('UPDATE players SET cash = ? WHERE id = ?', { 500, id })
--
-- Load order: vox_sqlite must come BEFORE any resource that uses it (config.json).

local DB_FILE = (VoxSQLiteConfig and VoxSQLiteConfig.DatabaseFile) or "server.db"
local VERBOSE = not VoxSQLiteConfig or VoxSQLiteConfig.Verbose ~= false

local initialized = false

-- Initialize the one connection. Guarded so it can never run twice (the failure mode).
local function ensure()
    if initialized then return true end
    local ok = pcall(function() Database.Initialize(DB_FILE) end)
    initialized = true            -- set regardless: never attempt Initialize again
    return ok
end

-- HELIX `Select` returns a list of rows whose `.Columns` is a UE object — direct field
-- access errors, so convert with `:ToTable()`. This yields a plain Lua array of
-- { column = value } tables, which is what callers actually want.
local function rowsToTables(rs)
    local out = {}
    if not rs then return out end
    local n = (rs.Length and rs:Length()) or #rs
    for i = 1, n do
        local row = (rs.Get and rs:Get(i)) or rs[i]
        out[i] = (row and row.Columns and row.Columns:ToTable()) or {}
    end
    return out
end

-- SQL identifiers (table/column names) CANNOT be parameterized — only values can.
-- Anywhere a name is interpolated into SQL, it must be a plain identifier. This guard
-- rejects anything that isn't, so caller mistakes (or player input wrongly used as a
-- name) can't inject. VALUES always go through `?` params and are never interpolated.
local function validIdent(name)
    return type(name) == "string" and name:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Core API
-- ---------------------------------------------------------------------------

-- SELECT -> array of row tables (empty array on failure, never nil).
local function Query(sql, params)
    ensure()
    local ok, rs = pcall(function() return Database.Select(sql, params or {}) end)
    if not ok then return {} end
    return rowsToTables(rs)
end

-- First row of a SELECT, or nil.
local function Single(sql, params)
    return Query(sql, params)[1]
end

-- First column of the first row (e.g. COUNT(*)), or nil.
local function Scalar(sql, params)
    local row = Single(sql, params)
    if not row then return nil end
    -- prefer a deterministic single column if the query selected one
    for _, v in pairs(row) do return v end
    return nil
end

-- INSERT / UPDATE / CREATE / DELETE -> boolean success.
local function Execute(sql, params)
    ensure()
    local ok, res = pcall(function() return Database.Execute(sql, params or {}) end)
    return ok and res or false
end

-- INSERT returning the new row id (SQLite `last_insert_rowid()`), or nil on failure.
-- Safe on the single owned connection: nothing else can interleave a write between the
-- INSERT and the id read (HELIX Lua is single-threaded per resource and vox_sqlite owns
-- the only handle to this file). For a table without an INTEGER PRIMARY KEY the value is
-- the implicit rowid — still a truthy success signal.
local function Insert(sql, params)
    ensure()
    local ok = pcall(function() return Database.Execute(sql, params or {}) end)
    if not ok then return nil end
    local row = Single("SELECT last_insert_rowid() AS id")
    return row and row.id or nil
end

-- INSERT / UPDATE / DELETE returning the affected-row count (SQLite `changes()`).
-- Returns -1 on execution failure so a caller can tell "the statement errored" apart
-- from "ran fine, matched 0 rows" (a 0-row DELETE is still a success). A plain SELECT
-- does not disturb `changes()`, so reading it on the next line is correct.
local function ExecuteCount(sql, params)
    ensure()
    local ok = pcall(function() return Database.Execute(sql, params or {}) end)
    if not ok then return -1 end
    local row = Single("SELECT changes() AS n")
    return (row and row.n) or 0
end

-- Async variants (won't block the game thread on heavy queries).
local function QueryAsync(sql, params, cb)
    ensure()
    pcall(function()
        Database.SelectAsync(sql, params or {}, function(rs)
            if cb then cb(rowsToTables(rs)) end
        end)
    end)
end

local function ExecuteAsync(sql, params, cb)
    ensure()
    pcall(function()
        Database.ExecuteAsync(sql, params or {}, function(ok)
            if cb then cb(ok and true or false) end
        end)
    end)
end

-- Convenience: SQLite upsert. keyCols identify the row; all of `data` is written, and
-- on a key conflict the non-key columns are updated (SQLite ON CONFLICT — there is no
-- MySQL `ON DUPLICATE KEY UPDATE`).
local function Upsert(tableName, keyCols, data)
    if not validIdent(tableName) then return false end
    local cols, marks, params = {}, {}, {}
    for col, val in pairs(data) do
        if not validIdent(col) then return false end   -- reject unsafe column names
        cols[#cols + 1] = col
        marks[#marks + 1] = "?"
        params[#params + 1] = val
    end
    local isKey = {}
    for _, k in ipairs(keyCols) do
        if not validIdent(k) then return false end
        isKey[k] = true
    end
    local sets = {}
    for _, col in ipairs(cols) do
        if not isKey[col] then sets[#sets + 1] = col .. " = excluded." .. col end
    end
    local sql = ("INSERT INTO %s (%s) VALUES (%s) ON CONFLICT(%s) DO UPDATE SET %s")
        :format(tableName, table.concat(cols, ", "), table.concat(marks, ", "),
                table.concat(keyCols, ", "), table.concat(sets, ", "))
    return Execute(sql, params)
end

-- ---------------------------------------------------------------------------
-- Schema helpers (DDL). Table/column names are validated as identifiers; the
-- type/constraint text in a column def is developer-authored DDL.
-- ---------------------------------------------------------------------------

-- CreateTable('players', { 'id TEXT PRIMARY KEY', 'name TEXT', 'cash INTEGER DEFAULT 0' })
-- Each column def must begin with a valid identifier. ifNotExists defaults to true.
local function CreateTable(name, columnDefs, ifNotExists)
    if not validIdent(name) then return false end
    if type(columnDefs) ~= "table" or #columnDefs == 0 then return false end
    for _, def in ipairs(columnDefs) do
        local ident = type(def) == "string" and def:match("^%s*([A-Za-z_][A-Za-z0-9_]*)")
        if not ident then return false end          -- every def must start with a column name
    end
    local ine = (ifNotExists ~= false) and "IF NOT EXISTS " or ""
    return Execute(("CREATE TABLE %s%s (%s)"):format(ine, name, table.concat(columnDefs, ", ")), {})
end

-- Empty a table (SQLite has no TRUNCATE) and reset its AUTOINCREMENT counter.
local function TruncateTable(name)
    if not validIdent(name) then return false end
    local ok = Execute(("DELETE FROM %s"):format(name), {})
    Execute("DELETE FROM sqlite_sequence WHERE name = ?", { name })   -- value param: safe
    return ok
end

local function DropTable(name)
    if not validIdent(name) then return false end
    return Execute(("DROP TABLE IF EXISTS %s"):format(name), {})
end

local function TableExists(name)
    if not validIdent(name) then return false end
    return Scalar("SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?", { name }) ~= nil
end

-- JSON blob helpers (store Lua tables as TEXT columns).
local function Encode(v)
    local ok, s = pcall(function() return JSON.stringify(v) end)
    return ok and s or "{}"
end
local function Decode(s)
    if not s then return nil end
    local ok, v = pcall(function() return JSON.parse(s) end)
    return ok and v or nil
end

-- Is the database connection open? (false if Initialize failed.)
local function IsReady()
    return ensure()
end

-- ---------------------------------------------------------------------------
-- oxmysql-compatible API (the FiveM MySQL.* surface). vox_sqlite OWNS this adapter so converted resources call
-- exports.vox_sqlite:query/single/... DIRECTLY — no injected compat shim. Handles: named @params -> positional ?,
-- MySQL->SQLite dialect, and oxmysql return-contract coercion (vox_sqlite stringifies; oxmysql returns numbers).
-- ---------------------------------------------------------------------------
local function _translate_named(sql, params)
    if type(params) ~= "table" then return sql, params end
    local named = false
    for k in pairs(params) do if type(k) == "string" then named = true break end end
    if not named then return sql, params end
    local out, ordered, i, n, oi = {}, {}, 1, #sql, 0
    local quote = nil
    while i <= n do
        local c = sql:sub(i, i)
        if quote then out[#out+1] = c; if c == quote then quote = nil end; i = i + 1
        elseif c == "'" or c == '"' or c == "`" then quote = c; out[#out+1] = c; i = i + 1
        elseif c == "@" or c == ":" then
            local prev = sql:sub(i-1, i-1)
            local name = (prev == "" or not prev:match("[%w_@:]")) and sql:match("^[%w_]+", i+1) or nil
            if name then oi = oi + 1; ordered[oi] = params[name]; if ordered[oi] == nil then ordered[oi] = params["@"..name] end; if ordered[oi] == nil then ordered[oi] = params[":"..name] end
                out[#out+1] = "?"; i = i + 1 + #name
            else out[#out+1] = c; i = i + 1 end
        else out[#out+1] = c; i = i + 1 end
    end
    return table.concat(out), ordered
end
local function _ci(w) return (w:gsub("%a", function(c) return "["..c:upper()..c:lower().."]" end)) end
local _ONDUP = "%f[%w]".._ci("on").."%s+".._ci("duplicate").."%s+".._ci("key").."%s+".._ci("update")
local function _dialect(sql)
    if type(sql) ~= "string" then return sql end
    sql = sql:gsub("%f[%w]".._ci("insert").."(%s+)".._ci("ignore").."%f[%W]", "INSERT%1OR IGNORE")
    sql = sql:gsub("%f[%w]".._ci("unix_timestamp").."%s*%(%s*%)", "strftime('%%s','now')")
    sql = sql:gsub("%f[%w]".._ci("now").."%s*%(%s*%)", "CURRENT_TIMESTAMP")
    sql = sql:gsub("%f[%w]".._ci("curdate").."%s*%(%s*%)", "date('now')")
    sql = sql:gsub("%f[%w]".._ci("curtime").."%s*%(%s*%)", "time('now')")
    if sql:find(_ONDUP) then
        sql = sql:gsub("^(%s*)".._ci("insert").."(%s+)".._ci("into"), "%1INSERT OR REPLACE%2INTO", 1)
        sql = sql:gsub(_ONDUP..".*$", "")
    end
    return sql
end
local function _prep(sql, params) return _translate_named(_dialect(sql), params) end
local function _tonum(v) return tonumber(v) or v end
local function _numscalar(v) if type(v) ~= "string" then return v end local nbr = tonumber(v); if nbr ~= nil and tostring(nbr) == v then return nbr end return v end
local function _mk(fn, post)
    -- oxmysql params: a single table `{p1,p2}` OR trailing varargs `(sql, p1, p2, ...)`. (Async callbacks stay consumer-side
    -- — the converter rewrites async to `cb(export(...))` — so vox_sqlite never receives a cb across the boundary.)
    return function(_self, sql, ...)
        local n = select("#", ...)
        local params
        if n == 1 and type((...)) == "table" then params = (...)
        elseif n >= 1 then params = { ... }
        else params = {} end
        local s, p = _prep(sql, params)
        local r = fn(s, p)
        if post then r = post(r) end
        return r
    end
end
-- ROW coercion (parity-probe finding 2026-07-02): SQLite/Database.Select STRINGIFIES numeric columns; oxmysql returns
-- NUMBERS. Without this, converted code doing `row.money > x` throws (string vs number compare) and `row.v == 0` is
-- always false. _numscalar is round-trip-safe: "4242"->4242 but "0123" (leading zero) and "12.30" stay strings.
local function _numrow(r)
    if type(r) ~= "table" then return r end
    for k, v in pairs(r) do r[k] = _numscalar(v) end
    return r
end
local function _numrows(rs)
    if type(rs) ~= "table" then return rs end
    for i = 1, #rs do _numrow(rs[i]) end
    return rs
end
local m_query, m_single = _mk(Query, _numrows), _mk(Single, _numrow)
local m_scalar  = _mk(Scalar, _numscalar)
local m_insert  = _mk(Insert, _tonum)
local m_execute = _mk(ExecuteCount, _tonum)
local function m_prepare(_self, sql, sets, cb)
    local s = _dialect(sql)
    local isSel = type(s) == "string" and s:match("^%s*[Ss][Ee][Ll][Ee][Cc][Tt]") ~= nil
    local r
    if type(sets) == "table" and type(sets[1]) == "table" then
        local total = 0
        for _, ps in ipairs(sets) do local q, p = _translate_named(s, ps); if isSel then r = Query(q, p) else total = total + (tonumber(ExecuteCount(q, p)) or 0) end end
        if not isSel then r = total end
    else
        local q, p = _translate_named(s, sets); r = isSel and Query(q, p) or (tonumber(ExecuteCount(q, p)) or 0)
    end
    if type(cb) == "function" then cb(r) end
    return r
end
local function m_transaction(_self, queries, cb)
    local ok = true
    if type(queries) == "table" then
        for _, q in ipairs(queries) do
            local sql, params = q.query or q[1], q.values or q[2]
            if sql then local s, p = _prep(sql, params); if Execute(s, p) == false then ok = false end end
        end
    end
    if type(cb) == "function" then cb(ok) end
    return ok
end
local function m_ready(_self, cb) if type(cb) == "function" then cb() end return true end
for name, fn in pairs({ query = m_query, single = m_single, scalar = m_scalar, insert = m_insert,
                        update = m_execute, execute = m_execute, prepare = m_prepare,
                        transaction = m_transaction, ready = m_ready }) do
    exports("vox_sqlite", name, fn)
end

-- ---------------------------------------------------------------------------
-- Boot + exports
-- ---------------------------------------------------------------------------
local opened = ensure()

exports("vox_sqlite", "Query", Query)
exports("vox_sqlite", "Single", Single)
exports("vox_sqlite", "Scalar", Scalar)
exports("vox_sqlite", "Execute", Execute)
exports("vox_sqlite", "Insert", Insert)
exports("vox_sqlite", "ExecuteCount", ExecuteCount)
exports("vox_sqlite", "QueryAsync", QueryAsync)
exports("vox_sqlite", "ExecuteAsync", ExecuteAsync)
exports("vox_sqlite", "Upsert", Upsert)
exports("vox_sqlite", "CreateTable", CreateTable)
exports("vox_sqlite", "TruncateTable", TruncateTable)
exports("vox_sqlite", "DropTable", DropTable)
exports("vox_sqlite", "TableExists", TableExists)
exports("vox_sqlite", "Encode", Encode)
exports("vox_sqlite", "Decode", Decode)
exports("vox_sqlite", "IsReady", IsReady)

if VERBOSE then
    print(("[vox_sqlite] %s (db=%s) — exports ready")
        :format(opened and "connected" or "INIT FAILED", DB_FILE))
end
