--!strict
-- ─────────────────────────────────────────────────────────────
-- QuestSystem.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/QuestSystem
-- Purpose : Server-side quest registry + per-player progress.
--           Definitions are registered at load; progress persists
--           in Profile.Quests via DataManager. Rewards are paid
--           through EconomyService / ItemService on completion.
--           Finished quests are counted in Profile.QuestsCompleted
--           ({ [questId] = times completed }), so they survive rejoins.
-- ─────────────────────────────────────────────────────────────


local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
-- Data / Economy / Item are only called when a player's quests are read or a
-- reward is paid (call time), so they are plain requires, not lifecycle Needs. Pet is
-- optional (its package may not be installed): its coin multiplier is looked up
-- with Lifecycle.Find and stays best-effort (see grantReward).
local Shared         = ReplicatedStorage.Gaxia_Packages.Shared
local Signal         = require(Shared.Signal)
local Lifecycle      = require(script.Parent.ServiceLifecycle)
local DataManager    = require(script.Parent.DataManager)
local EconomyService = require(script.Parent.EconomyService)
local ItemService    = require(script.Parent.ItemService)

-- ── Types ──
export type GoalType = "kill" | "collect" | "reach" | "time_played"
export type Goal = { type: GoalType, target: string, count: number }
export type QuestReward = { currency: string?, amount: number?, items: { [string]: number }? }
export type QuestDef = {
	id: string,
	name: string,
	description: string,
	goals: { Goal },
	reward: QuestReward,
}
-- One active quest's live state (GetActive returns copies).
export type QuestProgress = { progress: { [string]: number }, started: number }

-- The equipped-pet multiplier boosts ONLY this currency (matches PetService.EGG_CURRENCY).
local COIN_CURRENCY: string = "Coins"

-- Saved-data key of the finished-quest record: { [questId]: number } (times completed).
local COMPLETED_KEY: string = "QuestsCompleted"

-- The part of the Pet service a reward uses (Pet is a soft dependency).
type PetApi = { GetCoinMultiplier: (player: Player) -> number }

-- ── Module ──
local QuestSystem = {}

-- Registry of all known quests (shared across the server).
local Registry: { [string]: QuestDef } = {}

-- Signals — orchestrator-style fan-out so other systems can react.
-- (player, questId) after Start adds the quest to the player's active list
QuestSystem.OnQuestStart    = Signal.new() :: Signal.Signal<Player, string>
-- (player, questId, goalKey, current, target) each time Track advances a matching goal
QuestSystem.OnGoalProgress  = Signal.new() :: Signal.Signal<Player, string, string, number, number>
-- (player, questId, reward, paid) after the quest completes and its reward was paid.
-- reward is the quest's reward definition; paid is the currency amount actually added
-- (after the pet coin bonus and the balance cap; 0 when there is no currency reward or the
-- payment failed). Handlers with three parameters keep working.
QuestSystem.OnQuestComplete = Signal.new() :: Signal.Signal<Player, string, QuestReward, number>

-- ── Helpers ──

-- Fetch the per-player profile if it exists; nil if not yet loaded.
local function getProfile(player: Player): any?
	-- DataManager.Get returns nil while profile is still loading; that's fine.
	local ok, prof = pcall(function()
		return DataManager.Get(player)
	end)
	if not ok then return nil end
	return prof
end

-- Ensure Profile.Quests table exists and return it (or nil if no profile).
local function ensureQuestsTable(player: Player): { [string]: QuestProgress }?
	local prof = getProfile(player)
	if not prof then return nil end
	local q = prof.Quests
	if type(q) ~= "table" then
		q = {}
		-- WHY: avoid `(prof :: any).Quests = ...` on a line by itself (lint rule).
		local alias: any = prof
		alias.Quests = q
	end
	return q
end

-- Total required count for a goal target inside a quest.
local function targetCountFor(def: QuestDef, target: string): number
	local sum = 0
	for _, g in ipairs(def.goals) do
		if g.target == target then sum += g.count end
	end
	return sum
end

-- Return true when every goal's progress meets/exceeds its required count.
local function isQuestSatisfied(def: QuestDef, progress: { [string]: number }): boolean
	for _, g in ipairs(def.goals) do
		local have = progress[g.target] or 0
		if have < g.count then return false end
	end
	return true
end

-- Economy refuses (does not clamp) fractions and amounts above its per-call limit,
-- so a reward is floored and capped at Economy.MaxTransaction before it is paid.
-- Without this, a 10.5 or 2,000,000 reward would pay nothing after the quest is gone.
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

-- The saved finished-quest record (nil while the profile is not loaded).
local function getCompleted(player: Player): { [string]: number }?
	local prof = getProfile(player)
	if not prof then return nil end
	local done = prof[COMPLETED_KEY]
	if type(done) ~= "table" then return {} end
	return done
end

-- Count one more completion of questId in the player's saved data.
local function recordCompleted(player: Player, questId: string): ()
	local done = getCompleted(player)
	if not done then return end
	done[questId] = (tonumber(done[questId]) or 0) + 1
	DataManager.Set(player, COMPLETED_KEY, done)
end

