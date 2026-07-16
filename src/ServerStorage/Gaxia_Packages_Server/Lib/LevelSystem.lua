--!strict
-- ─────────────────────────────────────────────────────────────
-- LevelSystem.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/LevelSystem
-- Purpose : Server-side XP/level progression. Persists in
--           Profile.Level / Profile.Experience via DataManager.
--           Curve is configurable; AddXP handles multi-level-up.
-- ─────────────────────────────────────────────────────────────


local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

-- ── Direct-path lazy require for DataManager ──
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

-- ── Lazy server (Config + EConfig) — resolved at CALL-TIME, never module load ──
local ServerStorage = game:GetService("ServerStorage")
local _server: any = nil
local function server(): any
	if not _server then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server"):WaitForChild("init")
		_server = require(serverInit :: any)
	end
	return _server
end
-- Config default <- runtime Flag override via Gaxia.EConfig. Read per-call so an
-- admin can `/flag set Level.CurveExponent N` to retune leveling pace live.
local function levelCfg(key: string, default: number): number
	local s = server()
	return s.EConfig.Get("Level." .. key, (s.Config.Level or {})[key] or default)
end

-- ── Module ──
local LevelSystem = {}

-- Default curve: classic RPG-ish polynomial growth. Base coefficient + exponent
-- come from Config.Level (CurveBase / CurveExponent), runtime-overridable.
local DEFAULT_CURVE: (level: number) -> number = function(level: number): number
	return math.floor(levelCfg("CurveBase", 100) * (level ^ levelCfg("CurveExponent", 1.5)))
end

local curveFn: (level: number) -> number = DEFAULT_CURVE

LevelSystem.OnXPGained = Signal.new()  -- (player, amount, newTotal)
LevelSystem.OnLevelUp  = Signal.new()  -- (player, newLevel, oldLevel)

-- ── Helpers ──

local function getProfile(player: Player): any?
	local dm = getDataManager()
	if not dm then return nil end
	local ok, prof = pcall(dm.Get, player)
	if not ok then return nil end
	return prof
end

-- Ensure Level / Experience fields exist on the profile.
local function ensureFields(player: Player): any?
	local prof = getProfile(player)
	if not prof then return nil end
	local alias: any = prof
	if type(alias.Level) ~= "number" then alias.Level = levelCfg("StartLevel", 1) end
	if type(alias.Experience) ~= "number" then alias.Experience = 0 end
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
	return (prof :: any).Level
end

function LevelSystem.GetXP(player: Player): number
	local prof = ensureFields(player)
	if not prof then return 0 end
	return (prof :: any).Experience
end

function LevelSystem.GetXPToNext(player: Player): number
	local prof = ensureFields(player)
	if not prof then return curveFn(1) end
	local alias: any = prof
	local needed = curveFn(alias.Level)
	local remaining = needed - alias.Experience
	if remaining < 0 then remaining = 0 end
	return remaining
end

function LevelSystem.AddXP(player: Player, amount: number): ()
	if amount == nil or amount <= 0 then return end
	local prof = ensureFields(player)
	if not prof then return end -- profile not loaded — silent no-op
	local alias: any = prof
	local oldLevel: number = alias.Level
	alias.Experience = alias.Experience + amount
	LevelSystem.OnXPGained:Fire(player, amount, alias.Experience)

	-- Multi-level-up loop: keep promoting while XP overflow remains.
	-- WHY: a huge AddXP (e.g. boss kill) could span several levels at once.
	while true do
		local needed = curveFn(alias.Level)
		if alias.Experience < needed then break end
		alias.Experience = alias.Experience - needed
		alias.Level = alias.Level + 1
		LevelSystem.OnLevelUp:Fire(player, alias.Level, alias.Level - 1)
		-- Sanity guard against pathological curves returning <=0.
		if needed <= 0 then break end
	end
	-- Silence unused-warning on oldLevel — kept for potential future delta logging.
	local _ = oldLevel
end

function LevelSystem.SetLevel(player: Player, level: number): ()
	assert(type(level) == "number" and level >= 1, "SetLevel requires level >= 1")
	local prof = ensureFields(player)
	if not prof then return end
	local alias: any = prof
	local old: number = alias.Level
	alias.Level = math.floor(level)
	alias.Experience = 0
	if alias.Level ~= old then
		LevelSystem.OnLevelUp:Fire(player, alias.Level, old)
	end
end

return LevelSystem
