--!strict
-- ─────────────────────────────────────────────────────────────
-- QuestSystem.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/QuestSystem
-- Purpose : Server-side quest registry + per-player progress.
--           Definitions are registered at load; progress persists
--           in Profile.Quests via DataManager. Rewards are paid
--           through EconomyService / ItemService on completion.
-- ─────────────────────────────────────────────────────────────


local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

-- ── Types ──
export type GoalType = "kill" | "collect" | "reach" | "time_played"
export type Goal = { type: GoalType, target: string, count: number }
export type QuestDef = {
	id: string,
	name: string,
	description: string,
	goals: { Goal },
	reward: { currency: string?, amount: number?, items: { [string]: number }? },
}

-- ── Direct-path lazy requires (avoid GaxiaServer __index recursion) ──
local _dataMgr: any = nil
local function getDataManager(): any
	if _dataMgr ~= nil then return _dataMgr end
	local lib = (script.Parent :: any)
	local mod = lib:FindFirstChild("DataManager")
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(require, mod) ; if ok then _dataMgr = m end
	end
	return _dataMgr
end

local _econ: any = nil
local function getEconomy(): any
	if _econ ~= nil then return _econ end
	local lib = (script.Parent :: any)
	local mod = lib:FindFirstChild("EconomyService")
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(require, mod) ; if ok then _econ = m end
	end
	return _econ
end

local _items: any = nil
local function getItems(): any
	if _items ~= nil then return _items end
	local lib = (script.Parent :: any)
	local mod = lib:FindFirstChild("ItemService")
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(require, mod) ; if ok then _items = m end
	end
	return _items
end

local _pet: any = nil
local function getPet(): any
	if _pet ~= nil then return _pet end
	local lib = (script.Parent :: any)
	local mod = lib:FindFirstChild("PetService")
	if mod and mod:IsA("ModuleScript") then
		local ok, m = pcall(require, mod) ; if ok then _pet = m end
	end
	return _pet
end

-- The equipped-pet multiplier boosts ONLY this currency (matches PetService.EGG_CURRENCY).
local COIN_CURRENCY: string = "Coins"

-- ── Module ──
local QuestSystem = {}

-- Registry of all known quests (shared across the server).
local Registry: { [string]: QuestDef } = {}

-- Signals — orchestrator-style fan-out so other systems can react.
QuestSystem.OnQuestStart    = Signal.new()
QuestSystem.OnGoalProgress  = Signal.new()  -- (player, questId, goalKey, current, target)
QuestSystem.OnQuestComplete = Signal.new()  -- (player, questId, reward)

-- ── Helpers ──

-- Fetch the per-player profile if it exists; nil if not yet loaded.
local function getProfile(player: Player): any?
	local dm = getDataManager()
	if not dm then return nil end
	-- DataManager.Get returns nil while profile is still loading; that's fine.
	local ok, prof = pcall(dm.Get, player)
	if not ok then return nil end
	return prof
end

-- Ensure Profile.Quests table exists and return it (or nil if no profile).
local function ensureQuestsTable(player: Player): { [string]: any }?
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

-- Pay out reward via Economy + Item services (best-effort; missing services skipped).
local function grantReward(player: Player, def: QuestDef): ()
	local reward = def.reward
	if not reward then return end
	if reward.currency and reward.amount and reward.amount > 0 then
		local econ = getEconomy()
		if econ and econ.Add then
			local amount = reward.amount
			-- Coin rewards get the equipped-pet multiplier; other currencies (Gems, …) don't.
			if reward.currency == COIN_CURRENCY then
				local pet = getPet()
				if pet and pet.GetCoinMultiplier then
					local ok, mult = pcall(pet.GetCoinMultiplier, player)
					if ok and typeof(mult) == "number" and mult == mult then
						amount = math.floor(amount * mult)
					end
				end
			end
			pcall(econ.Add, player, reward.currency, amount)
		end
	end
	if reward.items then
		local items = getItems()
		if items and items.Give then
			for itemId, qty in pairs(reward.items) do
				pcall(items.Give, player, itemId, qty)
			end
		end
	end
end

-- ── Public API ──

function QuestSystem.Register(def: QuestDef): ()
	assert(type(def) == "table" and type(def.id) == "string", "QuestDef requires string id")
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

	for questId, state in pairs(quests) do
		local def = Registry[questId]
		if def then
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
					grantReward(player, def)
					QuestSystem.OnQuestComplete:Fire(player, questId, def.reward)
				end
			end
		end
	end
end

function QuestSystem.GetActive(player: Player): { [string]: { progress: {[string]: number}, started: number } }
	local quests = ensureQuestsTable(player)
	if not quests then return {} end
	-- Shallow copy so callers can't mutate live state.
	local out: { [string]: any } = {}
	for id, state in pairs(quests) do
		local pcopy: { [string]: number } = {}
		for k, v in pairs(state.progress) do pcopy[k] = v end
		out[id] = { progress = pcopy, started = state.started }
	end
	return out
end

function QuestSystem.IsComplete(player: Player, questId: string): boolean
	-- A quest is "complete" once it has been removed from active list AND the
	-- definition exists. We approximate by: not active and progress empty.
	local quests = ensureQuestsTable(player)
	if not quests then return false end
	return quests[questId] == nil and Registry[questId] ~= nil
end

function QuestSystem.Abandon(player: Player, questId: string): ()
	local quests = ensureQuestsTable(player)
	if not quests then return end
	quests[questId] = nil
end

return QuestSystem
