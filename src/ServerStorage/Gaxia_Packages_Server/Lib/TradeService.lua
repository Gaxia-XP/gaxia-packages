--!strict
-- ─────────────────────────────────────────────────────────────
-- TradeService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/TradeService
-- Purpose : Two-party, both-confirm, ATOMIC item+currency trading — the #1 dupe
--           surface, so it's built last on verified primitives and vetted hard.
--           Each side builds an offer (items via Gaxia.Item, currency via Gaxia.
--           Economy); ANY change re-opens both confirmations (you can't sneak an
--           edit in after your partner locks). When both confirm, the swap runs
--           in one synchronous, yield-free pass: re-validate ownership NOW, debit
--           both, credit both — and if any leg fails the whole thing rolls back,
--           so currency/items can never be duplicated or lost.
--
-- Access  : Gaxia.Trade  (server)
--   local id = Gaxia.Trade.Request(a, b)
--   Gaxia.Trade.AddCurrency(a, id, "Coins", 100) ; Gaxia.Trade.AddItem(b, id, "Sword", 1)
--   Gaxia.Trade.Confirm(a, id) ; Gaxia.Trade.Confirm(b, id)  -- executes on 2nd
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal         = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle      = require(script.Parent.ServiceLifecycle)
local ItemService    = require(script.Parent.ItemService)
local EconomyService = require(script.Parent.EconomyService)

-- ── Types ──
-- One side's offer: itemId → count, currency → amount, and whether that side confirmed.
export type Offer = { items: { [string]: number }, currencies: { [string]: number }, confirmed: boolean }
-- A live trade session (GetTrade). offers is keyed by each side's UserId.
export type Trade = { id: string, a: Player, b: Player, offers: { [number]: Offer } }

local TradeService = {}

-- (tradeId) on Request, every offer change and every Confirm
TradeService.OnUpdate = Signal.new() :: Signal.Signal<string>
-- (tradeId, success) after the swap ran (Confirm) or the trade was cancelled (success = false)
TradeService.OnComplete = Signal.new() :: Signal.Signal<string, boolean>

local trades: { [string]: Trade } = {}
local playerTrade: { [number]: string } = {}
local seq = 0

local function newOffer(): Offer
	return { items = {}, currencies = {}, confirmed = false }
end

local function resetConfirms(trade: Trade): ()
	for _, o in pairs(trade.offers) do
		o.confirmed = false
	end
end

local function teardown(trade: Trade): ()
	playerTrade[trade.a.UserId] = nil
	playerTrade[trade.b.UserId] = nil
	trades[trade.id] = nil
end

-- ── Session lifecycle ──

function TradeService.Request(from: Player, to: Player): (string?, string?)
	if from.UserId == to.UserId then
		return nil, "cannot trade self"
	end
	if playerTrade[from.UserId] or playerTrade[to.UserId] then
		return nil, "already trading"
	end
	seq += 1
	local id = `trade_{seq}`
	trades[id] = { id = id, a = from, b = to, offers = { [from.UserId] = newOffer(), [to.UserId] = newOffer() } }
	playerTrade[from.UserId] = id
	playerTrade[to.UserId] = id
	TradeService.OnUpdate:Fire(id)
	return id, nil
end

function TradeService.GetActiveTrade(player: Player): string?
	return playerTrade[player.UserId]
end

function TradeService.GetTrade(tradeId: string): Trade?
	return trades[tradeId]
end

local function sideOf(tradeId: string, player: Player): (Trade?, Offer?)
	local trade = trades[tradeId]
	if not trade then
		return nil, nil
	end
	return trade, trade.offers[player.UserId]
end

-- ── Building an offer (each change re-opens both confirmations) ──

function TradeService.AddItem(player: Player, tradeId: string, itemId: string, count: number): (boolean, string)
	local trade, offer = sideOf(tradeId, player)
	if not trade or not offer then
		return false, "not in this trade"
	end
	offer.items[itemId] = (offer.items[itemId] or 0) + math.max(1, math.floor(count))
	resetConfirms(trade)
	TradeService.OnUpdate:Fire(tradeId)
	return true, "ok"
end

function TradeService.RemoveItem(player: Player, tradeId: string, itemId: string, count: number?): (boolean, string)
	local trade, offer = sideOf(tradeId, player)
	if not trade or not offer or not offer.items[itemId] then
		return false, "not offered"
	end
	if count and count < offer.items[itemId] then
		offer.items[itemId] -= math.floor(count)
	else
		offer.items[itemId] = nil
	end
	resetConfirms(trade)
	TradeService.OnUpdate:Fire(tradeId)
	return true, "ok"
end

function TradeService.AddCurrency(player: Player, tradeId: string, currency: string, amount: number): (boolean, string)
	local trade, offer = sideOf(tradeId, player)
	if not trade or not offer then
		return false, "not in this trade"
	end
	offer.currencies[currency] = (offer.currencies[currency] or 0) + math.max(1, math.floor(amount))
	resetConfirms(trade)
	TradeService.OnUpdate:Fire(tradeId)
	return true, "ok"
