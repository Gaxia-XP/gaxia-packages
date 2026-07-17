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
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal = SharedPkg.Signal

local GaxiaServer: any = nil
local function server(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer
end
local function getData(): any
	return server().Data
end

local DAILY_KEY : string = "Daily"
local DAY : number = 86400  -- ultimate fallback if Config absent

local function dailyGet(key: string, fallback: any): any
	local s = server()
	return s.EConfig.Get(`Daily.{key}`, (s.Config.Daily or {})[key] or fallback)
end

export type ClaimResult = { day: number, streak: number, reward: any }

local DailyRewardService = {}

DailyRewardService.OnClaim = Signal.new() -- (player, ClaimResult)

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
	local s = getData().Get(player, DAILY_KEY)
	if typeof(s) == "table" then
		return { lastClaim = tonumber(s.lastClaim) or 0, streak = tonumber(s.streak) or 0 }
	end
	return { lastClaim = 0, streak = 0 }
end

local function saveState(player: Player, lastClaim: number, streak: number): ()
	getData().Set(player, DAILY_KEY, { lastClaim = lastClaim, streak = streak })
end

function DailyRewardService.GetStreak(player: Player): number
	return loadState(player).streak
end

function DailyRewardService.CanClaim(player: Player): boolean
	local s = loadState(player)
	local can = select(1, DailyRewardService.ComputeClaim(s.lastClaim, os.time(), s.streak, dailyGet("DaySeconds", DAY), dailyGet("ResetWindow", DAY * 2)))
	return can
end

-- Seconds until the next claim opens (0 if claimable now).
function DailyRewardService.GetTimeUntilNext(player: Player): number
	local s = loadState(player)
	if s.lastClaim <= 0 then
		return 0
	end
	return math.max(0, (s.lastClaim + dailyGet("DaySeconds", DAY)) - os.time())
end

-- ── Claim ──

function DailyRewardService.Claim(player: Player): (ClaimResult?, string?)
	local s = loadState(player)
	local now = os.time()
	local can, newStreak = DailyRewardService.ComputeClaim(s.lastClaim, now, s.streak, dailyGet("DaySeconds", DAY), dailyGet("ResetWindow", DAY * 2))
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

return DailyRewardService
