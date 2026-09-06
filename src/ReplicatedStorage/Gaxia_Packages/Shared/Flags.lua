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
local CollectionService = game:GetService("CollectionService")

local RunService = game:GetService("RunService")
-- WHY the extra Studio clause: in Edit mode via tooling IsServer() is false and
-- client paths would stall/assert. Edit mode has no real client, so server
-- semantics are the default there; Play mode and live servers are unaffected.
local IS_SERVER : boolean = RunService:IsServer()
	or (RunService:IsStudio() and not RunService:IsRunning())

local FLAGS_STATE : string = "GaxiaFlags"

-- Lazy ReplicatedState require: its body WaitForChild's GaxiaState on the client,
-- which would yield under the shared loader metamethod. Resolve at USE time
-- (normal context) instead.
local _State: any = nil
local function stateModule(): any
	if not _State then
		_State = require(script.Parent:FindFirstChild("ReplicatedState") :: ModuleScript)
	end
	return _State
end

local Flags = {}

local stateObj: any = nil
local function getState(): any
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
	getState():Set(name, value)
end

function Flags.Get(name: string, default: any?): any
	local s = getState()
	if not s then
		return default
	end
	local v = s:Get(name)
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
	return s:OnChanged(name, fn)
end

return Flags
