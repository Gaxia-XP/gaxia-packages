--!strict
--[[
	Module : EconomyService
	Location: ServerStorage.Gaxia_Packages_Server.Lib.EconomyService
	Purpose : Atomic currency CRUD backed by DataManager. Add/Spend/Transfer
	          validate the amount (whole number, > 0, <= MaxTransaction) and
	          REJECT anything else — they never clamp — then fire OnTransaction.
	          Every rejection warns once per call site and reason, naming the
	          expected signature, so a wrong call is never silent.
]]


-- ── Services ──
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Shared      = ReplicatedStorage.Gaxia_Packages.Shared
local Signal      = require(Shared.Signal)
local Lifecycle   = require(script.Parent.ServiceLifecycle)
local Config      = require(script.Parent.Parent.Config)
local EConfig     = require(script.Parent.EffectiveConfig)
local DataManager = require(script.Parent.DataManager)

-- ── Types ──
export type TransactionKind = "add" | "spend" | "set" | "transfer"

-- ── Effective caps (Config default <- runtime Flag override) ──
local DEFAULT_MAX_TRANSACTION : number = 1_000_000     -- ultimate fallback if Config absent
local DEFAULT_MAX_BALANCE     : number = 1_000_000_000

-- A cap must be a finite number > 0; anything else (a bad Config edit) falls back.
local function validCap(v: any, fallback: number): number
	if typeof(v) == "number" and v == v and v > 0 and v < math.huge then
		return v
	end
	return fallback
end

local function maxTransaction(): number
	local configured = validCap(Config.Economy.MaxTransaction, DEFAULT_MAX_TRANSACTION)
	return validCap(EConfig.Get("Economy.MaxTransaction", configured), configured)
end
local function maxBalance(): number
	local configured = validCap(Config.Economy.MaxBalance, DEFAULT_MAX_BALANCE)
	return validCap(EConfig.Get("Economy.MaxBalance", configured), configured)
end

-- ── Module ──
local EconomyService = {}

-- (player, currency, delta, newBalance, kind)
EconomyService.OnTransaction = Signal.new() :: Signal.Signal<Player, string, number, number, TransactionKind>

-- ── Rejection warnings (once per function + reason + call site) ──

local SIGNATURES: { [string]: string } = {
	Get      = "Economy.Get(player: Player, currency: string): number",
	Add      = "Economy.Add(player: Player, currency: string, amount: number): boolean",
	Spend    = "Economy.Spend(player: Player, currency: string, amount: number): boolean",
	Set      = "Economy.Set(player: Player, currency: string, amount: number): boolean",
	Transfer = "Economy.Transfer(from: Player, to: Player, currency: string, amount: number): boolean",
}

local warned: { [string]: boolean } = {}

-- `level` is the stack level of the game code that called the public function,
-- counted from the function that calls `reject`.
local function reject(fnName: string, reason: string, detail: string, level: number): ()
	local source, line = debug.info(level + 2, "sl")
	local site = if source and line and line > 0 then `{source}:{line}` else "?"
	local key = `{fnName}|{reason}|{site}`
	if warned[key] then
		return
	end
	warned[key] = true
	local where = if site ~= "?" then ` (called from {site})` else ""
	warn(`[Economy] {fnName} refused: {detail}. Expected {SIGNATURES[fnName]}{where}`)
end

local function describe(v: any): string
	if typeof(v) == "string" then
		return `string "{v}"`
	end
	return `{typeof(v)} {tostring(v)}`
end

-- Arguments shared by every call. Returns true when player and currency are usable.
-- `level`: see reject (1 = the caller of the function that calls checkTarget).
local function checkTarget(fnName: string, player: any, currency: any, level: number): boolean
	if typeof(player) ~= "Instance" or not (player :: Instance):IsA("Player") then
		reject(fnName, "player", `player must be a Player, got {describe(player)}`, level + 1)
		return false
	end
	if typeof(currency) ~= "string" or #currency == 0 then
		local hint = if typeof(currency) == "number" then " (are currency and amount swapped?)" else ""
		reject(fnName, "currency", `currency must be a non-empty string, got {describe(currency)}{hint}`, level + 1)
		return false
	end
	return true
end

-- Add/Spend/Transfer amount: a whole number in [1, MaxTransaction]. Never clamps.
local function checkAmount(fnName: string, amount: any, level: number): number?
	local reason: string? = nil
	local detail = ""
	if typeof(amount) ~= "number" then
		local hint = if typeof(amount) == "string" then " (are currency and amount swapped?)" else ""
		reason, detail = "type", `amount must be a number, got {describe(amount)}{hint}`
	elseif amount ~= amount then
		reason, detail = "nan", "amount is NaN"
	elseif amount == math.huge or amount == -math.huge then
		reason, detail = "inf", `amount is {tostring(amount)}`
	elseif amount % 1 ~= 0 then
		reason, detail = "fraction", `amount must be a whole number, got {amount} (round it with math.floor first)`
	elseif amount <= 0 then
		reason, detail = "nonpositive", `amount must be greater than 0, got {amount}`
	else
		local cap = maxTransaction()
		if amount > cap then
			reason, detail = "cap", `amount {amount} is above Economy.MaxTransaction ({cap}); split it or raise the limit with EConfig.Set("Economy.MaxTransaction", n)`
		end
	end
	if reason then
		reject(fnName, reason, detail, level + 1)
		return nil
	end
	return amount
end

