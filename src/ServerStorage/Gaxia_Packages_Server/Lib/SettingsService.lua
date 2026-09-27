--!strict
-- ─────────────────────────────────────────────────────────────
-- SettingsService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/SettingsService
-- Purpose : Server-authoritative bridge to Profile.Data.Settings with a
--           key + type WHITELIST, plus a client RemoteFunction so the (already
--           built) settings UI can read/write. Persisted Settings (Music/SFX…)
--           were previously dead — no endpoint reached them. Unknown keys and
--           bad-typed values are rejected (anti-exploit).
--
-- Access  : Gaxia.Settings  (server) — list "Settings" in Features (or touch it at
--           boot) to create the client bridge before a client invokes it:
--   Gaxia.Settings.RegisterSetting("Quality", function(v) return typeof(v)=="number" end)
--   Gaxia.Settings.Set(player, "Music", false)
-- Client  : RemoteFunction ReplicatedStorage.Events.Gaxia_Settings
--   remote:InvokeServer("get"|"getAll"|"set", key, value)
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Lifecycle   = require(script.Parent.ServiceLifecycle)
local DataManager = require(script.Parent.DataManager)

local SETTINGS_KEY : string = "Settings"        -- Profile.Data.Settings
local REMOTE_NAME  : string = "Gaxia_Settings"

local SettingsService = {}

-- key → validator(value) -> boolean. Defaults mirror DataManager.DEFAULT_PROFILE.Settings.
local function isBool(v: any): boolean
	return typeof(v) == "boolean"
end
local whitelist: { [string]: (value: any) -> boolean } = {
	Music = isBool,
	SFX   = isBool,
}

-- ── Public API ──

function SettingsService.RegisterSetting(key: string, validator: (value: any) -> boolean): ()
	if type(key) ~= "string" or #key == 0 or type(validator) ~= "function" then
		return
	end
	whitelist[key] = validator
end

function SettingsService.Get(player: Player, key: string): any
	local settings = DataManager.Get(player, SETTINGS_KEY)
	if typeof(settings) ~= "table" then
		return nil
	end
	return settings[key]
end

function SettingsService.GetAll(player: Player): { [string]: any }
	local settings = DataManager.Get(player, SETTINGS_KEY)
	local out: { [string]: any } = {}
	if typeof(settings) == "table" then
		for k, v in pairs(settings) do
			out[k] = v
		end
	end
	return out
end

-- Validate against the whitelist, then persist. Returns false on unknown key /
-- bad value / profile-not-loaded.
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
	local settings = DataManager.Get(player, SETTINGS_KEY)
	if typeof(settings) ~= "table" then
		settings = {}
	end
	settings[key] = value
	return DataManager.Set(player, SETTINGS_KEY, settings) == true
end

-- ── Client bridge (RemoteFunction) ──
-- Created in Init (no yield: FindFirstChild + Instance.new), so the service must
-- start before the client invokes (list "Settings" in Features).
local function getOrCreateEvents(): Instance
	local events = ReplicatedStorage:FindFirstChild("Events")
	if events then
		return events
	end
	local folder = Instance.new("Folder")
	folder.Name = "Events"
	folder.Parent = ReplicatedStorage
	return folder
end

local function onServerInvoke(player: Player, op: any, key: any, value: any): any
	if op == "get" and typeof(key) == "string" then
		return SettingsService.Get(player, key)
	elseif op == "getAll" then
		return SettingsService.GetAll(player)
	elseif op == "set" and typeof(key) == "string" then
		return SettingsService.Set(player, key, value)
	end
	return nil
end

Lifecycle.Define(SettingsService, {
	Name = "Settings",
	Needs = {},
	Init = function()
		local events = getOrCreateEvents()
		local existing = events:FindFirstChild(REMOTE_NAME)
		if existing and not existing:IsA("RemoteFunction") then
			existing:Destroy()
			existing = nil
		end
		local remote: RemoteFunction = (existing :: RemoteFunction?) or (function()
			local r = Instance.new("RemoteFunction")
			r.Name = REMOTE_NAME
			r.Parent = events
			return r
		end)()
		remote.OnServerInvoke = onServerInvoke
	end,
})

return SettingsService
