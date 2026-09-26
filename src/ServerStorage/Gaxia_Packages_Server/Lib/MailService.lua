--!strict
-- ─────────────────────────────────────────────────────────────
-- MailService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/MailService
-- Purpose : Persistent player inbox with claimable reward attachments — the
--           channel for compensation ("sorry for downtime, here's 500 gems"),
--           gifts, and async player-to-player items. Mail lives in the
--           recipient's profile so it waits until they next log in and survives
--           sessions. Claim() hands the attachments back exactly once (the game
--           grants them) and can't be double-claimed; expired mail is filtered
--           out. (Delivery to a player who is offline RIGHT NOW rides on the
--           24.7 global-store layer; online + on-login delivery work here.)
--
-- Access  : Gaxia.Mail  (server)
--   Gaxia.Mail.Send(player, { Subject="Welcome", Attachments={Coins=100} })
--   local att = Gaxia.Mail.Claim(player, mailId)   -- grant att yourself
-- ─────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal      = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle   = require(script.Parent.ServiceLifecycle)
local Config      = require(script.Parent.Parent.Config)
local EConfig     = require(script.Parent.EffectiveConfig)
local DataManager = require(script.Parent.DataManager)

local MAILBOX_KEY : string = "Mailbox"
local MAX_MAIL : number = 50  -- ultimate fallback if Config absent

local function maxMail(): number
	return EConfig.Get("Mail.MaxMail", Config.Mail.MaxMail or MAX_MAIL)
end

export type MailInput = { Subject: string?, Body: string?, From: string?, Attachments: any?, ExpiresAt: number? }
export type Mail = {
	id: string, subject: string, body: string, from: string,
	attachments: any, sentAt: number, expiresAt: number,
	read: boolean, claimed: boolean,
}

local MailService = {}

-- (player, mail) after Send stored the mail in the recipient's mailbox
MailService.OnReceive = Signal.new() :: Signal.Signal<Player, Mail>

local function loadBox(player: Player): { [string]: any }
	local b = DataManager.Get(player, MAILBOX_KEY)
	return (typeof(b) == "table") and b or {}
end

local function saveBox(player: Player, box: { [string]: any }): ()
	DataManager.Set(player, MAILBOX_KEY, box)
end

local function isExpired(mail: any, now: number): boolean
	return typeof(mail.expiresAt) == "number" and mail.expiresAt > 0 and mail.expiresAt < now
end

-- Trim oldest claimed/read mail when the box overflows.
local function enforceCap(box: { [string]: any }): ()
	local ids: { string } = {}
	for id in pairs(box) do
		if id ~= "__seq" then
			table.insert(ids, id)
		end
	end
	local cap = maxMail()
	if #ids <= cap then
		return
	end
	table.sort(ids, function(a, b)
		return (box[a].sentAt or 0) < (box[b].sentAt or 0)
	end)
	local toRemove = #ids - cap
	for _, id in ipairs(ids) do
		if toRemove <= 0 then
			break
		end
		box[id] = nil
		toRemove -= 1
	end
end

-- ── Public API ──

function MailService.Send(toPlayer: Player, input: MailInput): string
	local box = loadBox(toPlayer)
	local seq = (tonumber(box.__seq) or 0) + 1
	box.__seq = seq
	local id = `mail_{seq}`
	local mail: Mail = {
		id = id,
		subject = input.Subject or "(no subject)",
		body = input.Body or "",
		from = input.From or "System",
		attachments = input.Attachments,
		sentAt = os.time(),
		expiresAt = input.ExpiresAt or 0,
		read = false,
		claimed = false,
	}
	box[id] = mail
	enforceCap(box)
	saveBox(toPlayer, box)
	MailService.OnReceive:Fire(toPlayer, box[id])
	return id
end

function MailService.GetMailbox(player: Player): { Mail }
	local box = loadBox(player)
	local now = os.time()
	local out: { Mail } = {}
	for id, m in pairs(box) do
		if id ~= "__seq" and typeof(m) == "table" and not isExpired(m, now) then
			table.insert(out, m :: Mail)
		end
	end
	table.sort(out, function(a, b)
		return a.sentAt > b.sentAt
	end)
	return out
end

function MailService.GetUnreadCount(player: Player): number
	local n = 0
	for _, m in ipairs(MailService.GetMailbox(player)) do
		if not m.read then
			n += 1
		end
	end
	return n
end

function MailService.MarkRead(player: Player, mailId: string): boolean
	local box = loadBox(player)
	local m = box[mailId]
	if typeof(m) ~= "table" then
		return false
	end
	m.read = true
	saveBox(player, box)
	return true
end

-- Hand back the attachments once; marks the mail read + claimed.
function MailService.Claim(player: Player, mailId: string): (any?, string?)
	local box = loadBox(player)
	local m = box[mailId]
	if typeof(m) ~= "table" then
		return nil, "no such mail"
	end
	if isExpired(m, os.time()) then
		return nil, "expired"
	end
	if m.claimed then
		return nil, "already claimed"
	end
	if m.attachments == nil then
		return nil, "no attachments"
	end
	m.claimed = true
	m.read = true
	saveBox(player, box)
	return m.attachments, nil
end

function MailService.Delete(player: Player, mailId: string): boolean
	local box = loadBox(player)
	if box[mailId] == nil then
		return false
	end
	box[mailId] = nil
	saveBox(player, box)
	return true
end

-- Pure API over the player's profile: nothing to set up. Registered so
-- Features / IsEnabled know it.
Lifecycle.Define(MailService, {
	Name = "Mail",
	Needs = {},
})

return MailService
