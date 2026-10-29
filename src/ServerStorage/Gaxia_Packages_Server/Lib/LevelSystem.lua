--!strict
-- ─────────────────────────────────────────────────────────────
-- LevelSystem.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/LevelSystem
-- Purpose : Server-side XP/level progression. Persists in
--           Profile.Level / Profile.Experience via DataManager.
--           Curve is configurable; AddXP handles multi-level-up.
-- ─────────────────────────────────────────────────────────────


local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
-- DataManager / Config / EConfig are only used when a player's level is read or
-- changed (call time), so there are no lifecycle Needs.
local Shared      = ReplicatedStorage.Gaxia_Packages.Shared
local Signal      = require(Shared.Signal)
local Lifecycle   = require(script.Parent.ServiceLifecycle)
local Config      = require(script.Parent.Parent.Config)
local EConfig     = require(script.Parent.EffectiveConfig)
local DataManager = require(script.Parent.DataManager)

type Profile = DataManager.PlayerData

-- Config default <- runtime Flag override via Gaxia.EConfig. Read per-call so an
-- admin can `/flag set Level.CurveExponent N` to retune leveling pace live.
local function levelCfg(key: string, default: number): number
	local levelConfig = Config.Level :: { [string]: any }
	return EConfig.Get("Level." .. key, levelConfig[key] or default)
end

-- ── Module ──
local LevelSystem = {}

-- Default curve: classic RPG-ish polynomial growth. Base coefficient + exponent
-- come from Config.Level (CurveBase / CurveExponent), runtime-overridable.
local DEFAULT_CURVE: (level: number) -> number = function(level: number): number
	return math.floor(levelCfg("CurveBase", 100) * (level ^ levelCfg("CurveExponent", 1.5)))
end

local curveFn: (level: number) -> number = DEFAULT_CURVE

-- (player, amount, newTotal) after AddXP adds XP (newTotal before any level-up carry)
LevelSystem.OnXPGained = Signal.new() :: Signal.Signal<Player, number, number>
-- (player, newLevel, oldLevel) per level gained in AddXP, or when SetLevel changes it
LevelSystem.OnLevelUp  = Signal.new() :: Signal.Signal<Player, number, number>

-- ── Helpers ──

local function getProfile(player: Player): Profile?
	local ok, prof = pcall(function()
		return DataManager.Get(player)
	end)
	if not ok then return nil end
	return prof
end

-- Ensure Level / Experience fields exist on the profile.
local function ensureFields(player: Player): Profile?
	local prof = getProfile(player)
	if not prof then return nil end
	if type(prof.Level) ~= "number" then prof.Level = levelCfg("StartLevel", 1) end
	if type(prof.Experience) ~= "number" then prof.Experience = 0 end
	return prof
end

-- ── Public API ──

function LevelSystem.SetCurve(fn: (level: number) -> number): ()
	assert(type(fn) == "function", "SetCurve requires function(level)->number")
	curveFn = fn
end

function LevelSystem.GetCurve(): (level: number) -> number
	return curveFn
end

function LevelSystem.GetLevel(player: Player): number
	local prof = ensureFields(player)
	if not prof then return 1 end
	return prof.Level
end

function LevelSystem.GetXP(player: Player): number
	local prof = ensureFields(player)
	if not prof then return 0 end
	return prof.Experience
end

function LevelSystem.GetXPToNext(player: Player): number
	local prof = ensureFields(player)
	if not prof then return curveFn(1) end
	local needed = curveFn(prof.Level)
	local remaining = needed - prof.Experience
	if remaining < 0 then remaining = 0 end
	return remaining
end

function LevelSystem.AddXP(player: Player, amount: number): ()
	if amount == nil or amount <= 0 then return end
	local prof = ensureFields(player)
	if not prof then return end -- profile not loaded — silent no-op
	prof.Experience = prof.Experience + amount
	LevelSystem.OnXPGained:Fire(player, amount, prof.Experience)

	-- Multi-level-up loop: keep promoting while XP overflow remains.
	-- WHY: a huge AddXP (e.g. boss kill) could span several levels at once.
	while true do
		local needed = curveFn(prof.Level)
		if prof.Experience < needed then break end
		prof.Experience = prof.Experience - needed
		prof.Level = prof.Level + 1
		LevelSystem.OnLevelUp:Fire(player, prof.Level, prof.Level - 1)
		-- Sanity guard against pathological curves returning <=0.
		if needed <= 0 then break end
	end
end

function LevelSystem.SetLevel(player: Player, level: number): ()
	assert(type(level) == "number" and level >= 1, "SetLevel requires level >= 1")
	local prof = ensureFields(player)
	if not prof then return end
	local old: number = prof.Level
	prof.Level = math.floor(level)
	prof.Experience = 0
	if prof.Level ~= old then
		LevelSystem.OnLevelUp:Fire(player, prof.Level, old)
	end
end

-- Pure API: nothing to set up. The signals exist from require time, so a module
-- that requires LevelSystem can connect to OnLevelUp immediately.
Lifecycle.Define(LevelSystem, {
	Name = "Level",
	Needs = {},
})

return LevelSystem
