--!strict
--[[
	Deprecated Maid-compatible facade backed by the Wally-managed Janitor.
	New code should use Gaxia.Janitor directly.

	The facade keeps the legacy LIFO cleanup order so existing consumers can
	migrate without changing teardown behaviour.
]]

local RunService = game:GetService("RunService")
local Janitor = require(script.Parent.Parent.Packages.Janitor)

export type Task = RBXScriptConnection | Instance | () -> () | { Destroy: (any) -> () }

export type Maid = {
	GiveTask: (self: Maid, task: Task) -> Task,
	GiveBindToRenderStep: (
		self: Maid,
		name: string,
		priority: number,
		fn: (dt: number) -> ()
	) -> (),
	DoCleaning: (self: Maid) -> (),
	Destroy: (self: Maid) -> (),
}

local Maid = {}
Maid.__index = Maid

function Maid.new(): Maid
	return setmetatable({
		_taskJanitors = {} :: { any },
	}, Maid) :: any
end

function Maid:GiveTask(cleanupTask: Task): Task
	assert(cleanupTask ~= nil, "Maid:GiveTask received nil")
	local taskJanitor = Janitor.new()
	taskJanitor:Add(cleanupTask)
	table.insert((self :: any)._taskJanitors, taskJanitor)
	return cleanupTask
end

function Maid:GiveBindToRenderStep(name: string, priority: number, fn: (dt: number) -> ()): ()
	RunService:BindToRenderStep(name, priority, fn)
	self:GiveTask(function()
		pcall(function()
			RunService:UnbindFromRenderStep(name)
		end)
	end)
end

function Maid:DoCleaning(): ()
	local maidState = self :: any
	local taskJanitors = maidState._taskJanitors
	maidState._taskJanitors = {}
	for index = #taskJanitors, 1, -1 do
		local ok, cleanupError = pcall(function()
			taskJanitors[index]:Cleanup()
		end)
		if not ok then
			warn(`[Maid] cleanup task #{index} errored: {cleanupError}`)
		end
	end
end

function Maid:Destroy(): ()
	self:DoCleaning()
	setmetatable(self :: any, nil)
end

return Maid
