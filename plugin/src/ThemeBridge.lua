--!strict
-- ─────────────────────────────────────────────────────────────
-- ThemeBridge.lua
-- Location: plugin/src/ThemeBridge
-- Purpose : Reverse-map Color3 -> Gaxia Theme token name. Used by
--           the Serializer to emit `Theme.Color("Primary")` instead
--           of a raw RGB literal whenever a property value exactly
--           matches a known token.
--
-- Theme source: prefer the open place's Theme (ReplicatedStorage.
-- Gaxia_Packages.Shared.Theme); fall back to the plugin's bundled
-- Payload.Gaxia_Packages.Shared.Theme. Exact-match only — no nearest-
-- neighbour matching, no per-channel tolerance.
-- ─────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ThemeBridge = {}

local function findTheme(): ModuleScript?
	local place = ReplicatedStorage:FindFirstChild("Gaxia_Packages")
	if place then
		local shared = place:FindFirstChild("Shared")
		if shared then
			local mod = shared:FindFirstChild("Theme")
			if mod and mod:IsA("ModuleScript") then return mod end
		end
	end
	-- Plugin Payload fallback: only present in the installed-plugin context.
	local plugin_self = script.Parent
	local payload = plugin_self and plugin_self:FindFirstChild("Payload")
	if payload then
		local gp = payload:FindFirstChild("Gaxia_Packages")
		local shared = gp and gp:FindFirstChild("Shared")
		local mod = shared and shared:FindFirstChild("Theme")
		if mod and mod:IsA("ModuleScript") then return mod end
	end
	return nil
end

local function buildMap(themeMod: ModuleScript): ({ [string]: string }, { [string]: Color3 })
	local Theme = require(themeMod) :: any
	local byKey: { [string]: string } = {}
	local byName: { [string]: Color3 } = {}

	-- Theme exposes Theme.Get() -> Tokens where Tokens.Color is { [string]: Color3 }.
	-- This is the actual surface: no Theme.Colors table, no Theme.TokenNames list.
	if typeof(Theme.Get) == "function" then
		local tok = Theme.Get()
		if typeof(tok) == "table" and typeof(tok.Color) == "table" then
			for name, c in pairs(tok.Color) do
				if typeof(c) == "Color3" and typeof(name) == "string" then
					byKey[tostring(c)] = name
					byName[name] = c
				end
			end
			return byKey, byName
		end
	end

	-- Fallback branch: Theme.Colors table (not present in current build, kept for
	-- forward-compatibility if the module is ever restructured).
	if typeof(Theme.Colors) == "table" then
		for name, c in pairs(Theme.Colors) do
			if typeof(c) == "Color3" and typeof(name) == "string" then
				byKey[tostring(c)] = name
				byName[name] = c
			end
		end
		return byKey, byName
	end

	-- Fallback branch: Theme.TokenNames list + Theme.Color() accessor.
	if typeof(Theme.TokenNames) == "table" and typeof(Theme.Color) == "function" then
		for _, name in ipairs(Theme.TokenNames) do
			local ok, c = pcall(Theme.Color, name)
			if ok and typeof(c) == "Color3" then
				byKey[tostring(c)] = name
				byName[name] = c
			end
		end
	end

	return byKey, byName
end

export type Bridge = {
	match: (self: Bridge, c: Color3) -> string?,
	tokensUsed: (self: Bridge) -> { string },
}

function ThemeBridge.new(): Bridge
	local self = { _byKey = {}, _byName = {}, _used = {} }
	local mod = findTheme()
	if mod then
		local byKey, byName = buildMap(mod)
		self._byKey = byKey
		self._byName = byName
	end
	function self:match(c: Color3): string?
		local name = self._byKey[tostring(c)]
		if name and not self._used[name] then
			self._used[name] = true
		end
		return name
	end
	function self:tokensUsed(): { string }
		local out: { string } = {}
		for name in pairs(self._used) do table.insert(out, name) end
		table.sort(out)
		return out
	end
	return self :: any
end

return ThemeBridge
