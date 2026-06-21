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
    local cols, marks, params = {}, {}, {}
    for col, val in pairs(data) do
        cols[#cols + 1] = col
        marks[#marks + 1] = "?"
        params[#params + 1] = val
    end
    local isKey = {}
    for _, k in ipairs(keyCols) do isKey[k] = true end
    local sets = {}
    for _, col in ipairs(cols) do
        if not isKey[col] then sets[#sets + 1] = col .. " = excluded." .. col end
    end
    local sql = ("INSERT INTO %s (%s) VALUES (%s) ON CONFLICT(%s) DO UPDATE SET %s")
        :format(tableName, table.concat(cols, ", "), table.concat(marks, ", "),
                table.concat(keyCols, ", "), table.concat(sets, ", "))
    return Execute(sql, params)
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
-- Boot + exports
-- ---------------------------------------------------------------------------
local opened = ensure()

exports("vox_sqlite", "Query", Query)
exports("vox_sqlite", "Single", Single)
exports("vox_sqlite", "Scalar", Scalar)
exports("vox_sqlite", "Execute", Execute)
exports("vox_sqlite", "QueryAsync", QueryAsync)
exports("vox_sqlite", "ExecuteAsync", ExecuteAsync)
exports("vox_sqlite", "Upsert", Upsert)
exports("vox_sqlite", "Encode", Encode)
exports("vox_sqlite", "Decode", Decode)
exports("vox_sqlite", "IsReady", IsReady)

if VERBOSE then
    print(("[vox_sqlite] %s (db=%s) — exports ready")
        :format(opened and "connected" or "INIT FAILED", DB_FILE))
end
