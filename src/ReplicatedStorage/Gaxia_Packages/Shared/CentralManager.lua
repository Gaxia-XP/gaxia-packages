--!strict
--[[
	CentralManager.lua
	Location: ReplicatedStorage/Gaxia_Packages/Shared/CentralManager
	Purpose: Runs named periodic tasks on one Heartbeat connection.
]]

local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Signal)

export type TaskOptions = {
	name: string?,
	duration: number?,
	priority: number?,
	startTime: number?,
	endTime: number?,
}

export type TaskHandle = {
	name: string,
	cancel: () -> (),
	Cancel: (self: TaskHandle) -> (),
	Pause: (self: TaskHandle) -> (),
	Resume: (self: TaskHandle) -> (),
	IsActive: (self: TaskHandle) -> boolean,
}

type Callback = (elapsed: number) -> ()

type TaskRecord = {
	id: number,
	name: string,
	duration: number,
	priority: number,
	startTime: number,
	endTime: number,
	callback: Callback,
	elapsed: number,
	paused: boolean,
}

export type SignalConnection = {
	Connected: boolean,
	Disconnect: (self: SignalConnection) -> (),
	Destroy: (self: SignalConnection) -> (),
}

export type TaskSignal = {
	Fire: (self: TaskSignal, name: string) -> (),
	FireDeferred: (self: TaskSignal, name: string) -> (),
	Connect: (self: TaskSignal, callback: (name: string) -> ()) -> SignalConnection,
	Once: (self: TaskSignal, callback: (name: string) -> ()) -> SignalConnection,
	DisconnectAll: (self: TaskSignal) -> (),
	Destroy: (self: TaskSignal) -> (),
	Wait: (self: TaskSignal) -> string,
}

export type CentralManager = {
	Started: TaskSignal,
	Stopped: TaskSignal,
	Paused: TaskSignal,
	Resumed: TaskSignal,
	Canceled: TaskSignal,
	Finished: TaskSignal,
	Register: (self: CentralManager, options: TaskOptions, callback: Callback) -> TaskHandle,
	Cancel: (self: CentralManager, name: string) -> boolean,
	Pause: (self: CentralManager, name: string) -> boolean,
	Resume: (self: CentralManager, name: string) -> boolean,
	Destroy: (self: CentralManager) -> (),
}

type InternalCentralManager = CentralManager & {
	_tasks: { [string]: TaskRecord },
	_connection: RBXScriptConnection?,
	_nextId: number,
	_destroyed: boolean,
}

local CentralManager = {}
CentralManager.__index = CentralManager

