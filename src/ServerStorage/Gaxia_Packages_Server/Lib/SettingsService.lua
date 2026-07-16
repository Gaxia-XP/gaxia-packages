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
-- Access  : Gaxia.Settings  (server) — touch it at boot to activate the bridge:
--   Gaxia.Settings.RegisterSetting("Quality", function(v) return typeof(v)=="number" end)
--   Gaxia.Settings.Set(player, "Music", false)
-- Client  : RemoteFunction ReplicatedStorage.Events.Gaxia_Settings
--   remote:InvokeServer("get"|"getAll"|"set", key, value)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

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

-- Lazy DataManager (require the loader at CALL time, not module load — module
-- load runs under the no-yield loader metamethod; calls run in normal context).
local GaxiaServer: any = nil
local function getData(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server"):WaitForChild("init")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer.Data
end

-- ── Public API ──

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

-- ── Client bridge (RemoteFunction) ──
-- Created at module load (no yield: FindFirstChild + Instance.new). The game must
-- touch Gaxia.Settings server-side at boot so this runs before the client invokes.
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

remote.OnServerInvoke = function(player: Player, op: any, key: any, value: any): any
	if op == "get" and typeof(key) == "string" then
		return SettingsService.Get(player, key)
	elseif op == "getAll" then
		return SettingsService.GetAll(player)
	elseif op == "set" and typeof(key) == "string" then
		return SettingsService.Set(player, key, value)
	end
	return nil
end

return SettingsService
