--!strict
-- ─────────────────────────────────────────────────────────────
-- CooldownService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/CooldownService
-- Purpose : Server-authoritative cooldown / debounce primitive. One tested
--           place for "can this action run yet?" so abilities, daily rewards,
--           shop buys, quest claims, raids and remote handlers stop re-rolling
--           their own os.clock() debounce maps. The atomic Consume() both gates
--           AND arms in a single call — the anti-spam-claim primitive.
--
-- Access  : Gaxia.Cooldown  (server)
--   if Gaxia.Cooldown.ConsumePlayer(player, "Claim", 86400) then grantDaily() end
--   Gaxia.Cooldown.GetRemaining("GlobalBoss") -- cross-player cooldown (no player key)
-- ─────────────────────────────────────────────────────────────
local Players = game:GetService("Players")

-- ── Dependencies ──
local Lifecycle = require(script.Parent.ServiceLifecycle)
local Config    = require(script.Parent.Parent.Config)
local EConfig   = require(script.Parent.EffectiveConfig)

-- ── Constants ──
local SWEEP_INTERVAL  : number = 60     -- ultimate fallback if Config absent
local PLAYER_KEY_PREFIX : string = "P:" -- namespace for per-player keys

-- Effective sweep interval (Config default <- runtime override), read every sweep.
local function sweepInterval(): number
	return EConfig.Get("Cooldown.SweepInterval", Config.Cooldown.SweepInterval or SWEEP_INTERVAL)
end

local CooldownService = {}

-- key → os.clock() expiry timestamp. Cross-player cooldowns use a bare key;
-- per-player cooldowns use Key(player, action) so they cool down independently.
local cooldowns: { [string]: number } = {}

-- Drop the entry if expired; return the live expiry timestamp or nil.
local function liveExpiry(key: string): number?
	local exp = cooldowns[key]
	if exp == nil then
		return nil
	end
	if os.clock() >= exp then
		cooldowns[key] = nil
		return nil
	end
	return exp
end

-- ── Public API ──

-- Set / refresh a cooldown on `key` for `duration` seconds. (Gameplay API — the
-- service's lifecycle hooks are in the Define spec at the bottom.)
function CooldownService.Start(key: string, duration: number): ()
	if type(key) ~= "string" or type(duration) ~= "number" or duration <= 0 then
		return
	end
	cooldowns[key] = os.clock() + duration
end

-- True while the cooldown is active.
function CooldownService.IsActive(key: string): boolean
	return liveExpiry(key) ~= nil
end

-- Seconds remaining (0 when not active).
function CooldownService.GetRemaining(key: string): number
	local exp = liveExpiry(key)
	if not exp then
		return 0
	end
	return math.max(0, exp - os.clock())
end

-- ATOMIC check-and-set: if `key` is NOT on cooldown, start it for `duration`
-- and return true (action allowed); otherwise return false (still cooling down).
-- A single call both gates and arms — no TOCTOU window for spam exploits.
function CooldownService.Consume(key: string, duration: number): boolean
	if type(key) ~= "string" or type(duration) ~= "number" or duration <= 0 then
		return false
	end
	if liveExpiry(key) ~= nil then
		return false
	end
	cooldowns[key] = os.clock() + duration
	return true
end

-- Clear a cooldown immediately.
function CooldownService.Clear(key: string): ()
	cooldowns[key] = nil
end

-- ── Player-namespaced helpers ──

-- Build a per-player key so the same `action` cools down independently per player.
function CooldownService.Key(player: Player, action: string): string
	return `{PLAYER_KEY_PREFIX}{player.UserId}:{action}`
end

function CooldownService.ConsumePlayer(player: Player, action: string, duration: number): boolean
	return CooldownService.Consume(CooldownService.Key(player, action), duration)
end

function CooldownService.IsPlayerActive(player: Player, action: string): boolean
	return CooldownService.IsActive(CooldownService.Key(player, action))
end

function CooldownService.GetPlayerRemaining(player: Player, action: string): number
	return CooldownService.GetRemaining(CooldownService.Key(player, action))
end

-- ── Lifecycle: cleanup ──

-- Drop a leaving player's per-player cooldowns so the map doesn't leak.
local function clearPlayer(player: Player): ()
	local prefix = `{PLAYER_KEY_PREFIX}{player.UserId}:`
	local n = #prefix
	for key in pairs(cooldowns) do
		if string.sub(key, 1, n) == prefix then
			cooldowns[key] = nil
		end
	end
end

-- Periodic sweep so never-revisited expired keys don't accumulate. Runs forever.
local function sweepLoop(): ()
	while true do
		task.wait(sweepInterval())
		local t = os.clock()
		for key, exp in pairs(cooldowns) do
			if t >= exp then
				cooldowns[key] = nil
			end
		end
	end
end

-- The lifecycle hooks live in this spec, not on the module: CooldownService.Start
-- is the gameplay API above.
Lifecycle.Define(CooldownService, {
	Name = "Cooldown",
	Needs = {},
	Init = function()
		Players.PlayerRemoving:Connect(clearPlayer)
	end,
	Start = sweepLoop,
})

return CooldownService
