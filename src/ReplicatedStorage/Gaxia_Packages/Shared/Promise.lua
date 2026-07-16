--!strict
--[[
    Module:   Promise
    Location: ReplicatedStorage/Gaxia_Packages/Shared
    Purpose:  Promises/A+-flavoured asynchronous primitive (simplified). The
              executor receives (resolve, reject, onCancel). Instance methods:
              :andThen, :catch, :finally, :await, :expect, :cancel. Static
              helpers: Promise.resolve / .reject / .delay / .all / .any / .race.
              All callbacks are dispatched via task.spawn so user errors are
              isolated from each other and from internal state.
--]]


-- ── Constants ──

local STATE_PENDING: string = "pending"
local STATE_RESOLVED: string = "resolved"
local STATE_REJECTED: string = "rejected"
local STATE_CANCELLED: string = "cancelled"

-- ── Types ──

export type Status = "pending" | "resolved" | "rejected" | "cancelled"

export type Promise = {
    Status: Status,
    andThen: (self: Promise, onResolve: ((...any) -> ...any)?, onReject: ((any) -> ...any)?) -> Promise,
    catch: (self: Promise, onReject: (any) -> ...any) -> Promise,
    finally: (self: Promise, fn: () -> ()) -> Promise,
    await: (self: Promise) -> (boolean, ...any),
    expect: (self: Promise) -> ...any,
    cancel: (self: Promise) -> (),
}

type Callback = {
    onResolve: ((...any) -> ...any)?,
    onReject: ((any) -> ...any)?,
    next: Promise, -- the chained promise returned by :andThen
}

-- ── Promise class ──

local Promise = {}
Promise.__index = Promise

-- Forward declarations: settlement callbacks reference each other.
local settle: (p: any, status: Status, values: { any }) -> ()
local flush: (p: any) -> ()

-- Pack/unpack n-args correctly so we don't lose nils between values.
local function pack(...: any): { any }
    return { n = select("#", ...), ... } :: any
end

