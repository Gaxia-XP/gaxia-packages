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
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

local GaxiaServer: any = nil
local function server(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server"):WaitForChild("init")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer
end

type Offer = { items: { [string]: number }, currencies: { [string]: number }, confirmed: boolean }
type Trade = { id: string, a: any, b: any, offers: { [number]: Offer } }

local TradeService = {}

TradeService.OnUpdate = Signal.new()   -- (tradeId)
TradeService.OnComplete = Signal.new() -- (tradeId, success)

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

function TradeService.Request(from: any, to: any): (string?, string?)
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

function TradeService.GetActiveTrade(player: any): string?
	return playerTrade[player.UserId]
end

function TradeService.GetTrade(tradeId: string): Trade?
	return trades[tradeId]
end

local function sideOf(tradeId: string, player: any): (Trade?, Offer?)
	local trade = trades[tradeId]
	if not trade then
		return nil, nil
	end
	return trade, trade.offers[player.UserId]
end

-- ── Building an offer (each change re-opens both confirmations) ──

function TradeService.AddItem(player: any, tradeId: string, itemId: string, count: number): (boolean, string)
	local trade, offer = sideOf(tradeId, player)
	if not trade or not offer then
		return false, "not in this trade"
	end
	offer.items[itemId] = (offer.items[itemId] or 0) + math.max(1, math.floor(count))
	resetConfirms(trade)
	TradeService.OnUpdate:Fire(tradeId)
	return true, "ok"
end

function TradeService.RemoveItem(player: any, tradeId: string, itemId: string, count: number?): (boolean, string)
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

function TradeService.AddCurrency(player: any, tradeId: string, currency: string, amount: number): (boolean, string)
	local trade, offer = sideOf(tradeId, player)
	if not trade or not offer then
		return false, "not in this trade"
	end
	offer.currencies[currency] = (offer.currencies[currency] or 0) + math.max(1, math.floor(amount))
	resetConfirms(trade)
	TradeService.OnUpdate:Fire(tradeId)
	return true, "ok"
end

function TradeService.RemoveCurrency(player: any, tradeId: string, currency: string, amount: number?): (boolean, string)
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

function TradeService.IsConfirmed(player: any, tradeId: string): boolean
	local _, offer = sideOf(tradeId, player)
	return offer ~= nil and offer.confirmed
end

-- ── Atomic execution ──

local function hasAll(player: any, offer: Offer): boolean
	local Item, Economy = server().Item, server().Economy
	for itemId, cnt in pairs(offer.items) do
		if not Item.Has(player, itemId, cnt) then
			return false
		end
	end
	for cur, amt in pairs(offer.currencies) do
		if Economy.Get(player, cur) < amt then
			return false
		end
	end
	return true
end

local function execute(trade: Trade): (boolean, string)
	local A, B = trade.a, trade.b
	local oa, ob = trade.offers[A.UserId], trade.offers[B.UserId]
	local Item, Economy = server().Item, server().Economy

	if not hasAll(A, oa) then
		return false, "A lacks offered"
	end
	if not hasAll(B, ob) then
		return false, "B lacks offered"
	end

	local removed: { { who: any, kind: string, id: string, amt: number } } = {}
	local function refundRemoved()
		for _, r in ipairs(removed) do
			if r.kind == "item" then
				Item.Give(r.who, r.id, r.amt)
			else
				Economy.Add(r.who, r.id, r.amt)
			end
		end
	end
	local function take(player: any, offer: Offer): boolean
		for itemId, cnt in pairs(offer.items) do
			if Item.Remove(player, itemId, cnt) then
				table.insert(removed, { who = player, kind = "item", id = itemId, amt = cnt })
			else
				return false
			end
		end
		for cur, amt in pairs(offer.currencies) do
			if Economy.Spend(player, cur, amt) then
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

	local given: { { who: any, kind: string, id: string, amt: number } } = {}
	local function give(recipient: any, offer: Offer): boolean
		for itemId, cnt in pairs(offer.items) do
			if Item.Give(recipient, itemId, cnt) then
				table.insert(given, { who = recipient, kind = "item", id = itemId, amt = cnt })
			else
				return false
			end
		end
		for cur, amt in pairs(offer.currencies) do
			if Economy.Add(recipient, cur, amt) then
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
				Item.Remove(g.who, g.id, g.amt)
			else
				Economy.Spend(g.who, g.id, g.amt)
			end
		end
		refundRemoved()
		return false, "credit failed — rolled back"
	end
	return true, "ok"
end

-- ── Confirm / cancel ──

-- Returns (ok, executed, message). The swap fires when BOTH sides are confirmed.
function TradeService.Confirm(player: any, tradeId: string): (boolean, boolean, string)
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

function TradeService.Cancel(player: any, tradeId: string): boolean
	local trade = trades[tradeId]
	if not trade then
		return false
	end
	teardown(trade)
	TradeService.OnComplete:Fire(tradeId, false)
	return true
end

return TradeService
