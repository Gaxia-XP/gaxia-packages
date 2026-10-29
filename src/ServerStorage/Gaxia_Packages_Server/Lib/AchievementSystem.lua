--!strict
-- ─────────────────────────────────────────────────────────────
-- AchievementSystem.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/AchievementSystem
-- Purpose : Server-side achievement registry + persistent unlock
--           tracking. Unlock IDs persist in Profile.Achievements
--           (a {[id]=true} map). Conditions are evaluated on
--           Track() and can grant rewards via EconomyService.
-- ─────────────────────────────────────────────────────────────


local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
-- Data / Economy are only called when unlocks are read or a reward is paid (call
-- time), so they are plain requires, not lifecycle Needs.
local Shared         = ReplicatedStorage.Gaxia_Packages.Shared
local Signal         = require(Shared.Signal)
local Lifecycle      = require(script.Parent.ServiceLifecycle)
local DataManager    = require(script.Parent.DataManager)
local EconomyService = require(script.Parent.EconomyService)

-- ── Types ──
export type AchievementDef = {
	id: string,
	name: string,
	description: string,
	reward: { currency: string?, amount: number? }?,
	-- Optional condition: called by Track(); return true to auto-unlock.
	condition: ((player: Player, eventType: string, ...any) -> boolean)?,
}

-- ── Module ──
local AchievementSystem = {}

-- All known achievements, keyed by id.
local Registry: { [string]: AchievementDef } = {}

-- (player, id, def) once per player when an achievement unlocks (Award / Track)
AchievementSystem.OnUnlocked = Signal.new() :: Signal.Signal<Player, string, AchievementDef>

-- ── Helpers ──

local function getProfile(player: Player): any?
	local ok, prof = pcall(function()
		return DataManager.Get(player)
	end)
	if not ok then return nil end
	return prof
end

-- Ensure Profile.Achievements exists; return nil if profile not loaded.
local function ensureUnlockTable(player: Player): { [string]: boolean }?
	local prof = getProfile(player)
	if not prof then return nil end
	local a = prof.Achievements
	if type(a) ~= "table" then
		a = {}
		-- WHY: assign through alias to keep linter happy.
		local alias: any = prof
		alias.Achievements = a
	end
	return a
end

-- Economy refuses (does not clamp) fractions and amounts above its per-call limit,
-- so a reward is floored and capped at Economy.MaxTransaction before it is paid.
-- Without this, a 10.5 or 2,000,000 reward would pay nothing although the achievement unlocks.
local function payableAmount(amount: number): number
	if amount ~= amount then return 0 end
	return math.min(math.floor(amount), EconomyService.GetMaxTransaction())
end

-- Warns once at Register when the reward will be floored or capped when paid.
local function checkRewardAmount(kind: string, id: string, amount: any): ()
	if typeof(amount) ~= "number" or amount <= 0 then return end
	local paid = payableAmount(amount)
	if paid ~= amount then
		warn(`[{kind}] "{id}" reward amount {amount} is not a whole number from 1 to Economy.MaxTransaction ({EconomyService.GetMaxTransaction()}): it pays {math.max(paid, 0)}`)
	end
end

local function payReward(player: Player, def: AchievementDef): ()
	local reward = def.reward
	if not reward then return end
	if reward.currency and reward.amount and reward.amount > 0 then
		local amount = payableAmount(reward.amount)
		if amount >= 1 then
			pcall(EconomyService.Add, player, reward.currency, amount)
		end
	end
end

-- ── Public API ──

function AchievementSystem.Register(def: AchievementDef): ()
	assert(type(def) == "table" and type(def.id) == "string", "AchievementDef requires string id")
	if def.reward then checkRewardAmount("Achievement", def.id, def.reward.amount) end
	Registry[def.id] = def
end

function AchievementSystem.Award(player: Player, id: string): boolean
	local def = Registry[id]
	if not def then return false end
	local unlocks = ensureUnlockTable(player)
	if not unlocks then return false end
	if unlocks[id] then return false end -- already unlocked — idempotent
	unlocks[id] = true
	payReward(player, def)
	AchievementSystem.OnUnlocked:Fire(player, id, def)
	return true
end

function AchievementSystem.IsUnlocked(player: Player, id: string): boolean
	local unlocks = ensureUnlockTable(player)
	if not unlocks then return false end
	return unlocks[id] == true
end

function AchievementSystem.GetUnlocked(player: Player): { string }
	local unlocks = ensureUnlockTable(player)
	local out: { string } = {}
	if not unlocks then return out end
	for id, v in pairs(unlocks) do
		if v then table.insert(out, id) end
	end
	return out
end

function AchievementSystem.Track(player: Player, eventType: string, ...: any): ()
	local unlocks = ensureUnlockTable(player)
	if not unlocks then return end
	-- Iterate registry — only consider achievements with a condition and not yet unlocked.
	-- Pack varargs so we can pass them into the condition reproducibly.
	local nArgs = select("#", ...)
	local args = table.pack(...)
	for id, def in pairs(Registry) do
		if def.condition and not unlocks[id] then
			-- WHY: pcall — a buggy condition shouldn't crash the whole track call.
			local ok, result = pcall(function()
				return def.condition(player, eventType, table.unpack(args, 1, nArgs))
			end)
			if ok and result == true then
				AchievementSystem.Award(player, id)
			end
		end
	end
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(AchievementSystem, {
	Name = "Achievement",
	Needs = {},
})

return AchievementSystem