end

function TradeService.RemoveCurrency(player: Player, tradeId: string, currency: string, amount: number?): (boolean, string)
	local trade, offer = sideOf(tradeId, player)
	if not trade or not offer or not offer.currencies[currency] then
		return false, "not offered"
	end
	if amount and amount < offer.currencies[currency] then
		offer.currencies[currency] -= math.floor(amount)
	else
		offer.currencies[currency] = nil
	end
	resetConfirms(trade)
	TradeService.OnUpdate:Fire(tradeId)
	return true, "ok"
end

function TradeService.IsConfirmed(player: Player, tradeId: string): boolean
	local _, offer = sideOf(tradeId, player)
	return offer ~= nil and offer.confirmed
end

-- ── Atomic execution ──

local function hasAll(player: Player, offer: Offer): boolean
	for itemId, cnt in pairs(offer.items) do
		if not ItemService.Has(player, itemId, cnt) then
			return false
		end
	end
	for cur, amt in pairs(offer.currencies) do
		if EconomyService.Get(player, cur) < amt then
			return false
		end
	end
	return true
end

local function execute(trade: Trade): (boolean, string)
	local A, B = trade.a, trade.b
	local oa, ob = trade.offers[A.UserId], trade.offers[B.UserId]

	if not hasAll(A, oa) then
		return false, "A lacks offered"
	end
	if not hasAll(B, ob) then
		return false, "B lacks offered"
	end

	local removed: { { who: Player, kind: string, id: string, amt: number } } = {}
	local function refundRemoved()
		for _, r in ipairs(removed) do
			if r.kind == "item" then
				ItemService.Give(r.who, r.id, r.amt)
			else
				EconomyService.Add(r.who, r.id, r.amt)
			end
		end
	end
	local function take(player: Player, offer: Offer): boolean
		for itemId, cnt in pairs(offer.items) do
			if ItemService.Remove(player, itemId, cnt) then
				table.insert(removed, { who = player, kind = "item", id = itemId, amt = cnt })
			else
				return false
			end
		end
		for cur, amt in pairs(offer.currencies) do
			if EconomyService.Spend(player, cur, amt) then
				table.insert(removed, { who = player, kind = "cur", id = cur, amt = amt })
			else
				return false
			end
		end
		return true
	end

	if not take(A, oa) or not take(B, ob) then
		refundRemoved()
		return false, "debit failed — rolled back"
	end

	local given: { { who: Player, kind: string, id: string, amt: number } } = {}
	local function give(recipient: Player, offer: Offer): boolean
		for itemId, cnt in pairs(offer.items) do
			if ItemService.Give(recipient, itemId, cnt) then
				table.insert(given, { who = recipient, kind = "item", id = itemId, amt = cnt })
			else
				return false
			end
		end
		for cur, amt in pairs(offer.currencies) do
			if EconomyService.Add(recipient, cur, amt) then
				table.insert(given, { who = recipient, kind = "cur", id = cur, amt = amt })
			else
				return false
			end
		end
		return true
	end

	-- A's offer goes to B; B's offer goes to A.
	if not give(B, oa) or not give(A, ob) then
		for _, g in ipairs(given) do
			if g.kind == "item" then
				ItemService.Remove(g.who, g.id, g.amt)
			else
				EconomyService.Spend(g.who, g.id, g.amt)
			end
		end
		refundRemoved()
		return false, "credit failed — rolled back"
	end
	return true, "ok"
end

-- ── Confirm / cancel ──

-- Returns (ok, executed, message). The swap fires when BOTH sides are confirmed.
function TradeService.Confirm(player: Player, tradeId: string): (boolean, boolean, string)
	local trade, offer = sideOf(tradeId, player)
	if not trade or not offer then
		return false, false, "not in this trade"
	end
	offer.confirmed = true
	TradeService.OnUpdate:Fire(tradeId)

	local bothConfirmed = true
	for _, o in pairs(trade.offers) do
		if not o.confirmed then
			bothConfirmed = false
		end
	end
	if not bothConfirmed then
		return true, false, "waiting for partner"
	end

	local ok, msg = execute(trade)
	teardown(trade)
	TradeService.OnComplete:Fire(tradeId, ok)
	return ok, ok, msg
end

function TradeService.Cancel(player: Player, tradeId: string): boolean
	local trade = trades[tradeId]
	if not trade then
		return false
	end
	teardown(trade)
	TradeService.OnComplete:Fire(tradeId, false)
	return true
end

-- Pure API (session state only): nothing to set up. Registered so Features /
-- IsEnabled know it.
Lifecycle.Define(TradeService, {
	Name = "Trade",
	Needs = {},
})

return TradeService
