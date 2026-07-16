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
--   local hud = Gaxia.State.Get("HUD")
--   local unbind = Gaxia.UI.StateBinding.BindText(coinLabel, hud, "Coins",
--                    function(v) return `Coins: {v}` end)
-- ─────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")

export type Unbind = () -> ()

export type StateBinding = {
	Bind: (gui: Instance, property: string, state: any, key: string, transform: ((value: any) -> any)?) -> Unbind,
	BindText: (label: Instance, state: any, key: string, format: ((value: any) -> string)?) -> Unbind,
}

-- Client-only; server require returns a no-op stub.
if not RunService:IsClient() then
	return ({
		Bind = function(): Unbind return function() end end,
		BindText = function(): Unbind return function() end end,
	} :: any) :: StateBinding
end

local StateBinding = {}

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

return StateBinding :: StateBinding
