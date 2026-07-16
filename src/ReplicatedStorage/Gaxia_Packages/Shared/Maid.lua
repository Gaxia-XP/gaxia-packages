--!strict
--[[
    Module:   Maid
    Location: ReplicatedStorage/Gaxia_Packages/Shared
    Purpose:  Classic LIFO cleanup container. Accepts RBXScriptConnection,
              Instance, function, or any table with a :Destroy method via
              :GiveTask. :DoCleaning / :Destroy unwind in reverse insertion
              order. Provides :GiveBindToRenderStep with auto-unbind.
--]]


local RunService = game:GetService("RunService")

-- ── Types ──

export type Task = RBXScriptConnection | Instance | () -> () | { Destroy: (any) -> () }

export type Maid = {
    GiveTask: (self: Maid, task: Task) -> Task,
    GiveBindToRenderStep: (self: Maid, name: string, priority: number, fn: (dt: number) -> ()) -> (),
    DoCleaning: (self: Maid) -> (),
    Destroy: (self: Maid) -> (),
}

-- ── Cleanup dispatch ──
-- Centralised so :GiveTask and :DoCleaning agree on what "clean" means
-- for each task type.

local function cleanupOne(task: Task): ()
    local kind = typeof(task)
    if kind == "RBXScriptConnection" then
        (task :: RBXScriptConnection):Disconnect()
    elseif kind == "Instance" then
        (task :: Instance):Destroy()
    elseif kind == "function" then
        (task :: () -> ())()
    elseif kind == "table" then
        local destroy = (task :: any).Destroy
        if typeof(destroy) == "function" then
            destroy(task)
        end
    end
end

-- ── Maid ──

local Maid = {}
Maid.__index = Maid

function Maid.new(): Maid
    local self = setmetatable({
        _tasks = {} :: { Task }, -- ordered stack; cleared LIFO
    }, Maid)
    return (self :: any) :: Maid
end

function Maid:GiveTask(task: Task): Task
    assert(task ~= nil, "Maid:GiveTask received nil")
    -- Append to end so LIFO unwinding matches construction order.
    table.insert((self :: any)._tasks, task)
    return task
end

function Maid:GiveBindToRenderStep(name: string, priority: number, fn: (dt: number) -> ()): ()
    RunService:BindToRenderStep(name, priority, fn)
    -- Wrap the unbind in a function task so :DoCleaning handles it generically.
    self:GiveTask(function()
        -- pcall guards against double-unbind if the user already cleaned manually.
        pcall(function()
            RunService:UnbindFromRenderStep(name)
        end)
    end)
end

function Maid:DoCleaning(): ()
    -- Local alias avoids the Luau "ambiguous syntax" warning that fires when a
    -- statement-starting `(` follows an expression-ending line.
    local s = self :: any
    local tasks = s._tasks
    -- Detach the list before iterating so tasks that re-add to this Maid
    -- during cleanup get queued for the *next* cleaning pass, not silently lost.
    s._tasks = {}
    for i = #tasks, 1, -1 do
        local ok, err = pcall(cleanupOne, tasks[i])
        if not ok then
            warn(`[Maid] cleanup task #{i} errored: {err}`)
        end
    end
end

function Maid:Destroy(): ()
    self:DoCleaning()
    -- Clear metatable so future calls fail fast instead of silently no-oping.
    setmetatable(self :: any, nil)
end

return Maid