-- Current balance, or nil (with a warning) when the saved value under this name
-- is not a number: that key belongs to something else (a table, a string…), and
-- writing a number over it would destroy that data.
-- A saved NaN / ±inf number is a corrupt balance, not "not a currency": the
-- second result is true for it. Get reads it as 0, Add/Spend refuse it, and Set
-- overwrites it (the only way to repair it).
local function readBalance(fnName: string, player: Player, currency: string, level: number): (number?, boolean)
	local v = DataManager.Get(player, currency)
	if v == nil then
		return 0, false
	end
	if typeof(v) ~= "number" then
		reject(fnName, "saved", `the saved value "{currency}" is a {typeof(v)}, not a number: it is not a currency`, level + 1)
		return nil, false
	end
	if v ~= v or v == math.huge or v == -math.huge then
		if fnName ~= "Set" then
			reject(fnName, "corrupt", `the saved balance "{currency}" is {tostring(v)} (corrupt); repair it with Economy.Set(player, "{currency}", amount)`, level + 1)
		end
		return nil, true
	end
	return v, false
end

-- ── Public API ──

-- The current balance. 0 when the player's data has not loaded, the currency was
-- never set, or the saved value under that name is not a number or is NaN/inf (warns).
function EconomyService.Get(player: Player, currency: string): number
	if not checkTarget("Get", player, currency, 1) then return 0 end
	local balance = readBalance("Get", player, currency, 1)
	return balance or 0
end

-- Adds `amount` (a whole number from 1 to Economy.MaxTransaction). Any other
-- amount is refused with a warning (never clamped). The balance stops at
-- Economy.MaxBalance. Returns false when refused or the data is not loaded.
function EconomyService.Add(player: Player, currency: string, amount: number): boolean
	if not checkTarget("Add", player, currency, 1) then return false end
	local amt = checkAmount("Add", amount, 1)
	if not amt then return false end
	local current = readBalance("Add", player, currency, 1)
	if not current then return false end

	local newBalance = math.min(current + amt, maxBalance())
	local ok = DataManager.Set(player, currency, newBalance)
	if ok then
		EconomyService.OnTransaction:Fire(player, currency, newBalance - current, newBalance, "add")
	end
	return ok
end

-- Takes `amount` (a whole number from 1 to Economy.MaxTransaction) if the player
-- has at least that much. Any other amount is refused with a warning (never
-- clamped). Returns false when refused, short on balance or the data is not loaded.
function EconomyService.Spend(player: Player, currency: string, amount: number): boolean
	if not checkTarget("Spend", player, currency, 1) then return false end
	local amt = checkAmount("Spend", amount, 1)
	if not amt then return false end
	local current = readBalance("Spend", player, currency, 1)
	if not current then return false end
	if current < amt then return false end                  -- insufficient balance — atomic check

	local newBalance = current - amt
	local ok = DataManager.Set(player, currency, newBalance)
	if ok then
		EconomyService.OnTransaction:Fire(player, currency, -amt, newBalance, "spend")
	end
	return ok
end

-- Admin override: sets an exact balance (a whole number from 0 to Economy.MaxBalance;
-- skips the MaxTransaction limit). Any other amount is refused with a warning.
-- Also repairs a corrupt (NaN/inf) saved balance, with a warning.
function EconomyService.Set(player: Player, currency: string, amount: number): boolean
	if not checkTarget("Set", player, currency, 1) then return false end
	local reason: string? = nil
	local detail = ""
	if typeof(amount) ~= "number" then
		reason, detail = "type", `amount must be a number, got {describe(amount)}`
	elseif amount ~= amount then
		reason, detail = "nan", "amount is NaN"
	elseif amount == math.huge or amount == -math.huge then
		reason, detail = "inf", `amount is {tostring(amount)}`
	elseif amount % 1 ~= 0 then
		reason, detail = "fraction", `amount must be a whole number, got {amount}`
	elseif amount < 0 then
		reason, detail = "negative", `amount must be 0 or more, got {amount}`
	elseif amount > maxBalance() then
		reason, detail = "cap", `amount {amount} is above Economy.MaxBalance ({maxBalance()})`
	end
	if reason then
		reject("Set", reason, detail, 1)
		return false
	end
	local current, corrupt = readBalance("Set", player, currency, 1)
	if corrupt then
		warn(`[Economy] Set repaired a corrupt saved balance "{currency}" ({tostring(DataManager.Get(player, currency))}) for {player.Name}: now {amount}`)
		current = 0
	end
	if not current then return false end
	local ok = DataManager.Set(player, currency, amount)
	if ok then
		EconomyService.OnTransaction:Fire(player, currency, amount - current, amount, "set")
	end
	return ok
end

-- Atomic transfer between two players. Spend from sender first; only credit
-- recipient if Spend succeeded so failure can't duplicate currency.
function EconomyService.Transfer(from: Player, to: Player, currency: string, amount: number): boolean
	if not checkTarget("Transfer", from, currency, 1) then return false end
	if not checkTarget("Transfer", to, currency, 1) then return false end
	if from == to then return false end
	local amt = checkAmount("Transfer", amount, 1)
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

-- The largest amount one Add / Spend / Transfer accepts right now
-- (Config Economy.MaxTransaction, or its runtime override).
function EconomyService.GetMaxTransaction(): number
	return maxTransaction()
end

-- The highest balance Add can reach (Config Economy.MaxBalance, or its runtime override).
function EconomyService.GetMaxBalance(): number
	return maxBalance()
end

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(EconomyService, {
	Name = "Economy",
	Needs = {},
})

return EconomyService