local function unpackN(t: { any }): ...any
    return table.unpack(t, 1, (t :: any).n or #t)
end

flush = function(p: any): ()
    -- Drain queued callbacks in FIFO insertion order. Called both at
    -- settlement time and (with no-op effect) on cancel.
    local cbs = p._callbacks
    p._callbacks = {}
    for _, cb in ipairs(cbs) do
        local handler: any
        local passthroughIsResolve: boolean
        if p._status == STATE_RESOLVED then
            handler = cb.onResolve
            passthroughIsResolve = true
        else
            handler = cb.onReject
            passthroughIsResolve = false
        end

        if handler == nil then
            -- No handler for this branch: forward the value/error unchanged
            -- so the caller can attach a handler later in the chain.
            settle(cb.next, p._status, p._values)
        else
            -- task.spawn isolates user code; an error becomes the rejection
            -- value of the chained promise instead of crashing the script.
            task.spawn(function()
                local ok, results = pcall(function()
                    return pack(handler(unpackN(p._values)))
                end)
                if not ok then
                    settle(cb.next, STATE_REJECTED, { results, n = 1 })
                    return
                end
                -- If user returned another Promise, adopt its eventual state.
                local first = (results :: any)[1]
                if (results :: any).n == 1 and typeof(first) == "table"
                    and getmetatable(first) == Promise
                then
                    local typed = first :: any
                    typed:andThen(
                        function(...) settle(cb.next, STATE_RESOLVED, pack(...)) end,
                        function(err) settle(cb.next, STATE_REJECTED, { err, n = 1 }) end
                    )
                else
                    local nextStatus = if passthroughIsResolve then STATE_RESOLVED else STATE_RESOLVED
                    -- A successful onReject converts rejection into resolution
                    -- (Promises/A+ recovery semantics).
                    settle(cb.next, nextStatus, results :: any)
                end
            end)
        end
    end
end

settle = function(p: any, status: Status, values: { any }): ()
    if p._status ~= STATE_PENDING then
        return -- promises settle once; subsequent calls are no-ops
    end
    p._status = status
    p._values = values
    p.Status = status
    flush(p)
end

function Promise.new(executor: (resolve: (...any) -> (), reject: (any) -> (), onCancel: (fn: () -> ()) -> ()) -> ()): Promise
    local self: any = setmetatable({
        _status = STATE_PENDING,
        Status = STATE_PENDING :: Status,
        _values = { n = 0 } :: { any }, -- packed result tuple
        _callbacks = {} :: { Callback }, -- queued .andThen handlers
        _cancelHandlers = {} :: { () -> () }, -- run once on cancel
    }, Promise)

    local function resolve(...: any): ()
        settle(self, STATE_RESOLVED, pack(...))
    end
    local function reject(err: any): ()
        settle(self, STATE_REJECTED, { err, n = 1 })
    end
    local function onCancel(fn: () -> ()): ()
        if self._status == STATE_CANCELLED then
            -- Already cancelled before user attached handler: run immediately.
            task.spawn(fn)
        elseif self._status == STATE_PENDING then
            table.insert(self._cancelHandlers, fn)
        end
        -- If already resolved/rejected, cancel handlers are silently dropped.
    end

    -- Run executor in pcall so a synchronous throw becomes a rejection.
    local ok, err = pcall(executor, resolve, reject, onCancel)
    if not ok and self._status == STATE_PENDING then
        reject(err)
    end

    return (self :: any) :: Promise
end

function Promise:andThen(onResolve: ((...any) -> ...any)?, onReject: ((any) -> ...any)?): Promise
    -- Create the chained promise up-front so we can return it synchronously
    -- regardless of when this promise settles.
    local next = Promise.new(function() end)
    table.insert((self :: any)._callbacks, {
        onResolve = onResolve,
        onReject = onReject,
        next = next,
    })
    -- If we're already settled, drain immediately so the new callback fires.
    if (self :: any)._status ~= STATE_PENDING then
        flush(self)
    end
    return next
end

function Promise:catch(onReject: (any) -> ...any): Promise
    -- Sugar for :andThen(nil, onReject) — explicit form reads better in chains.
    return self:andThen(nil, onReject)
end

function Promise:finally(fn: () -> ()): Promise
    -- Runs in both success and failure paths without altering the value.
    return self:andThen(
        function(...)
            fn()
            return ...
        end,
        function(err)
            fn()
            -- Re-throw so downstream :catch still sees the rejection.
            error(err, 0)
        end
    )
end

function Promise:await(): (boolean, ...any)
    if (self :: any)._status == STATE_RESOLVED then
        return true, unpackN((self :: any)._values)
    elseif (self :: any)._status == STATE_REJECTED or (self :: any)._status == STATE_CANCELLED then
        return false, unpackN((self :: any)._values)
    end
    -- Still pending: park the current coroutine until settlement.
    local thread = coroutine.running()
    self:andThen(
        function(...) task.spawn(thread, true, ...) end,
        function(err) task.spawn(thread, false, err) end
    )
    return coroutine.yield()
end

function Promise:expect(): ...any
    local ok, first, second, third = self:await()
    if not ok then
        -- Surface the rejection as a real Lua error for "expect" semantics.
        error(first, 2)
    end
    return first, second, third
end

function Promise:cancel(): ()
    -- Local alias avoids the Luau "ambiguous syntax" warning that fires when a
    -- statement-starting `(` follows an expression-ending line.
    local s = self :: any
    if s._status ~= STATE_PENDING then
        return -- only pending promises can be cancelled
    end
    s._status = STATE_CANCELLED
    s.Status = STATE_CANCELLED
    s._values = { "Promise cancelled", n = 1 }
    -- Fire user's cleanup hooks before flushing chained .catch handlers.
    for _, fn in ipairs(s._cancelHandlers) do
        task.spawn(fn)
    end
    s._cancelHandlers = {}
    flush(self)
end

-- ── Static constructors ──

function Promise.resolve(...: any): Promise
    local args = pack(...)
    return Promise.new(function(resolve)
        resolve(unpackN(args))
    end)
end

function Promise.reject(err: any): Promise
    return Promise.new(function(_, reject)
        reject(err)
    end)
end

function Promise.delay(seconds: number): Promise
    -- Resolves after `seconds`. Cancellable: cancelling stops the resolve.
    return Promise.new(function(resolve, _, onCancel)
        local cancelled = false
        onCancel(function() cancelled = true end)
        task.delay(seconds, function()
            if not cancelled then
                resolve(seconds)
            end
        end)
    end)
end

-- ── Aggregators ──

function Promise.all(promises: { Promise }): Promise
    return Promise.new(function(resolve, reject)
        local results: { any } = {}
        local remaining = #promises
        if remaining == 0 then
            resolve(results)
            return
        end
        for i, p in ipairs(promises) do
            -- Capture index so out-of-order completion still fills correct slot.
            local typed = p :: any
            typed:andThen(
                function(value)
                    results[i] = value
                    remaining -= 1
                    if remaining == 0 then
                        resolve(results)
                    end
                end,
                -- First rejection wins (subsequent settles are no-ops).
                function(err) reject(err) end
            )
        end
    end)
end

function Promise.any(promises: { Promise }): Promise
    -- Resolves on first success, rejects only if ALL reject.
    return Promise.new(function(resolve, reject)
        local errors: { any } = {}
        local remaining = #promises
        if remaining == 0 then
            reject("Promise.any: empty input")
            return
        end
        for i, p in ipairs(promises) do
            local typed = p :: any
            typed:andThen(
                function(...) resolve(...) end,
                function(err)
                    errors[i] = err
                    remaining -= 1
                    if remaining == 0 then
                        reject(errors)
                    end
                end
            )
        end
    end)
end

function Promise.race(promises: { Promise }): Promise
    -- First to settle (resolve OR reject) wins; everything else is ignored.
    return Promise.new(function(resolve, reject)
        for _, p in ipairs(promises) do
            local typed = p :: any
            typed:andThen(
                function(...) resolve(...) end,
                function(err) reject(err) end
            )
        end
    end)
end

return Promise
