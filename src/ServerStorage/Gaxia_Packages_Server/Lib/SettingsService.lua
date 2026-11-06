--!strict
-- ─────────────────────────────────────────────────────────────
-- SettingsService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/SettingsService
-- Purpose : Server-authoritative bridge to Profile.Data.Settings with a
--           key + type whitelist. Client requests use the registered Net
--           RPCs below; this service never owns a raw RemoteFunction.
--
-- Access  : Gaxia.Settings  (server) — list "Settings" in Features (or touch it at
--           boot) to register the client RPCs before a client invokes them:
--   Gaxia.Settings.RegisterSetting("Quality", function(v) return typeof(v) == "number" end)
--   Gaxia.Settings.Set(player, "Music", false)
-- Client  : Shared.Settings (client)
--   Settings.Get("Music") / Settings.GetAll() / Settings.Set("Music", false)
--
-- Transport contract:
--   Settings.Read { key = string? }  -- omitted key returns all settings
--   Settings.Set  { key = string, value = any }
--           Net applies its per-RPC rate / schema / concurrency gates, then a
--           per-player token bucket shared by both RPCs (REMOTE_RATE /
--           REMOTE_BURST) rejects calls over budget. Rejection warnings are
--           throttled.
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

-- ── Dependencies ──
local Net         = require(ReplicatedStorage.Gaxia_Packages.Shared.NetService)
local Lifecycle   = require(script.Parent.ServiceLifecycle)
local DataManager = require(script.Parent.DataManager)

local SETTINGS_KEY : string = "Settings"        -- Profile.Data.Settings
local READ_RPC     : string = "Settings.Read"
local SET_RPC      : string = "Settings.Set"
local MAX_SETTING_KEY_BYTES: number = 64
local REMOTE_RATE  : number = 5                -- client calls refilled per second, per player
local REMOTE_BURST : number = 10               -- bucket capacity (calls in a burst)
local WARN_INTERVAL: number = 10               -- seconds between two warnings of one kind
local MAX_KEY_SHOWN: number = 40               -- chars of a rejected key shown in Output

local SettingsService = {}

-- key → validator(value) -> boolean. Defaults mirror DataManager.DEFAULT_PROFILE.Settings.
local function isBool(value: any): boolean
	return typeof(value) == "boolean"
end

local whitelist: { [string]: (value: any) -> boolean } = {
	Music = isBool,
	SFX = isBool,
}

-- Warnings a client can trigger are throttled per kind. The kinds are bounded
-- ("unknown", "invalid:<whitelisted key>", "rate"), so a client sending endless
-- different keys cannot grow this table or flood Output.
local lastWarn: { [string]: number } = {}
local function throttledWarn(kind: string, message: string): ()
	local now = os.clock()
	local last = lastWarn[kind]
	if last and now - last < WARN_INTERVAL then
		return
	end
	lastWarn[kind] = now
	warn(message)
end

-- ── Public server API ──

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
		local shown = string.sub(tostring(key), 1, MAX_KEY_SHOWN)
		throttledWarn("unknown", `[SettingsService] rejected unknown setting '{shown}' (repeats are not shown for {WARN_INTERVAL} s)`)
		return false
	end
	if not check(value) then
		throttledWarn(`invalid:{key}`, `[SettingsService] rejected invalid value for '{key}' (repeats are not shown for {WARN_INTERVAL} s)`)
		return false
	end
	local settings = DataManager.Get(player, SETTINGS_KEY)
	if typeof(settings) ~= "table" then
		settings = {}
	end
	settings[key] = value
	return DataManager.Set(player, SETTINGS_KEY, settings) == true
end

-- ── Registered Net RPCs (registered in Init) ──

-- Per-player token bucket shared by both RPCs. Weak keys + PlayerRemoving cleanup.
type Bucket = { tokens: number, lastClock: number }
local buckets: { [Player]: Bucket } = setmetatable({}, { __mode = "k" }) :: any

local function consume(player: Player): boolean
	local now = os.clock()
	local b = buckets[player]
	if not b then
		b = { tokens = REMOTE_BURST, lastClock = now }
		buckets[player] = b
	end
	b.tokens = math.min(REMOTE_BURST, b.tokens + (now - b.lastClock) * REMOTE_RATE)
	b.lastClock = now
	if b.tokens >= 1 then
		b.tokens -= 1
		return true
	end
	return false
end

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

-- The shared per-player budget; over it the request is rejected by Net.
local function withinBudget(context: any, _payload: any): boolean
	local player = context.player
	if not consume(player) then
		throttledWarn("rate", `[SettingsService] {player.Name} is calling the Settings RPCs too fast; extra calls are rejected`)
		return false
	end
	return true
end

-- Net supplies this Player from Roblox, never from the payload. Still require
-- a currently connected player for a state-changing request so a request that
-- races PlayerRemoving cannot mutate detached profile state.
local function maySetOwnSettings(context: any, payload: any): boolean
	local player = context.player
	return typeof(player) == "Instance"
		and player:IsA("Player")
		and player.Parent == Players
		and withinBudget(context, payload)
end

local function registerRpcs(): ()
	Net.Server.RegisterFunction(READ_RPC, {
		schema = isReadPayload,
		validate = withinBudget,
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
end

Lifecycle.Define(SettingsService, {
	Name = "Settings",
	Needs = {},
	Init = function()
		registerRpcs()
		Players.PlayerRemoving:Connect(function(player: Player)
			buckets[player] = nil
		end)
	end,
})

return SettingsService
