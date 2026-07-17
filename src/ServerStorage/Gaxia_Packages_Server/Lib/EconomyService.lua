--!strict
--[[
	Module : EconomyService
	Location: ServerStorage.Gaxia_Packages_Server.Lib.EconomyService
	Purpose : Atomic currency CRUD backed by DataManager. Add/Spend/Transfer
	          validate amount, clamp to MAX_TRANSACTION, and fire OnTransaction.
]]


-- ── Services ──
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

-- ── Shared ──
local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages")) :: any
local Signal    = SharedPkg.Signal

-- ── Lazy server (DataManager + Config + EConfig) ──
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

-- ── Effective caps (Config default <- runtime Flag override) ──
local DEFAULT_MAX_TRANSACTION : number = 1_000_000     -- ultimate fallback if Config absent
local DEFAULT_MAX_BALANCE     : number = 1_000_000_000

local function maxTransaction(): number
	local s = server()
	return s.EConfig.Get("Economy.MaxTransaction", (s.Config.Economy or {}).MaxTransaction or DEFAULT_MAX_TRANSACTION)
end
local function maxBalance(): number
	local s = server()
	return s.EConfig.Get("Economy.MaxBalance", (s.Config.Economy or {}).MaxBalance or DEFAULT_MAX_BALANCE)
end

-- ── Module ──
local EconomyService = {}

-- (player, currency, delta, newBalance, kind) — kind ∈ "add" | "spend" | "set" | "transfer"
EconomyService.OnTransaction = Signal.new()

-- ── Helpers ──

local function validateCurrency(currency: any): boolean
	return typeof(currency) == "string" and #currency > 0
end

-- Anti-exploit clamp: returns nil for invalid amounts so callers reject fast.
local function clampAmount(amount: any): number?
	if typeof(amount) ~= "number" then return nil end
	if amount ~= amount then return nil end                 -- NaN guard
	if amount <= 0 then return nil end
	local cap = maxTransaction()
	if amount > cap then return cap end
	return math.floor(amount)
end

-- ── Public API ──

function EconomyService.Get(player: Player, currency: string): number
	if not validateCurrency(currency) then return 0 end
	local Data = getData()
	if not Data then return 0 end
	local v = Data.Get(player, currency)
	return typeof(v) == "number" and v or 0
end

function EconomyService.Add(player: Player, currency: string, amount: number): boolean
	if not validateCurrency(currency) then return false end
	local amt = clampAmount(amount)
	if not amt then return false end

	local current = EconomyService.Get(player, currency)
	local newBalance = math.min(current + amt, maxBalance())
	local Data = getData()
	if not Data then return false end
	local ok = Data.Set(player, currency, newBalance)
	if ok then
		EconomyService.OnTransaction:Fire(player, currency, newBalance - current, newBalance, "add")
	end
	return ok
end

function EconomyService.Spend(player: Player, currency: string, amount: number): boolean
	if not validateCurrency(currency) then return false end
	local amt = clampAmount(amount)
	if not amt then return false end

	local current = EconomyService.Get(player, currency)
	if current < amt then return false end                  -- insufficient balance — atomic check

	local newBalance = current - amt
	local Data = getData()
	if not Data then return false end
	local ok = Data.Set(player, currency, newBalance)
	if ok then
		EconomyService.OnTransaction:Fire(player, currency, -amt, newBalance, "spend")
	end
	return ok
end

-- Admin override — bypasses Add/Spend clamps. Use sparingly (rewards, refunds).
function EconomyService.Set(player: Player, currency: string, amount: number): boolean
	if not validateCurrency(currency) then return false end
	if typeof(amount) ~= "number" or amount ~= amount then return false end
	local clamped = math.max(0, math.min(math.floor(amount), maxBalance()))
	local current = EconomyService.Get(player, currency)
	local Data = getData()
	if not Data then return false end
	local ok = Data.Set(player, currency, clamped)
	if ok then
		EconomyService.OnTransaction:Fire(player, currency, clamped - current, clamped, "set")
	end
	return ok
end

-- Atomic transfer between two players. Spend from sender first; only credit
-- recipient if Spend succeeded so failure can't duplicate currency.
function EconomyService.Transfer(from: Player, to: Player, currency: string, amount: number): boolean
	if from == to then return false end
	local amt = clampAmount(amount)
	if not amt then return false end
	if not EconomyService.Spend(from, currency, amt) then return false end
	if not EconomyService.Add(to, currency, amt) then
		-- Recipient credit failed (e.g. profile not loaded) — refund sender to keep totals conserved.
		EconomyService.Add(from, currency, amt)
		return false
	end
	-- Both legs succeeded — emit a single "transfer" telemetry record per side.
	EconomyService.OnTransaction:Fire(from, currency, -amt, EconomyService.Get(from, currency), "transfer")
	EconomyService.OnTransaction:Fire(to,   currency,  amt, EconomyService.Get(to,   currency), "transfer")
	return true
end

return EconomyService
