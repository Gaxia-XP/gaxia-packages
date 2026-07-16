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
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

-- ── Types ──
export type AchievementDef = {
	id: string,
	name: string,
	description: string,
	reward: { currency: string?, amount: number? }?,
	-- Optional condition: called by Track(); return true to auto-unlock.
	condition: ((player: Player, eventType: string, ...any) -> boolean)?,
}

-- ── Direct-path lazy requires ──
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

-- ── Module ──
local AchievementSystem = {}

-- All known achievements, keyed by id.
local Registry: { [string]: AchievementDef } = {}

AchievementSystem.OnUnlocked = Signal.new()  -- (player, id, def)

-- ── Helpers ──

local function getProfile(player: Player): any?
	local dm = getDataManager()
	if not dm then return nil end
	local ok, prof = pcall(dm.Get, player)
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

local function payReward(player: Player, def: AchievementDef): ()
	local reward = def.reward
	if not reward then return end
	if reward.currency and reward.amount and reward.amount > 0 then
		local econ = getEconomy()
		if econ and econ.Add then
			pcall(econ.Add, player, reward.currency, reward.amount)
		end
	end
end

-- ── Public API ──

function AchievementSystem.Register(def: AchievementDef): ()
	assert(type(def) == "table" and type(def.id) == "string", "AchievementDef requires string id")
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

return AchievementSystem
