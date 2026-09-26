--!strict
-- ─────────────────────────────────────────────────────────────
-- IdleService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/IdleService
-- Purpose : Passive / offline earnings — the core loop of idle & tycoon games.
--           Tracks the last collect time; Collect() grants rate × elapsed,
--           with elapsed CLAMPED to MAX_OFFLINE (so a month away doesn't pay a
--           month) and the payout clamped to a per-player cap. Works the same
--           online or offline (elapsed-since-last-collect), so a single Collect
--           on join + on a timer drives both. Optional auto-grant via Gaxia.
--           Economy; always fires OnOfflineEarnings. lastSeen persists in the
--           profile so the clock survives rejoins.
--
-- Access  : Gaxia.Idle  (server)
--   Gaxia.Idle.Configure(player, { Rate = 5, Currency = "Coins", Cap = 50000 })
--   local earned, secs = Gaxia.Idle.Collect(player)  -- call on join + on a loop
-- ─────────────────────────────────────────────────────────────
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Shared         = ReplicatedStorage.Gaxia_Packages.Shared
local Signal         = require(Shared.Signal)
local Lifecycle      = require(script.Parent.ServiceLifecycle)
local Config         = require(script.Parent.Parent.Config)
local EConfig        = require(script.Parent.EffectiveConfig)
local DataManager    = require(script.Parent.DataManager)
local EconomyService = require(script.Parent.EconomyService)
-- Best-effort Coins multiplier (call-time only, so not a Need).
local PetService     = require(script.Parent.PetService)

local LAST_SEEN_KEY : string = "IdleLastSeen"
local DEFAULT_RATE  : number = 1           -- ultimate fallback if Config absent
local MAX_OFFLINE   : number = 8 * 3600    -- ultimate fallback (8h)
local COIN_CURRENCY : string = "Coins"     -- the pet multiplier boosts only this currency (matches PetService.EGG_CURRENCY)

-- Effective tunables: runtime Flag override <- Config.Idle default <- fallback.
local function defaultRate(): number
	return EConfig.Get("Idle.DefaultRate", Config.Idle.DefaultRate or DEFAULT_RATE)
end
local function maxOffline(): number
	return EConfig.Get("Idle.MaxOffline", Config.Idle.MaxOffline or MAX_OFFLINE)
end

-- Best-effort equipped-pet Coins multiplier. Returns 1.0 if the Pet service
-- failed to start (GaxiaServer.Pet is nil), the profile is unloaded, or the call
-- errors / returns NaN — so wiring this into a faucet can never break the grant
-- itself. Calling it starts Pet if nothing has yet (like touching GaxiaServer.Pet).
local function coinMultiplierFor(player: Player): number
	if Lifecycle.GetState(PetService) == "failed" then
		return 1.0
	end
	local ok, mult = pcall(function(): number
		return PetService.GetCoinMultiplier(player)
	end)
	if ok and typeof(mult) == "number" and mult == mult then -- mult == mult rejects NaN
		return mult
	end
	return 1.0
end

export type IdleConfig = { Rate: number?, Cap: number?, Currency: string? }

local IdleService = {}

-- (player, earnings, seconds) after a Collect that paid > 0; earnings = the amount
-- actually credited (after the pet multiplier), seconds = the clamped offline time
IdleService.OnOfflineEarnings = Signal.new() :: Signal.Signal<Player, number, number>

local configs: { [Player]: IdleConfig } = {}

-- ── PURE: clamp elapsed then apply rate + cap (unit-testable) ──
function IdleService.ComputeOffline(lastSeen: number, now: number, rate: number, maxOffline: number, cap: number): (number, number)
	local secs = math.clamp(now - lastSeen, 0, maxOffline)
	local earnings = math.min(rate * secs, cap)
	return math.floor(earnings), secs
end

-- ── Config ──

function IdleService.Configure(player: Player, cfg: IdleConfig): ()
	configs[player] = cfg
end

function IdleService.SetRate(player: Player, rate: number): ()
	local c: IdleConfig = configs[player] or {}
	c.Rate = rate
	configs[player] = c
end

function IdleService.GetRate(player: Player): number
	local c = configs[player]
	return (c and c.Rate) or defaultRate()
end

-- ── Internal ──

local function paramsFor(player: Player): (number, number, string?)
	local c: IdleConfig = configs[player] or {}
	return c.Rate or defaultRate(), c.Cap or math.huge, c.Currency
end

local function readLastSeen(player: Player): number
	local v = DataManager.Get(player, LAST_SEEN_KEY)
	if typeof(v) == "number" then
		return v
	end
	return os.time() -- first ever: anchor to now so the first Collect pays 0
end

-- ── Pending (preview — does NOT consume) ──

function IdleService.GetPending(player: Player): (number, number)
	local rate, cap = paramsFor(player)
	return IdleService.ComputeOffline(readLastSeen(player), os.time(), rate, maxOffline(), cap)
end

-- ── Collect (consumes elapsed; grants + fires) ──

function IdleService.Collect(player: Player): (number, number)
	local rate, cap, currency = paramsFor(player)
	local lastSeen = readLastSeen(player)
	local now = os.time()
	local earnings, secs = IdleService.ComputeOffline(lastSeen, now, rate, maxOffline(), cap)
	DataManager.Set(player, LAST_SEEN_KEY, now)
	local granted = earnings
	if earnings > 0 then
		if currency then
			-- The pet Coins multiplier boosts ONLY the coin currency (a Gems idle
			-- payout must not be inflated by a coin multiplier).
			if currency == COIN_CURRENCY then
				-- Pets help you reach the offline cap faster, but the configured `cap`
				-- stays a HARD ceiling (it means "never pay more than this per collect").
				-- When no cap is set, `cap` is math.huge so this is a plain multiply.
				-- Flip to exceed-cap by dropping the `math.min(…, cap)` wrapper.
				granted = math.min(math.floor(earnings * coinMultiplierFor(player)), cap)
			end
			EconomyService.Add(player, currency, granted)
		end
		-- Fire + return the POST-multiplier amount actually credited (not the base),
		-- so a UI listener / caller shows what the player really earned.
		IdleService.OnOfflineEarnings:Fire(player, granted, secs)
	end
	return granted, secs
end

-- Stamp lastSeen = now (e.g. on leave) so offline time is measured from here.
function IdleService.RecordSeen(player: Player): ()
	DataManager.Set(player, LAST_SEEN_KEY, os.time())
end

local function onPlayerRemoving(player: Player): ()
	-- best-effort stamp; pcall since the profile may already be releasing
	pcall(IdleService.RecordSeen, player)
	configs[player] = nil
end

Lifecycle.Define(IdleService, {
	Name = "Idle",
	Needs = {},
	Init = function()
		-- Stamp lastSeen on leave so offline time is measured from the leave.
		Players.PlayerRemoving:Connect(onPlayerRemoving)
	end,
})

return IdleService
