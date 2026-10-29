--!strict
-- ─────────────────────────────────────────────────────────────
-- StateBinding.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Client/UI/StateBinding
-- Purpose : Reactively bind a GUI property to a ReplicatedState key so the HUD
--           updates on change instead of polling every frame / 0.2s. Bind()
--           applies the value immediately and on every OnChanged, with an
--           optional transform; returns an unbind() to disconnect.
--
-- Access  : Gaxia.UI.StateBinding  (client)
--   local hud = Gaxia.State.Get("HUD")   -- nil until the server has created it
--   if hud then
--       local unbind = Gaxia.UI.StateBinding.BindText(coinLabel, hud, "Coins",
--                        function(v) return `Coins: {v}` end)
--   end
-- ─────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")

-- Types only: `typeof(require(...))` in a type position is erased at compile time,
-- so this does NOT load ReplicatedState (its body creates / waits for GaxiaState).
-- The state object callers pass in (Gaxia.State.Create / Gaxia.State.Get).
export type StateObject = typeof(require(script.Parent.Parent.Parent.Shared.ReplicatedState).Create("", nil))

export type Unbind = () -> ()

local StateBinding = {}
-- The module's own type (Bind / BindText below), so the server stub and the client
-- module share one type and `Gaxia.UI.StateBinding.<method>` autocompletes.
export type StateBinding = typeof(StateBinding)

-- Client-only; server require returns a no-op stub.
if not RunService:IsClient() then
	return ({
		Bind = function(): Unbind return function() end end,
		BindText = function(): Unbind return function() end end,
	} :: any) :: typeof(StateBinding)
end

-- `state`: a StateObject from Gaxia.State.Get / Create, or any object with the same
-- :Get(key) / :OnChanged(key, fn) methods (kept `any` so Gaxia.State.Get's optional
-- result and duck-typed stores are accepted as before; annotate your own locals
-- with StateBinding.StateObject for autocomplete).

-- Bind gui[property] to state:Get(key), updating on every OnChanged. Returns unbind().
function StateBinding.Bind(gui: Instance, property: string, state: any, key: string, transform: ((value: any) -> any)?): Unbind
	local function apply(value: any)
		local v = if transform then transform(value) else value
		local ok = pcall(function()
			(gui :: any)[property] = v
		end)
		if not ok then
			warn(`[StateBinding] failed to set .{property} on {gui:GetFullName()}`)
		end
	end

	apply(state:Get(key))
	local conn = state:OnChanged(key, function(new: any)
		apply(new)
	end)

	return function()
		conn:Disconnect()
	end
end

-- Convenience: bind a TextLabel/TextButton .Text to a state key, with optional format.
function StateBinding.BindText(label: Instance, state: any, key: string, format: ((value: any) -> string)?): Unbind
	return StateBinding.Bind(label, "Text", state, key, function(value: any): string
		if format then
			return format(value)
		end
		return tostring(value)
	end)
end

return StateBinding
