--!strict
--[[
	Module : ReplicatedState
	Location: ReplicatedStorage/Gaxia_Packages/Shared/ReplicatedState
	Purpose : Reactive server→client state sync via Folder attributes. Roblox
	          attributes replicate for free and fire `GetAttributeChangedSignal`
	          on the client, so we lean on the engine instead of rolling our
	          own RemoteEvent diff protocol.

	Limitation: attribute values must be Roblox-native scalars —
	  bool / number / string / Vector2 / Vector3 / CFrame / Color3 / UDim /
	  UDim2 / Rect / NumberSequence / ColorSequence / NumberRange / BrickColor.
	  For nested tables, encode with HttpService:JSONEncode and store the string,
	  or use NetService to broadcast diff events explicitly.

	Server:
		local state = State.Create("Game", { Stage = 1, Timer = 60 })
		state:Set("Stage", 2)             -- replicates to every client
		state:OnChanged("Stage", function(new, old) ... end)

	Client:
		local state = State.Get("Game")   -- yields until server creates
		print(state:Get("Stage"))
		state:OnChanged("Stage", function(new, old) ... end)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

-- WHY the extra Studio clause: in Edit mode via tooling (plugin runners, MCP
-- tests) IsServer()/IsClient() are BOTH false — client paths would stall on
-- WaitForChild and assert. Edit mode has no real client, so server semantics
-- are the correct default there. Play mode and live servers are unaffected
-- (IsRunning() gates the clause off).
local IS_SERVER : boolean = RunService:IsServer()
	or (RunService:IsStudio() and not RunService:IsRunning())

-- Serializer (sibling Shared module) for nested-table values (Phase 19.2).
-- FindFirstChild (no yield) — Serializer is a present sibling with a pure body.
local Serializer = require(script.Parent:FindFirstChild("Serializer") :: ModuleScript) :: any

-- ── Types ──

export type StateObject = {
	_folder : Folder,
	Get     : (self: StateObject, key: string) -> any,
	Set     : (self: StateObject, key: string, value: any) -> (),
	OnChanged : (self: StateObject, key: string, fn: (new: any, old: any) -> ()) -> RBXScriptConnection,
	GetAll  : (self: StateObject) -> { [string]: any },
	Destroy : (self: StateObject) -> (),
	-- Phase 19.2 — nested-table values (serialized to a string attribute):
	SetTable : (self: StateObject, key: string, value: { [any]: any }) -> (),
	GetTable : (self: StateObject, key: string) -> any,
	OnTableChanged : (self: StateObject, key: string, fn: (new: any, old: any) -> ()) -> RBXScriptConnection,
}

-- ── Container bootstrap ──

local container : Folder
do
	local existing = ReplicatedStorage:FindFirstChild("GaxiaState")
	if existing and existing:IsA("Folder") then
		container = existing
	elseif IS_SERVER then
		container = Instance.new("Folder")
		container.Name = "GaxiaState"
		container.Parent = ReplicatedStorage
	else
		local waited = ReplicatedStorage:WaitForChild("GaxiaState", 10)
		assert(waited and waited:IsA("Folder"), "[ReplicatedState] GaxiaState folder missing")
		container = waited :: Folder
	end
end

-- ── Wrapper class ──

local StateClass = {}
StateClass.__index = StateClass

local function wrap(folder: Folder): StateObject
	local self = setmetatable({ _folder = folder }, StateClass)
	return (self :: any) :: StateObject
end

function StateClass:Get(key: string): any
	return self._folder:GetAttribute(key)
end

function StateClass:Set(key: string, value: any): ()
	-- Roblox SetAttribute is server-authoritative and replicates automatically.
	-- Calling from the client mutates only the local snapshot — server is not
	-- notified, and the value reverts the next time the server writes.
	self._folder:SetAttribute(key, value)
end

-- ── Nested-table values (Phase 19.2) ──
-- Roblox attributes only hold scalars, so a nested table is serialized to a JSON
-- string (round-tripping Vector3/Vector2/CFrame/Color3 via Serializer) and stored
-- under `key`. Use SetTable/GetTable consistently for table keys.
function StateClass:SetTable(key: string, value: { [any]: any }): ()
	self._folder:SetAttribute(key, Serializer.Encode(value))
end

function StateClass:GetTable(key: string): any
	local s = self._folder:GetAttribute(key)
	if typeof(s) ~= "string" then
		return nil
	end
	local ok, decoded = pcall(Serializer.Decode, s)
	return if ok then decoded else nil
end

-- Like OnChanged but decodes the JSON string back to a table for new/old.
function StateClass:OnTableChanged(key: string, fn: (new: any, old: any) -> ()): RBXScriptConnection
	local function decode(s: any): any
		if typeof(s) ~= "string" then
			return nil
		end
		local ok, d = pcall(Serializer.Decode, s)
		return if ok then d else nil
	end
	local last = decode(self._folder:GetAttribute(key))
	return self._folder:GetAttributeChangedSignal(key):Connect(function()
		local new = decode(self._folder:GetAttribute(key))
		local old = last
		last = new
		fn(new, old)
	end)
end

-- Returns a connection — caller controls lifetime via :Disconnect().
function StateClass:OnChanged(key: string, fn: (new: any, old: any) -> ()): RBXScriptConnection
	local lastValue = self._folder:GetAttribute(key)
	return self._folder:GetAttributeChangedSignal(key):Connect(function()
		local newValue = self._folder:GetAttribute(key)
		local old = lastValue
		lastValue = newValue
		fn(newValue, old)
	end)
end

function StateClass:GetAll(): { [string]: any }
	return self._folder:GetAttributes()
end

function StateClass:Destroy(): ()
	-- Server only — clients can't destroy replicated state.
	if not IS_SERVER then return end
	self._folder:Destroy()
end

-- ── Public module ──

local State = {}

-- Cache so repeated Create / Get for the same name return the same object.
local cache : { [string]: StateObject } = {}

-- Server: create a state container with `defaults`. Existing attributes are
-- preserved (i.e. defaults only fill MISSING keys), so Create is idempotent
-- and safe to call from multiple bootstrap scripts.
function State.Create(name: string, defaults: { [string]: any }?): StateObject
	assert(IS_SERVER, "State.Create is server-only")
	assert(typeof(name) == "string" and #name > 0, "State.Create requires a non-empty name")

	local folder = container:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = container
	end
	if defaults then
		for k, v in pairs(defaults) do
			if folder:GetAttribute(k) == nil then
				folder:SetAttribute(k, v)
			end
		end
	end

	local obj = cache[name]
	if not obj then
		obj = wrap(folder :: Folder)
		cache[name] = obj
	end
	return obj
end

-- Server: returns the live state object, or nil if it doesn't exist yet.
-- Client: yields up to 10s waiting for the server to create the container.
function State.Get(name: string): StateObject?
	if cache[name] then return cache[name] end
	local folder : Instance?
	if IS_SERVER then
		folder = container:FindFirstChild(name)
	else
		folder = container:WaitForChild(name, 10)
	end
	if not folder or not folder:IsA("Folder") then return nil end
	local obj = wrap(folder :: Folder)
	cache[name] = obj
	return obj
end

return State
