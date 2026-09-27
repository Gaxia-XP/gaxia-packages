--!strict
-- ─────────────────────────────────────────────────────────────
-- Module:   InputManager
-- Location: ReplicatedStorage/Gaxia_Packages/Client/InputManager
-- Purpose:  Unified keybind manager for keyboard / mouse / gamepad.
--           Wraps ContextActionService so game code can declare
--           named actions ("Jump", "Sprint", "Interact") once and
--           freely rebind keys later (settings menu rebinds).
--           Exposes a Signal so other systems can react to ANY
--           bound action without each registering their own
--           ContextActionService callback.
-- ─────────────────────────────────────────────────────────────

local ContextActionService = game:GetService("ContextActionService")
local RunService           = game:GetService("RunService")

-- ── Dependencies ──
-- Shared/Signal directly (pure; no loader round-trip, and the Signal type flows
-- into OnAction below).
local Signal = require(script.Parent.Parent.Shared.Signal)

-- ── Types ──

export type ActionState = "Begin" | "End"

-- A bindable input: a keyboard/gamepad key or a mouse/touch input type.
export type InputKey = Enum.KeyCode | Enum.UserInputType

export type InputBinding = {
	name     : string,
	keys     : { InputKey },
	callback : (actionName: string, state: ActionState) -> (),
}

export type InputManagerType = {
	Bind        : (name: string, keys: { InputKey }, callback: (name: string, state: ActionState) -> ()) -> (),
	Unbind      : (name: string) -> (),
	Rebind      : (name: string, newKeys: { InputKey }) -> boolean,
	IsHeld      : (name: string) -> boolean,
	GetBindings : () -> { [string]: { InputKey } },
	-- (name, state) — fires for every bound action
	OnAction    : Signal.Signal<string, ActionState>,
}

-- Client-only guard. Server require returns a typed empty shell so cross-context
-- requires (e.g. server-side typeof(require(...))) still compile.
if not RunService:IsClient() then
	return ({} :: any) :: InputManagerType
end

-- ── State ──
-- bindings[name] holds the *user-facing* record. We re-register with CAS on
-- Rebind by Unbind+Bind under the hood, so we only need one source of truth.
local bindings : { [string]: InputBinding } = {}
local held     : { [string]: boolean } = {}

-- (name, state)
local OnAction = Signal.new() :: Signal.Signal<string, ActionState>

local InputManager = {}
InputManager.OnAction = OnAction

-- ── Helpers ──

-- Single bridge function we hand to ContextActionService. We translate the CAS
-- UserInputState enum into our simpler "Begin"/"End" string, update the held
-- table, fan out to user callback, and emit on OnAction.
-- WHY a closure factory: CAS calls the same function for every key in the
-- action; we capture `name` once so the bridge knows which logical action
-- fired.
local function makeBridge(name: string): (string, Enum.UserInputState, InputObject) -> Enum.ContextActionResult
	return function(_actionName: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
		-- Cancel = key released while another action stole focus; treat as End
		-- so games clear their "is held" state instead of getting stuck.
		local logical: ActionState? = nil
		if state == Enum.UserInputState.Begin then
			logical = "Begin"
			held[name] = true
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			logical = "End"
			held[name] = false
		end
		if logical == nil then
			-- Change/None — ignore; we only surface Begin/End to consumers.
			return Enum.ContextActionResult.Pass
		end

		local binding = bindings[name]
		if binding then
			-- pcall isolates user-callback errors so one bad listener can't
			-- corrupt the OnAction signal fanout below.
			local ok, err = pcall(binding.callback, name, logical)
			if not ok then
				warn(`[InputManager] callback for '{name}' errored: {tostring(err)}`)
			end
		end
		OnAction:Fire(name, logical)
		return Enum.ContextActionResult.Pass
	end
end

-- ── Bind ──
-- Registers a named action with one or more keys. Re-binding the same name
-- replaces the prior registration cleanly.
function InputManager.Bind(
	name     : string,
	keys     : { InputKey },
	callback : (name: string, state: ActionState) -> ()
): ()
	if bindings[name] then
		-- Quietly replace — saves callers from juggling Unbind boilerplate.
		ContextActionService:UnbindAction(name)
	end
	bindings[name] = {
		name     = name,
		keys     = keys,
		callback = callback,
	}
	held[name] = false
	-- Unpack the keys array because CAS:BindAction takes them as varargs.
	ContextActionService:BindAction(name, makeBridge(name), false, table.unpack(keys))
end

-- ── Unbind ──
-- Removes the action entirely. Safe to call for unknown names.
function InputManager.Unbind(name: string): ()
	if not bindings[name] then return end
	ContextActionService:UnbindAction(name)
	bindings[name] = nil
	held[name] = nil
end

-- ── Rebind ──
-- Swap keys for an existing action without losing the callback. Returns false
-- if the name was never bound (caller can decide whether to Bind fresh).
function InputManager.Rebind(name: string, newKeys: { InputKey }): boolean
	local existing = bindings[name]
	if not existing then return false end
	local cb = existing.callback
	-- Reuse the Bind path so the bridge / held tracking is identical.
	InputManager.Bind(name, newKeys, cb)
	return true
end

-- ── IsHeld ──
-- True while the action's primary state is Begin. Useful for per-frame movement
-- code that doesn't want to maintain its own UserInputService listener.
function InputManager.IsHeld(name: string): boolean
	return held[name] == true
end

-- ── GetBindings ──
-- Shallow-clone the keys per action so the caller (settings UI, rebind menu)
-- can iterate without mutating our internal state.
function InputManager.GetBindings(): { [string]: { InputKey } }
	local copy : { [string]: { InputKey } } = {}
	for n, b in pairs(bindings) do
		local keys = table.create(#b.keys)
		for i, k in ipairs(b.keys) do
			keys[i] = k
		end
		copy[n] = keys
	end
	return copy
end

return InputManager :: InputManagerType
