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
--           Rate-limited per player (token bucket, REMOTE_RATE / REMOTE_BURST):
--           over budget the call returns nil. Rejection warnings are throttled.
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

-- ── Dependencies ──
local Lifecycle   = require(script.Parent.ServiceLifecycle)
local DataManager = require(script.Parent.DataManager)

local SETTINGS_KEY : string = "Settings"        -- Profile.Data.Settings
local REMOTE_NAME  : string = "Gaxia_Settings"
local REMOTE_RATE  : number = 5                -- client calls refilled per second, per player
local REMOTE_BURST : number = 10               -- bucket capacity (calls in a burst)
local WARN_INTERVAL: number = 10               -- seconds between two warnings of one kind
local MAX_KEY_SHOWN: number = 40               -- chars of a rejected key shown in Output

local SettingsService = {}

-- key → validator(value) -> boolean. Defaults mirror DataManager.DEFAULT_PROFILE.Settings.
local function isBool(v: any): boolean
	return typeof(v) == "boolean"
end
local whitelist: { [string]: (value: any) -> boolean } = {
	Music = isBool,
	SFX   = isBool,
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

-- Per-player token bucket for the remote. Weak keys + PlayerRemoving cleanup.
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

local function onServerInvoke(player: Player, op: any, key: any, value: any): any
	if not consume(player) then
		throttledWarn("rate", `[SettingsService] {player.Name} is calling {REMOTE_NAME} too fast; extra calls return nil`)
		return nil
	end
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
		Players.PlayerRemoving:Connect(function(player: Player)
			buckets[player] = nil
		end)
	end,
})

return SettingsService