-- Pay out reward via Economy + Item services (best-effort: a failing grant is skipped).
-- Returns the currency amount actually added (0 when none was paid).
local function grantReward(player: Player, def: QuestDef): number
	local paid = 0
	local reward = def.reward
	if not reward then return paid end
	if reward.currency and reward.amount and reward.amount > 0 then
		local amount = reward.amount
		-- Coin rewards get the equipped-pet multiplier; other currencies (Gems, …) don't.
		-- Best-effort: if Pet errors or returns a non-number / NaN, the reward is ×1.0.
		local Pet: PetApi? = if reward.currency == COIN_CURRENCY then Lifecycle.Find("Pet") else nil
		if Pet then
			local ok, mult = pcall(Pet.GetCoinMultiplier, player)
			if ok and typeof(mult) == "number" and mult == mult then
				amount = amount * mult
			end
		end
		amount = payableAmount(amount)
		if amount >= 1 then
			local currency = reward.currency
			local before = EconomyService.Get(player, currency)
			local ok, added = pcall(EconomyService.Add, player, currency, amount)
			if ok and added == true then
				paid = math.max(0, EconomyService.Get(player, currency) - before)
			end
		end
	end
	if reward.items then
		for itemId, qty in pairs(reward.items) do
			pcall(ItemService.Give, player, itemId, qty)
		end
	end
	return paid
end

-- ── Public API ──

function QuestSystem.Register(def: QuestDef): ()
	assert(type(def) == "table" and type(def.id) == "string", "QuestDef requires string id")
	if def.reward then checkRewardAmount("Quest", def.id, def.reward.amount) end
	Registry[def.id] = def
end

function QuestSystem.Start(player: Player, questId: string): boolean
	local def = Registry[questId]
	if not def then return false end
	local quests = ensureQuestsTable(player)
	if not quests then return false end
	if quests[questId] then return false end -- already active
	quests[questId] = {
		progress = {},
		started = os.time(),
	}
	QuestSystem.OnQuestStart:Fire(player, questId)
	return true
end

function QuestSystem.Track(player: Player, eventType: GoalType, target: string, count: number?): ()
	local quests = ensureQuestsTable(player)
	if not quests then return end -- profile not loaded yet — silent no-op per spec
	local inc = count or 1

	-- Iterate a snapshot: OnQuestComplete handlers run inside this loop and may Start,
	-- Abandon or restart quests. Changing the live table under pairs() could skip or
	-- repeat quests (or error "invalid key to 'next'"). A quest started during this
	-- Track gets no progress from this event.
	local ids: { string } = {}
	for questId in pairs(quests) do
		table.insert(ids, questId)
	end
	local snapshot: { [string]: QuestProgress } = {}
	for _, questId in ipairs(ids) do
		snapshot[questId] = quests[questId]
	end

	for _, questId in ipairs(ids) do
		local def = Registry[questId]
		local state = quests[questId]
		-- Skip quests a handler abandoned or restarted since the snapshot was taken.
		if def and state ~= nil and state == snapshot[questId] then
			-- Only quests with a matching (type,target) goal accumulate progress.
			local matches = false
			for _, g in ipairs(def.goals) do
				if g.type == eventType and g.target == target then
					matches = true
					break
				end
			end
			if matches then
				local progress = state.progress
				local current = (progress[target] or 0) + inc
				progress[target] = current
				local needed = targetCountFor(def, target)
				QuestSystem.OnGoalProgress:Fire(player, questId, target, current, needed)

				if isQuestSatisfied(def, progress) then
					-- Remove BEFORE granting reward so completion signal sees clean state.
					quests[questId] = nil
					recordCompleted(player, questId)
					local paid = grantReward(player, def)
					QuestSystem.OnQuestComplete:Fire(player, questId, def.reward, paid)
				end
			end
		end
	end
end

function QuestSystem.GetActive(player: Player): { [string]: QuestProgress }
	local quests = ensureQuestsTable(player)
	if not quests then return {} end
	-- Shallow copy so callers can't mutate live state.
	local out: { [string]: QuestProgress } = {}
	for id, state in pairs(quests) do
		local pcopy: { [string]: number } = {}
		for k, v in pairs(state.progress) do pcopy[k] = v end
		out[id] = { progress = pcopy, started = state.started }
	end
	return out
end

-- True when the player finished this quest at least once (saved, survives rejoins)
-- and it is not active right now. False for a quest that was never finished, and
-- while the player's data is not loaded.
function QuestSystem.IsComplete(player: Player, questId: string): boolean
	local quests = ensureQuestsTable(player)
	if not quests then return false end
	return quests[questId] == nil and QuestSystem.GetCompletedCount(player, questId) > 0
end

-- How many times the player finished this quest (saved in QuestsCompleted; 0 while
-- the player's data is not loaded).
function QuestSystem.GetCompletedCount(player: Player, questId: string): number
	local done = getCompleted(player)
	if not done then return 0 end
	return tonumber(done[questId]) or 0
end

function QuestSystem.Abandon(player: Player, questId: string): ()
	local quests = ensureQuestsTable(player)
	if not quests then return end
	quests[questId] = nil
end

-- Pure API: nothing to set up. QuestSystem.Start above is the gameplay API (start a
-- quest for a player); this spec has no lifecycle hooks.
Lifecycle.Define(QuestSystem, {
	Name = "Quest",
	Needs = {},
})

return QuestSystem
