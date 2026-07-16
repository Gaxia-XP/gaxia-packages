--!strict
--[[
    Module:   Signal
    Location: ReplicatedStorage/Gaxia_Packages/Shared
    Purpose:  Stravant-style linked-list signal implementation. Lightweight
              event object supporting :Connect, :Once, :Wait, :Fire,
              :DisconnectAll, :Destroy. Each handler is dispatched via
              task.spawn so a single failing listener cannot block siblings.
--]]


-- ── Types ──

export type Connection = {
    Connected: boolean,
    Disconnect: (self: Connection) -> (),
}

export type Signal = {
    Connect: (self: Signal, fn: (...any) -> ()) -> Connection,
    Once: (self: Signal, fn: (...any) -> ()) -> Connection,
    Wait: (self: Signal) -> ...any,
    Fire: (self: Signal, ...any) -> (),
    DisconnectAll: (self: Signal) -> (),
    Destroy: (self: Signal) -> (),
}

-- ── Connection ──
-- Each connection is a node in a singly linked list; this avoids the
-- per-fire allocation of an iteration array.

local Connection = {}
Connection.__index = Connection

local function disconnect(self): ()
    if not self.Connected then
        return
    end
    self.Connected = false

    -- Splice this node out of the owning signal's linked list.
    local signal = self._signal
    if signal._head == self then
        signal._head = self._next
    else
        local prev = signal._head
        while prev and prev._next ~= self do
            prev = prev._next
        end
        if prev then
            prev._next = self._next
        end
    end
end
Connection.Disconnect = disconnect

-- ── Signal ──

local Signal = {}
Signal.__index = Signal

function Signal.new(): Signal
    local self = setmetatable({
        _head = nil, -- head of the connection linked list
    }, Signal)
    return (self :: any) :: Signal
end

function Signal:Connect(fn: (...any) -> ()): Connection
    local node = setmetatable({
        Connected = true,
        _signal = self,
        _fn = fn,
        _next = (self :: any)._head,
    }, Connection)
    -- Insert at head: O(1) and fires in LIFO order which matches Roblox semantics.
    -- rawset avoids Luau "ambiguous syntax" — `}, Connection)` followed by a
    -- line starting with `(` would otherwise parse as a function call.
    rawset(self :: any, "_head", node)
    return (node :: any) :: Connection
end

function Signal:Once(fn: (...any) -> ()): Connection
    -- Wrap so the connection auto-disconnects before the user fn runs;
    -- ensures re-entrant fires inside fn won't re-trigger this handler.
    local conn: Connection
    conn = self:Connect(function(...)
        if conn.Connected then
            conn:Disconnect()
            fn(...)
        end
    end)
    return conn
end

function Signal:Wait(): ...any
    local thread = coroutine.running()
    local conn: Connection
    conn = self:Connect(function(...)
        conn:Disconnect()
        -- task.spawn resumes safely even if the signal is fired from a
        -- non-yieldable context (e.g. Heartbeat).
        task.spawn(thread, ...)
    end)
    return coroutine.yield()
end

function Signal:Fire(...: any): ()
    -- Snapshot head; new connections added during dispatch won't fire this round.
    local node = (self :: any)._head
    while node do
        if node.Connected then
            -- task.spawn isolates each handler in its own coroutine so an
            -- error in one listener doesn't abort the rest of the chain.
            task.spawn(node._fn, ...)
        end
        node = node._next
    end
end

function Signal:DisconnectAll(): ()
    local node = (self :: any)._head
    while node do
        node.Connected = false
        node = node._next
    end
    -- rawset to avoid Luau "ambiguous syntax" — `end` then `(` would otherwise
    -- be parsed as a function call on the previous expression.
    rawset(self :: any, "_head", nil)
end

function Signal:Destroy(): ()
    self:DisconnectAll()
    -- Wipe metatable so further calls fail loudly rather than silently no-op.
    setmetatable(self :: any, nil)
end

return Signal
