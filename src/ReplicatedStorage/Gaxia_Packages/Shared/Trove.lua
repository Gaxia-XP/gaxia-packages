--!strict
--[[
    Module:   Trove
    Location: ReplicatedStorage/Gaxia_Packages/Shared
    Purpose:  Sleitnick-style cleanup container with constructor sugar.
              :Add returns the object (chainable), :Construct(class, ...) is
              shorthand for :Add(class.new(...)), :Connect wraps signal
              listeners, :Extend creates a child trove cleaned with the
              parent. :Remove drops a tracked object WITHOUT cleaning it.
--]]


-- ── Types ──

export type Cleanable = any

type Entry = {
    obj: Cleanable,
    method: string?, -- explicit method override; nil falls back to defaults
}

export type Trove = {
    Add: (self: Trove, obj: Cleanable, cleanupMethod: string?) -> Cleanable,
    Construct: (self: Trove, class: { new: (...any) -> any }, ...any) -> any,
    Connect: (self: Trove, signal: any, fn: (...any) -> ()) -> RBXScriptConnection,
    Extend: (self: Trove) -> Trove,
    Remove: (self: Trove, obj: Cleanable) -> boolean,
    Clean: (self: Trove) -> (),
    Destroy: (self: Trove) -> (),
}

-- ── Cleanup dispatch ──

local function cleanupEntry(entry: Entry): ()
    local obj = entry.obj
    local method = entry.method

    -- Functions: just call. Connections: Disconnect. Otherwise call :method
    -- (Destroy by default for instances and tables).
    if typeof(obj) == "function" then
        obj()
        return
    end
    if typeof(obj) == "RBXScriptConnection" then
        obj:Disconnect()
        return
    end

    local fnName = method or "Destroy"
    local fn = (obj :: any)[fnName]
    if typeof(fn) == "function" then
        fn(obj)
    elseif typeof(obj) == "Instance" then
        obj:Destroy()
    end
end

-- ── Trove ──

local Trove = {}
Trove.__index = Trove

function Trove.new(): Trove
    local self = setmetatable({
        _entries = {} :: { Entry }, -- ordered for LIFO cleanup
    }, Trove)
    return (self :: any) :: Trove
end

function Trove:Add(obj: Cleanable, cleanupMethod: string?): Cleanable
    assert(obj ~= nil, "Trove:Add received nil")
    table.insert((self :: any)._entries, {
        obj = obj,
        method = cleanupMethod,
    })
    -- Returning obj enables `local x = trove:Add(X.new())` ergonomics.
    return obj
end

function Trove:Construct(class: { new: (...any) -> any }, ...: any): any
    -- One-liner for the very common "construct + track" pattern.
    return self:Add(class.new(...))
end

function Trove:Connect(signal: any, fn: (...any) -> ()): RBXScriptConnection
    -- Works on both RBXScriptSignal and our Signal module (both expose :Connect).
    local conn = signal:Connect(fn)
    self:Add(conn)
    return conn
end

function Trove:Extend(): Trove
    -- Child trove cleaned when parent cleans; useful for scoping nested lifetimes.
    local child = Trove.new()
    self:Add(child)
    return child
end

function Trove:Remove(obj: Cleanable): boolean
    -- Untrack without cleaning — caller takes ownership of obj's lifetime.
    local entries = (self :: any)._entries
    for i = #entries, 1, -1 do
        if entries[i].obj == obj then
            table.remove(entries, i)
            return true
        end
    end
    return false
end

function Trove:Clean(): ()
    -- Local alias avoids the Luau "ambiguous syntax" warning that fires when a
    -- statement-starting `(` follows an expression-ending line.
    local s = self :: any
    local entries = s._entries
    -- Detach the list so cleanup tasks that re-add to this trove queue for
    -- the next pass instead of being silently dropped or causing infinite loops.
    s._entries = {}
    for i = #entries, 1, -1 do
        local ok, err = pcall(cleanupEntry, entries[i])
        if not ok then
            warn(`[Trove] cleanup entry #{i} errored: {err}`)
        end
    end
end

function Trove:Destroy(): ()
    self:Clean()
    -- Future calls should fail loudly — surfaces lifecycle bugs.
    setmetatable(self :: any, nil)
end

return Trove