local function isFinite(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function disconnectIfIdle(self: InternalCentralManager, lastTaskName: string): ()
	if next(self._tasks) ~= nil then
		return
	end

	local connection = self._connection
	if connection then
		connection:Disconnect()
		self._connection = nil
		self.Stopped:Fire(lastTaskName)
	end
end

local function removeTask(
	self: InternalCentralManager,
	name: string,
	expectedId: number?,
	finished: boolean
): boolean
	local record = self._tasks[name]
	if not record or (expectedId ~= nil and record.id ~= expectedId) then
		return false
	end

	self._tasks[name] = nil
	if finished then
		self.Finished:Fire(name)
	else
		self.Canceled:Fire(name)
	end
	disconnectIfIdle(self, name)
	return true
end

local function setPaused(
	self: InternalCentralManager,
	name: string,
	expectedId: number?,
	paused: boolean
): boolean
	local record = self._tasks[name]
	if not record or (expectedId ~= nil and record.id ~= expectedId) or record.paused == paused then
		return false
	end

	record.paused = paused
	if paused then
		self.Paused:Fire(name)
	else
		self.Resumed:Fire(name)
	end
	return true
end

local function onHeartbeat(self: InternalCentralManager, deltaTime: number): ()
	local now = workspace:GetServerTimeNow()
	local due: { TaskRecord } = {}
	local finished: { TaskRecord } = {}

	for _, record in self._tasks do
		if now >= record.endTime then
			table.insert(finished, record)
		elseif not record.paused and now >= record.startTime then
			record.elapsed += deltaTime
			if record.duration == 0 or record.elapsed >= record.duration then
				table.insert(due, record)
			end
		end
	end

	table.sort(due, function(left, right)
		if left.priority == right.priority then
			return left.id < right.id
		end
		return left.priority < right.priority
	end)

	for _, record in due do
		if self._tasks[record.name] == record then
			local elapsed = record.elapsed
			record.elapsed = if record.duration == 0 then 0 else elapsed % record.duration
			task.spawn(record.callback, elapsed)
		end
	end

	for _, record in finished do
		removeTask(self, record.name, record.id, true)
	end
end

local function ensureConnected(self: InternalCentralManager): ()
	if self._connection then
		return
	end

	self._connection = RunService.Heartbeat:Connect(function(deltaTime)
		onHeartbeat(self, deltaTime)
	end)
end

local function newManager(): InternalCentralManager
	local self = setmetatable({
		_tasks = {},
		_connection = nil,
		_nextId = 0,
		_destroyed = false,
		Started = Signal.new() :: any,
		Stopped = Signal.new() :: any,
		Paused = Signal.new() :: any,
		Resumed = Signal.new() :: any,
		Canceled = Signal.new() :: any,
		Finished = Signal.new() :: any,
	}, CentralManager)
	return (self :: any) :: InternalCentralManager
end

function CentralManager.Register(
	self: InternalCentralManager,
	options: TaskOptions,
	callback: Callback
): TaskHandle
	assert(not self._destroyed, "CentralManager is destroyed")
	assert(type(options) == "table", "CentralManager:Register options must be a table")
	assert(type(callback) == "function", "CentralManager:Register callback must be a function")

	local duration = options.duration or 0
	local priority = options.priority or 0
	local startTime = options.startTime or workspace:GetServerTimeNow()
	local endTime = options.endTime or math.huge
	assert(
		isFinite(duration) and duration >= 0,
		"CentralManager duration must be a finite non-negative number"
	)
	assert(isFinite(priority), "CentralManager priority must be finite")
	assert(isFinite(startTime), "CentralManager startTime must be finite")
	assert(
		endTime == math.huge or isFinite(endTime),
		"CentralManager endTime must be finite or math.huge"
	)
	assert(endTime >= startTime, "CentralManager endTime must not be before startTime")

	self._nextId += 1
	local id = self._nextId
	local name = options.name
	if name == nil or name == "" then
		name = `task_{id}`
	end
	assert(type(name) == "string", "CentralManager task name must be a string")

	if self._tasks[name] then
		removeTask(self, name, nil, false)
	end

	self._tasks[name] = {
		id = id,
		name = name,
		duration = duration,
		priority = priority,
		startTime = startTime,
		endTime = endTime,
		callback = callback,
		elapsed = 0,
		paused = false,
	}
	ensureConnected(self)
	self.Started:Fire(name)

	local handle = {} :: any
	handle.name = name
	handle.cancel = function()
		removeTask(self, name, id, false)
	end
	handle.Cancel = handle.cancel
	handle.Pause = function()
		setPaused(self, name, id, true)
	end
	handle.Resume = function()
		setPaused(self, name, id, false)
	end
	handle.IsActive = function(): boolean
		local record = self._tasks[name]
		return record ~= nil and record.id == id
	end
	return handle :: TaskHandle
end

function CentralManager.Cancel(self: InternalCentralManager, name: string): boolean
	assert(type(name) == "string", "CentralManager:Cancel name must be a string")
	return removeTask(self, name, nil, false)
end

function CentralManager.Pause(self: InternalCentralManager, name: string): boolean
	assert(type(name) == "string", "CentralManager:Pause name must be a string")
	return setPaused(self, name, nil, true)
end

function CentralManager.Resume(self: InternalCentralManager, name: string): boolean
	assert(type(name) == "string", "CentralManager:Resume name must be a string")
	return setPaused(self, name, nil, false)
end

function CentralManager.Destroy(self: InternalCentralManager): ()
	if self._destroyed then
		return
	end
	self._destroyed = true

	local names = {}
	for name in self._tasks do
		table.insert(names, name)
	end
	for _, name in names do
		removeTask(self, name, nil, false)
	end

	self.Started:Destroy()
	self.Stopped:Destroy()
	self.Paused:Destroy()
	self.Resumed:Destroy()
	self.Canceled:Destroy()
	self.Finished:Destroy()
end

return newManager() :: CentralManager
