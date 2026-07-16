--!strict
--[[
    Module:   Janitor
    Location: ReplicatedStorage/Gaxia_Packages/Shared
    Purpose:  Named-index cleanup container (Howmanysmall-style). Each task
              is stored under a string/number index (auto-generated if not
              provided), enabling :Remove(index), :Get(index), and replacement
              of an existing index. :LinkToInstance auto-cleans when an
              Instance is removed from the DataModel.
--]]


-- ── Types ──

export type Cleanable = any
export type Index = string | number

export type Janitor = {
    Add: (self: Janitor, obj: Cleanable, methodName: (string | true)?, index: Index?) -> Cleanable,
    Remove: (self: Janitor, index: Index) -> (),
    Get: (self: Janitor, index: Index) -> Cleanable?,
    Cleanup: (self: Janitor) -> (),
    Destroy: (self: Janitor) -> (),
    LinkToInstance: (self: Janitor, instance: Instance) -> RBXScriptConnection,
}

-- ── Constants ──

local DEFAULT_METHOD: string = "Destroy" -- methodName fallback for table tasks

-- ── Helpers ──

local function invokeCleanup(obj: Cleanable, methodName: string | true | nil): ()
    -- Function tasks are called directly; everything else uses :methodName
    -- (defaulting to Destroy for tables and Disconnect for connections).
    if typeof(obj) == "function" then
        obj()
        return
    end
    if typeof(obj) == "RBXScriptConnection" then
        obj:Disconnect()
        return
    end

    local method: string
    if methodName == nil or methodName == true then
        method = DEFAULT_METHOD
    else
        method = methodName :: string
    end

    -- Some Roblox userdata (Instance) have :Destroy; tables may have custom names.
    local fn = (obj :: any)[method]
    if typeof(fn) == "function" then
        fn(obj)
    elseif typeof(obj) == "Instance" then
        -- Fall back to :Destroy for instances regardless of requested method name.
        obj:Destroy()
    end
end

-- ── Janitor ──

local Janitor = {}
Janitor.__index = Janitor

function Janitor.new(): Janitor
    local self = setmetatable({
        _items = {} :: { [Index]: Cleanable }, -- index -> obj
        _methods = {} :: { [Index]: string | true }, -- index -> method override
        _autoIndex = 0, -- monotonic counter for unnamed adds
    }, Janitor)
    return (self :: any) :: Janitor
end

function Janitor:Add(obj: Cleanable, methodName: (string | true)?, index: Index?): Cleanable
    assert(obj ~= nil, "Janitor:Add received nil")
    -- Local alias avoids the Luau "ambiguous syntax" warning that fires when a
    -- statement-starting `(` follows an expression-ending line.
    local s = self :: any
    local idx: Index
    if index ~= nil then
        idx = index
        -- Replacing an existing index: clean the old occupant first so we
        -- never silently leak a previous task.
        if s._items[idx] ~= nil then
            self:Remove(idx)
        end
    else
        s._autoIndex += 1
        idx = s._autoIndex
    end

    s._items[idx] = obj
    if methodName ~= nil then
        s._methods[idx] = methodName
    end
    return obj
end

function Janitor:Remove(index: Index): ()
    local s = self :: any
    local items = s._items
    local obj = items[index]
    if obj == nil then
        return
    end
    local methodName = s._methods[index]
    -- Clear before invoking so re-entrant calls during cleanup see consistent state.
    items[index] = nil
    s._methods[index] = nil
    local ok, err = pcall(invokeCleanup, obj, methodName)
    if not ok then
        warn(`[Janitor] cleanup of index '{tostring(index)}' errored: {err}`)
    end
end

function Janitor:Get(index: Index): Cleanable?
    return (self :: any)._items[index]
end

function Janitor:Cleanup(): ()
    -- Snapshot keys: cleanup may add or remove indices and we don't want to
    -- mutate the table while iterating.
    local indices: { Index } = {}
    for i in pairs((self :: any)._items) do
        table.insert(indices, i)
    end
    for _, i in ipairs(indices) do
        self:Remove(i)
    end
end

function Janitor:Destroy(): ()
    self:Cleanup()
    -- Strip metatable so further use throws — surfaces lifecycle bugs early.
    setmetatable(self :: any, nil)
end

function Janitor:LinkToInstance(instance: Instance): RBXScriptConnection
    -- Auto-clean when the instance leaves the DataModel. Checking parent==nil
    -- (rather than only Destroying signal) catches both :Destroy and reparent-to-nil.
    local conn: RBXScriptConnection
    conn = instance.AncestryChanged:Connect(function(_, parent)
        if parent == nil then
            conn:Disconnect()
            self:Cleanup()
        end
    end)
    -- Track the connection itself so manual :Cleanup also tears down the link.
    self:Add(conn, "Disconnect")
    return conn
end

return Janitor
