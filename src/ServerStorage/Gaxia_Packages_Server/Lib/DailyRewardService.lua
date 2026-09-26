--!strict
-- ─────────────────────────────────────────────────────────────
-- DailyRewardService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/DailyRewardService
-- Purpose : Login-streak daily rewards — the cheapest, highest-impact retention
--           hook. Defines a reward ladder; Claim() is gated to once per 24h,
--           advances the streak when claimed within the 24–48h window and resets
--           it past 48h, then hands back the ladder reward (cycling or capped).
--           State (lastClaim/streak) is os.time-based in the profile so it can't
--           be farmed by rejoining and survives sessions. Reward payload is
--           arbitrary — the game grants it from OnClaim, keeping currency/item
--           coupling out of the timer logic.
--
-- Access  : Gaxia.DailyReward  (server)
--   Gaxia.DailyReward.DefineLadder({ {Coins=100}, {Coins=250}, {Gems=5} })
--   local res = Gaxia.DailyReward.Claim(player)   -- {day, streak, reward} or nil
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Shared      = ReplicatedStorage.Gaxia_Packages.Shared
local Signal      = require(Shared.Signal)
local Lifecycle   = require(script.Parent.ServiceLifecycle)
local Config      = require(script.Parent.Parent.Config)
local EConfig     = require(script.Parent.EffectiveConfig)
local DataManager = require(script.Parent.DataManager)

local DAILY_KEY : string = "Daily"
local DAY : number = 86400  -- ultimate fallback if Config absent

-- Effective tunables: runtime Flag override <- Config.Daily default <- fallback.
local function daySeconds(): number
	return EConfig.Get("Daily.DaySeconds", Config.Daily.DaySeconds or DAY)
end
local function resetWindow(): number
	return EConfig.Get("Daily.ResetWindow", Config.Daily.ResetWindow or DAY * 2)
end

export type ClaimResult = { day: number, streak: number, reward: any }

local DailyRewardService = {}

-- (player, result) after a successful Claim; the game grants result.reward
DailyRewardService.OnClaim = Signal.new() :: Signal.Signal<Player, ClaimResult>

local ladder: { any } = {}
local cycle : boolean = true

-- ── PURE: claim eligibility + next streak value (unit-testable) ──
-- canClaim = first claim or ≥ a day since last. newStreak: continue if claimed
-- inside the 24–48h window, else reset to 1.
function DailyRewardService.ComputeClaim(lastClaim: number, now: number, currentStreak: number, dayLen: number, resetWindow: number?): (boolean, number)
	local reset = resetWindow or dayLen * 2 -- back-compat: default reset = 2 days
	if lastClaim <= 0 then
		return true, 1
	end
	local elapsed = now - lastClaim
	if elapsed < dayLen then
		return false, currentStreak
	end
	if elapsed < reset then
		return true, currentStreak + 1
	end
	return true, 1
end

-- ── Ladder ──

function DailyRewardService.DefineLadder(rewards: { any }, opts: { Cycle: boolean? }?): ()
	ladder = rewards
	if opts and opts.Cycle ~= nil then
		cycle = opts.Cycle
	end
end

-- Map a streak number to a ladder day index (1-based).
function DailyRewardService.LadderDay(streak: number): number
	if #ladder == 0 then
		return 0
	end
	if cycle then
		return ((streak - 1) % #ladder) + 1
	end
	return math.min(streak, #ladder)
end

-- ── State ──

local function loadState(player: Player): { lastClaim: number, streak: number }
	local s = DataManager.Get(player, DAILY_KEY)
	if typeof(s) == "table" then
		return { lastClaim = tonumber(s.lastClaim) or 0, streak = tonumber(s.streak) or 0 }
	end
	return { lastClaim = 0, streak = 0 }
end

local function saveState(player: Player, lastClaim: number, streak: number): ()
	DataManager.Set(player, DAILY_KEY, { lastClaim = lastClaim, streak = streak })
end

function DailyRewardService.GetStreak(player: Player): number
	return loadState(player).streak
end

function DailyRewardService.CanClaim(player: Player): boolean
	local s = loadState(player)
	local can = select(1, DailyRewardService.ComputeClaim(s.lastClaim, os.time(), s.streak, daySeconds(), resetWindow()))
	return can
end

-- Seconds until the next claim opens (0 if claimable now).
function DailyRewardService.GetTimeUntilNext(player: Player): number
	local s = loadState(player)
	if s.lastClaim <= 0 then
		return 0
	end
	return math.max(0, (s.lastClaim + daySeconds()) - os.time())
end

-- ── Claim ──

function DailyRewardService.Claim(player: Player): (ClaimResult?, string?)
	local s = loadState(player)
	local now = os.time()
	local can, newStreak = DailyRewardService.ComputeClaim(s.lastClaim, now, s.streak, daySeconds(), resetWindow())
	if not can then
		return nil, "already claimed today"
	end
	local day = DailyRewardService.LadderDay(newStreak)
	local reward = ladder[day]
	saveState(player, now, newStreak)
	local result: ClaimResult = { day = day, streak = newStreak, reward = reward }
	DailyRewardService.OnClaim:Fire(player, result)
	return result, nil
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(DailyRewardService, {
	Name = "DailyReward",
	Needs = {},
})

return DailyRewardService
