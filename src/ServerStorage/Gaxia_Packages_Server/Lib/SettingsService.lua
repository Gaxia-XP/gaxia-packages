--!strict
-- ─────────────────────────────────────────────────────────────
-- SettingsService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/SettingsService
-- Purpose : Server-authoritative bridge to Profile.Data.Settings with a
--           key + type whitelist. Client requests use the registered Net
--           RPCs below; this service never owns a raw RemoteFunction.
--
-- Access  : Gaxia.Settings (server)
--   Gaxia.Settings.RegisterSetting("Quality", function(v) return typeof(v) == "number" end)
--   Gaxia.Settings.Set(player, "Music", false)
-- Client  : Shared.Settings (client)
--   Settings.Get("Music") / Settings.GetAll() / Settings.Set("Music", false)
--
-- Transport contract:
--   Settings.Read { key = string? }  -- omitted key returns all settings
--   Settings.Set  { key = string, value = any }
-- ─────────────────────────────────────────────────────────────

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local SETTINGS_KEY: string = "Settings" -- Profile.Data.Settings
local READ_RPC: string = "Settings.Read"
local SET_RPC: string = "Settings.Set"
local MAX_SETTING_KEY_BYTES: number = 64

-- Require NetService through static descendants rather than the lazy Gaxia
-- loader. SettingsService can be required from that loader's no-yield
-- metamethod, while these descendants already exist when the package loads.
local packageRoot = ReplicatedStorage:FindFirstChild("Gaxia_Packages")
assert(packageRoot, "[SettingsService] ReplicatedStorage.Gaxia_Packages missing")
local sharedFolder = packageRoot:FindFirstChild("Shared")
assert(sharedFolder, "[SettingsService] Gaxia_Packages.Shared missing")
local netModule = sharedFolder:FindFirstChild("NetService")
assert(netModule and netModule:IsA("ModuleScript"), "[SettingsService] Shared.NetService missing")
local Net: any = require(netModule)

local SettingsService = {}

-- key → validator(value) -> boolean. Defaults mirror DataManager.DEFAULT_PROFILE.Settings.
local function isBool(value: any): boolean
	return typeof(value) == "boolean"
end

local whitelist: { [string]: (value: any) -> boolean } = {
	Music = isBool,
	SFX = isBool,
}

-- Lazy DataManager (require the loader at call time, not module load — module
-- load runs under the no-yield loader metamethod; calls run in normal context).
local GaxiaServer: any = nil
local function getData(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer.Data
end

-- ── Public server API ──

function SettingsService.RegisterSetting(key: string, validator: (value: any) -> boolean): ()
	if type(key) ~= "string" or #key == 0 or type(validator) ~= "function" then
		return
	end
	whitelist[key] = validator
end

function SettingsService.Get(player: Player, key: string): any
	local Data = getData()
	local settings = Data and Data.Get(player, SETTINGS_KEY)
	if typeof(settings) ~= "table" then
		return nil
	end
	return settings[key]
end

function SettingsService.GetAll(player: Player): { [string]: any }
	local Data = getData()
	local settings = Data and Data.Get(player, SETTINGS_KEY)
	local out: { [string]: any } = {}
	if typeof(settings) == "table" then
		for key, value in pairs(settings) do
			out[key] = value
		end
	end
	return out
end

-- Validate against the whitelist, then persist. Returns false on unknown key,
-- bad value, or profile-not-loaded.
function SettingsService.Set(player: Player, key: string, value: any): boolean
	local check = whitelist[key]
	if not check then
		warn(`[SettingsService] rejected unknown setting '{tostring(key)}'`)
		return false
	end
	if not check(value) then
		warn(`[SettingsService] rejected invalid value for '{key}'`)
		return false
	end
	local Data = getData()
	if not Data then
		return false
	end
	local settings = Data.Get(player, SETTINGS_KEY)
	if typeof(settings) ~= "table" then
		settings = {}
	end
	settings[key] = value
	return Data.Set(player, SETTINGS_KEY, settings) == true
end

-- ── Registered Net RPCs ──

local function isSettingKey(value: any): boolean
	return typeof(value) == "string" and #value > 0 and #value <= MAX_SETTING_KEY_BYTES
end

local function hasOnlyFields(payload: { [any]: any }, allowed: { [string]: boolean }): boolean
	for field in pairs(payload) do
		if typeof(field) ~= "string" or allowed[field] ~= true then
			return false
		end
	end
	return true
end

-- A read either targets one bounded key or uses an empty payload to request a
-- copy of the caller's complete settings table. Reject surplus fields instead
-- of silently accepting a future client-controlled protocol extension.
local function isReadPayload(payload: any): boolean
	if typeof(payload) ~= "table" or not hasOnlyFields(payload, { key = true }) then
		return false
	end
	return payload.key == nil or isSettingKey(payload.key)
end

-- `value` must be present. NetProtocol's tiny budget bounds its supported
-- primitive/table contents before this endpoint-specific shape check runs;
-- the setting's own whitelist remains the domain validator.
local function isSetPayload(payload: any): boolean
	if typeof(payload) ~= "table" or not hasOnlyFields(payload, { key = true, value = true }) then
		return false
	end
	return isSettingKey(payload.key) and payload.value ~= nil
end

-- Net supplies this Player from Roblox, never from the payload. Still require
-- a currently connected player for a state-changing request so a request that
-- races PlayerRemoving cannot mutate detached profile state.
local function maySetOwnSettings(context: any, _payload: any): boolean
	local player = context.player
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

Net.Server.RegisterFunction(READ_RPC, {
	schema = isReadPayload,
	handler = function(context: any, payload: any): any
		if payload.key == nil then
			return SettingsService.GetAll(context.player)
		end
		return SettingsService.Get(context.player, payload.key)
	end,
	rate = 4,
	burst = 8,
	budget = "tiny",
	concurrency = 2,
})

Net.Server.RegisterFunction(SET_RPC, {
	schema = isSetPayload,
	validate = maySetOwnSettings,
	mutation = true,
	handler = function(context: any, payload: any): boolean
		return SettingsService.Set(context.player, payload.key, payload.value)
	end,
	rate = 2,
	burst = 4,
	budget = "tiny",
	concurrency = 1,
})

return SettingsService
