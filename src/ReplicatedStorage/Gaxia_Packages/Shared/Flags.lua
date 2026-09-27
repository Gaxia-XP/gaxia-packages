--!strict
-- ─────────────────────────────────────────────────────────────
-- Flags.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/Flags
-- Purpose : Runtime feature flags / config overrides on top of ReplicatedState.
--           Server Set()s a flag and it replicates to every client (read via
--           Get/IsEnabled/OnChanged). Lets you toggle a misbehaving AntiCheat
--           detector or override a threshold WITHOUT a code push, and gate
--           features at runtime — the override layer Constants (frozen) can't be.
--
-- Access  : Gaxia.Flags  (shared)
--   -- server: Gaxia.Flags.Set("Detector.Teleport", false)   -- disable at runtime
--   -- anywhere: if Gaxia.Flags.IsEnabled("DoubleXP") then ... end
-- ─────────────────────────────────────────────────────────────
local RunService = game:GetService("RunService")
local IS_SERVER : boolean = RunService:IsServer()

local FLAGS_STATE : string = "GaxiaFlags"

-- Types only: `typeof(require(...))` in a type position is erased at compile time,
-- so it does NOT load ReplicatedState here.
type StateModule = typeof(require(script.Parent.ReplicatedState))
type StateObject = typeof(require(script.Parent.ReplicatedState).Create("", nil))

-- Lazy ReplicatedState require (keep-lazy): its body creates GaxiaState on the
-- server and WaitForChild's it on the client, which would yield under the shared
-- loader metamethod. Resolve at USE time (normal context) instead.
local _State: StateModule? = nil
local function stateModule(): StateModule
	local cached = _State
	if cached then
		return cached
	end
	local State = require(script.Parent.ReplicatedState)
	_State = State
	return State
end

local Flags = {}

-- Flag names are dotted ("AntiCheat.Enforce"), but a Roblox attribute name may only
-- hold letters, digits and "_" (at most 100 characters), so SetAttribute would
-- throw. Every name is stored under an escaped attribute name: "_" becomes "__"
-- and any other character becomes "_" plus its two hex digits, so
-- "AntiCheat.Enforce" is stored as "AntiCheat_2EEnforce". The mapping is
-- one-to-one, and Set/Get/OnChanged all go through it, so callers only ever see
-- the dotted names.
local MAX_ATTRIBUTE_NAME : number = 100

local function attributeName(name: string): string
	local encoded = string.gsub(name, "[^%w]", function(c: string): string
		if c == "_" then
			return "__"
		end
		return string.format("_%02X", string.byte(c))
	end)
	assert(#encoded > 0, "[Flags] flag name must be a non-empty string")
	assert(#encoded <= MAX_ATTRIBUTE_NAME, `[Flags] flag name too long: "{name}"`)
	-- Attribute names starting with "RBX" are reserved by Roblox.
	if string.sub(encoded, 1, 3) == "RBX" then
		encoded = "_" .. string.format("%02X", string.byte(encoded)) .. string.sub(encoded, 2)
	end
	return encoded
end

local stateObj: StateObject? = nil
local function getState(): StateObject?
	if stateObj then
		return stateObj
	end
	local State = stateModule()
	if IS_SERVER then
		stateObj = State.Create(FLAGS_STATE, {})
	else
		stateObj = State.Get(FLAGS_STATE)
	end
	return stateObj
end

-- ── Public API ──

function Flags.Set(name: string, value: any): ()
	assert(IS_SERVER, "Flags.Set is server-only")
	-- Server: getState() always returns the object State.Create made.
	local s = getState() :: StateObject
	s:Set(attributeName(name), value)
end

function Flags.Get(name: string, default: any?): any
	local s = getState()
	if not s then
		return default
	end
	local v = s:Get(attributeName(name))
	if v == nil then
		return default
	end
	return v
end

function Flags.IsEnabled(name: string): boolean
	return Flags.Get(name, false) == true
end

function Flags.OnChanged(name: string, fn: (new: any, old: any) -> ()): RBXScriptConnection?
	local s = getState()
	if not s then
		return nil
	end
	return s:OnChanged(attributeName(name), fn)
end

return Flags
