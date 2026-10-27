--!strict
-- ─────────────────────────────────────────────────────────────
-- Settings.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/Settings
-- Purpose : Small client migration API for SettingsService. It replaces the
--           legacy `ReplicatedStorage.Events.Gaxia_Settings:InvokeServer(...)`
--           bridge with typed logical RPCs through `Gaxia.Net.Client.Invoke`.
--
-- Client use:
--   local Settings = require(ReplicatedStorage.Gaxia_Packages.Shared.Settings)
--   local musicEnabled = Settings.Get("Music") -- value or nil
--   local all = Settings.GetAll()               -- table (empty on rejection)
--   local saved = Settings.Set("Music", false) -- boolean
--
-- Migration semantics: return values intentionally retain the legacy shape:
-- `Get` returns a raw setting value/nil, `GetAll` returns a raw table, and
-- `Set` returns a boolean. Transport and schema errors become those existing
-- failure values instead of leaking Net's `{ ok, code }` response into UI code.
-- Server callers should continue to use GaxiaServer.Settings directly.
-- ─────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")

assert(RunService:IsClient(), "[Settings] Shared.Settings is client-only")

local Net = require(script.Parent:FindFirstChild("NetService") :: ModuleScript) :: any

local READ_RPC: string = "Settings.Read"
local SET_RPC: string = "Settings.Set"
local MAX_SETTING_KEY_BYTES: number = 64

local Settings = {}

local function isSettingKey(value: any): boolean
	return typeof(value) == "string" and #value > 0 and #value <= MAX_SETTING_KEY_BYTES
end

function Settings.Get(key: string): any
	if not isSettingKey(key) then
		return nil
	end

	local result = Net.Client.Invoke(READ_RPC, { key = key })
	if result.ok == true then
		return result.data
	end
	return nil
end

function Settings.GetAll(): { [string]: any }
	local result = Net.Client.Invoke(READ_RPC, {})
	if result.ok == true and typeof(result.data) == "table" then
		return result.data
	end
	return {}
end

function Settings.Set(key: string, value: any): boolean
	if not isSettingKey(key) or value == nil then
		return false
	end

	local result = Net.Client.Invoke(SET_RPC, { key = key, value = value })
	return result.ok == true and result.data == true
end

return Settings
