--!strict
-- ─────────────────────────────────────────────────────────────
-- WebhookService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/WebhookService
-- Purpose : Outbound webhooks (Discord-first, but any JSON to any URL). A
--           per-channel queue throttles + retries (HTTP 429 aware) so reports
--           are reliable and never block game logic. Auto-reports player Bans
--           and AntiCheat hard actions with zero wiring when a channel is set.
--
-- SERVER-ONLY. Webhook URLs are secrets: they live in Config.Webhook.Channels
-- or are set from a server Script with Webhook.SetChannel (both ServerStorage-side,
-- never replicated) and are NEVER driven by client RemoteEvents (a client-triggered
-- webhook is an abuse vector).
--
-- Access  : Gaxia.Webhook  (server)
--   Gaxia.Webhook.SetChannel("BanReports", "https://discord.com/api/webhooks/...")
--   Gaxia.Webhook.Discord("BanReports", { title = "Hi", description = "world", color = Color3.fromRGB(231,76,60) })
--   Gaxia.Webhook.Send("ShopStock", { content = "Stock updated" })   -- raw JSON
--   Gaxia.Webhook.SendUrl("https://discord.com/api/webhooks/...", { content = "ad-hoc" })
--
-- Lifecycle: Start wires the auto-reports (Ban, AntiCheat, Guild signals) for
--            each Config.Webhook.AutoReport source whose package is installed. The
--            channel and its URL are looked up when the event fires, so a channel
--            set later (SetChannel, or Config from a game Script) still reports.
--            Subscribing never starts those services (Features decides). Start also
--            binds game:BindToClose to deliver what is still queued at shutdown.
-- ─────────────────────────────────────────────────────────────
local HttpService       = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal       = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle    = require(script.Parent.ServiceLifecycle)
local Config       = require(script.Parent.Parent.Config)
local EConfig      = require(script.Parent.EffectiveConfig)
local Types        = require(script.Parent.Parent.Types)

-- Soft dependencies: each auto-report is wired only when its package is installed
-- (looked up with Lifecycle.Find in Start).
type BanApi = { OnBan: Signal.Signal<number, any>, OnUnban: Signal.Signal<number> }
type AntiCheatApi = { OnAction: Signal.Signal<Player, string, Types.ActionKind> }
type GuildApi = {
	OnCreate: Signal.Signal<string, number>,
	OnDisband: Signal.Signal<string, number>,
	OnRoleChange: Signal.Signal<string, number, any>,
}

-- ── Effective config (call-time: Config default <- runtime Flag override) ──
local function flag(key: string, fallback: any): any
	-- key is the dotted path under "Webhook." e.g. flag("Enabled", true)
	return EConfig.Get("Webhook." .. key, fallback)
end
local function enabled(): boolean
	return flag("Enabled", Config.Webhook.Enabled ~= false) == true
end
-- `configured` is Config.Webhook.RateLimit[key] (nil falls back to `fallback`).
local function rate(key: string, configured: number?, fallback: number): number
	return flag("RateLimit." .. key, configured or fallback)
end
-- Channels set from code with Webhook.SetChannel (they win over Config).
local runtimeChannels: { [string]: string } = {}

-- Looked up on every call (never cached), so a channel set after boot works.
local function channelUrl(channel: string): string?
	local url: any = runtimeChannels[channel]
	if url == nil then
		-- Channels maps channel name -> secret URL (a free-form map in Config).
		url = Config.Webhook.Channels[channel]
	end
	if typeof(url) == "string" and #url > 0 then
		return url
	end
	return nil
end

-- ── Module ──
local Webhook = {}

-- (channel, ok) after a 2xx delivery; channel is "(url)" for SendUrl
Webhook.OnSend = Signal.new() :: Signal.Signal<string, boolean>
-- (channel, reason) when a payload is dropped (JSON encode failure, retries exhausted,
-- "queue_full" when MaxQueue pushed it out). Not fired while HTTP is disabled: those
-- messages stay queued and are retried.
Webhook.OnError = Signal.new() :: Signal.Signal<string, string>

-- ── Transport ──
-- transport(url, body) -> (ok, status?, retryAfter?, err?)
--   ok=true             : 2xx
--   ok=false, status=n  : HTTP non-2xx (retryAfter set when status == 429)
--   ok=false, err=string: request threw (HTTP disabled / network)
local function defaultTransport(url: string, body: string): (boolean, number?, number?, string?)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
	end)
	if not ok then
		return false, nil, nil, tostring(res)
	end
	local status: number = res.StatusCode
	if status >= 200 and status < 300 then
		return true, status, nil, nil
	end
	local retryAfter: number? = nil
	if status == 429 then
		local headers = res.Headers or {}
		retryAfter = tonumber(headers["retry-after"] or headers["Retry-After"])
		if not retryAfter then
			local okd, decoded = pcall(function() return HttpService:JSONDecode(res.Body) end)
			if okd and typeof(decoded) == "table" and decoded.retry_after then
				retryAfter = tonumber(decoded.retry_after)
			end
		end
	end
	return false, status, retryAfter, res.Body
end

local transport: (url: string, body: string) -> (boolean, number?, number?, string?) = defaultTransport

function Webhook.SetTransport(fn: (url: string, body: string) -> (boolean, number?, number?, string?)): ()
	if typeof(fn) == "function" then
		transport = fn
	end
end

-- ── Queue + drain ──
type Item = { url: string, channel: string, body: string }
local queues: { [string]: { Item } } = {} -- keyed by url
local draining: { [string]: boolean } = {}
local httpDisabledWarned = false
-- Set by the BindToClose handler: drains send faster and stop retrying a disabled HTTP.
local closing = false
local CLOSE_INTERVAL : number = 0.5 -- seconds between sends per URL while the server shuts down
local CLOSE_DEADLINE : number = 25  -- seconds BindToClose waits for the queues (Roblox kills at ~30)

local function reportFail(channel: string, reason: string): ()
	Webhook.OnError:Fire(channel, reason)
	warn(`[Webhook] '{channel}' dropped: {reason}`)
end

local function isHttpDisabled(err: string?): boolean
	return typeof(err) == "string" and string.find(err, "not enabled", 1, true) ~= nil
end

local function warnHttpDisabled(): ()
	if not httpDisabledWarned then
		httpDisabledWarned = true
		warn("[Webhook] HTTP requests are not enabled (Game Settings → Security). Messages stay queued and are retried.")
	end
end

local function drain(url: string): ()
	if draining[url] then return end
	draining[url] = true
	task.spawn(function()
		while true do
			local q = queues[url]
			if not q or #q == 0 then break end
			local item = table.remove(q, 1) :: Item
			local maxR = rate("MaxRetries", Config.Webhook.RateLimit.MaxRetries, 3)
			local attempt = 0
			local httpOff = false
			while true do
				attempt += 1
				local ok, status, retryAfter, err = transport(item.url, item.body)
				if ok then
					Webhook.OnSend:Fire(item.channel, true)
					break
				end
				if status == nil and isHttpDisabled(err) then
					-- HTTP is off: keep the message (front of its queue) and retry later.
					warnHttpDisabled()
					table.insert(q, 1, item)
					httpOff = true
					break
				end
				local canRetry = attempt <= maxR
				if status == 429 and retryAfter and canRetry then
					task.wait(math.clamp(retryAfter, 0, 60))
				elseif status ~= nil and canRetry then
					task.wait(math.min(attempt, 10)) -- linear backoff on other non-2xx
				else
					reportFail(item.channel, err or ("http_" .. tostring(status)))
					break
				end
			end
			if httpOff then
				if closing then
					break -- nothing can be sent during shutdown
				end
				-- Short waits, so a shutdown (closing) ends the wait at once instead of
				-- holding game:BindToClose for the whole HttpOffRetry.
				local retryAt = os.clock() + math.max(1, rate("HttpOffRetry", Config.Webhook.RateLimit.HttpOffRetry, 30))
				while not closing and os.clock() < retryAt do
					task.wait(0.25)
				end
				if closing then
					break -- HTTP was off a moment ago: do not hold the shutdown
				end
			elseif closing then
				task.wait(math.min(CLOSE_INTERVAL, rate("MinInterval", Config.Webhook.RateLimit.MinInterval, 2)))
			else
				task.wait(rate("MinInterval", Config.Webhook.RateLimit.MinInterval, 2))
			end
		end
		draining[url] = false
	end)
end

-- Number of messages still waiting in every queue.
local function pendingCount(): number
	local n = 0
	for _, q in pairs(queues) do
		n += #q
	end
	return n
end

-- game:BindToClose: deliver what is still queued (faster than MinInterval) until
-- the queues are empty or CLOSE_DEADLINE passes. With HTTP disabled nothing can be sent:
-- a drain waiting for HTTP to come back stops within 0.25 s, so the shutdown is not held.
local function flushOnClose(): ()
	closing = true
	for url, q in pairs(queues) do
		if #q > 0 then
			drain(url)
		end
	end
	local deadline = os.clock() + CLOSE_DEADLINE
	while os.clock() < deadline do
		local busy = false
		for _, d in pairs(draining) do
			if d then busy = true; break end
		end
		if not busy then break end
		task.wait(0.1)
	end
	local left = pendingCount()
	if left > 0 then
		warn(`[Webhook] server closing: {left} queued message(s) not delivered`)
	end
end

local function enqueue(url: string, channel: string, payload: any): boolean
	if not enabled() then
		return false
	end
	if typeof(url) ~= "string" or #url == 0 then
		return false
	end
	local okEnc, body = pcall(function() return HttpService:JSONEncode(payload) end)
	if not okEnc then
		Webhook.OnError:Fire(channel, "json_encode_failed")
		return false
	end
	local q = queues[url]
	if not q then q = {}; queues[url] = q end
	table.insert(q, { url = url, channel = channel, body = body })
	local cap = rate("MaxQueue", Config.Webhook.RateLimit.MaxQueue, 100)
	while #q > cap do
		local dropped = table.remove(q, 1) :: Item -- drop oldest
		Webhook.OnError:Fire(dropped.channel, "queue_full")
	end
	drain(url)
	return true
end

-- ── Public send API ──

-- Set (or, with nil / "", remove) the URL of a channel from a server Script. It wins
-- over Config.Webhook.Channels and is never replicated. Returns false (and warns)
-- for a bad name or a URL that does not start with http:// or https://.
function Webhook.SetChannel(channel: string, url: string?): boolean
	if typeof(channel) ~= "string" or #channel == 0 then
		warn("[Webhook] SetChannel: the channel name must be a non-empty string")
		return false
	end
	if url == nil or url == "" then
		runtimeChannels[channel] = nil
		return true
	end
	if typeof(url) ~= "string" or not (string.match(url, "^https?://") :: string?) then
		warn(`[Webhook] SetChannel('{channel}'): the URL must start with https://`)
		return false
	end
	runtimeChannels[channel] = url
	return true
end

function Webhook.SendUrl(url: string, payload: any): boolean
	return enqueue(url, "(url)", payload)
end

function Webhook.Send(channel: string, payload: any): boolean
	local url = channelUrl(channel)
	if not url then
		return false
	end
	return enqueue(url, channel, payload)
end

function Webhook.IsConfigured(channel: string): boolean
	return enabled() and channelUrl(channel) ~= nil
end

-- ── Discord helpers ──

local function colorToInt(c: any): number?
	if typeof(c) == "number" then
		return math.floor(c)
	end
	if typeof(c) == "Color3" then
		return math.floor(c.R * 255 + 0.5) * 65536
			+ math.floor(c.G * 255 + 0.5) * 256
			+ math.floor(c.B * 255 + 0.5)
	end
	return nil
end

export type EmbedOpts = {
	title: string?, description: string?, url: string?,
	color: (number | Color3)?,
	fields: { { name: any, value: any, inline: boolean? } }?,
}

-- A Discord embed object, ready to JSON-encode (what Embed returns). Embed only
-- fills the first five fields; set the others on the returned table.
export type Embed = {
	title: string?, description: string?, url: string?,
	color: number?,
	fields: { { name: string, value: string, inline: boolean } }?,
	timestamp: string,
	footer: { text: string, icon_url: string? }?,
	author: { name: string, url: string?, icon_url: string? }?,
	image: { url: string }?,
	thumbnail: { url: string }?,
}

function Webhook.Embed(opts: EmbedOpts): Embed
	local o: any = opts or {}
	local embed: any = {}
	if o.title then embed.title = tostring(o.title) end
	if o.description then embed.description = tostring(o.description) end
	if o.url then embed.url = tostring(o.url) end
	local col = colorToInt(o.color)
	if col then embed.color = col end
	if o.fields then
		local fields = {}
		for _, f in ipairs(o.fields) do
			table.insert(fields, {
				name = tostring(f.name),
				value = tostring(f.value),
				inline = f.inline == true,
			})
		end
		embed.fields = fields
	end
	embed.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
	return embed
end

export type DiscordOpts = {
	content: string?, username: string?,
	title: string?, description: string?, url: string?,
	color: (number | Color3)?,
	fields: { { name: any, value: any, inline: boolean? } }?,
}

function Webhook.Discord(channel: string, opts: DiscordOpts): boolean
	local o: any = opts or {}
	local payload: any = {}
	if o.content then payload.content = tostring(o.content) end
	payload.username = o.username or flag("Username", Config.Webhook.Username or "Gaxia")
	if o.title or o.description or o.color or o.fields or o.url then
		payload.embeds = { Webhook.Embed(o) }
	end
	return Webhook.Send(channel, payload)
end

-- ── Auto-reports (zero-wiring) — wired in Start ──
local RED, GREEN, ORANGE = 0xE74C3C, 0x2ECC71, 0xE67E22

-- The channel of a Config.Webhook.AutoReport source ("Bans", "AntiCheat", "Guild"),
-- if it has a URL right now. Read when the event fires, never cached at Start.
local function autoChannel(source: string): string?
	local ch: any = Config.Webhook.AutoReport[source]
	if typeof(ch) == "string" and channelUrl(ch) then
		return ch
	end
	return nil
end

local function autoSubscribe(): ()
	local BanService: BanApi? = Lifecycle.Find("Ban")
	local AntiCheat: AntiCheatApi? = Lifecycle.Find("AntiCheat")
	local GuildService: GuildApi? = Lifecycle.Find("Guild")

	if BanService then
		BanService.OnBan:Connect(function(userId: number, ban: any)
			local banCh = autoChannel("Bans")
			if not banCh then return end
			ban = ban or {}
			local duration = if ban.expiresAt
				then string.format("temp (until %d)", ban.expiresAt)
				else "permanent"
			Webhook.Discord(banCh, {
				title = "🔨 Player Banned",
				color = RED,
				fields = {
					{ name = "UserId", value = tostring(userId), inline = true },
					{ name = "Duration", value = duration, inline = true },
					{ name = "Reason", value = ban.reason or "—", inline = false },
				},
			})
		end)
		BanService.OnUnban:Connect(function(userId: number)
			local banCh = autoChannel("Bans")
			if not banCh then return end
			Webhook.Discord(banCh, {
				title = "✅ Player Unbanned",
				color = GREEN,
				fields = { { name = "UserId", value = userId, inline = true } },
			})
		end)
	end

	if AntiCheat then
		AntiCheat.OnAction:Connect(function(player: any, reason: string, kind: string)
			-- "observe" = would have been "hard" but Config.AntiCheat.Enforce is false.
			if kind ~= "hard" and kind ~= "observe" then return end
			local acCh = autoChannel("AntiCheat")
			if not acCh then return end
			Webhook.Discord(acCh, {
				title = if kind == "observe" then "👁️ AntiCheat (observe mode — not enforced)" else "⚠️ AntiCheat Action",
				color = ORANGE,
				fields = {
					{ name = "Player", value = (typeof(player) == "Instance" and player.Name or tostring(player)), inline = true },
					{ name = "Kind", value = kind :: string, inline = true },
					{ name = "Reason", value = reason or "—", inline = false },
				},
			})
		end)
	end

	-- ── Guild auto-report (Phase 26 · Social) ──
	-- Sends only while a Guild channel has a URL. (This used to touch GaxiaServer.Guild
	-- unconditionally, which started GuildService as a side effect; Guild is in the
	-- default Features, and otherwise Features decides whether it runs.)
	if GuildService then
		GuildService.OnCreate:Connect(function(guildId: string, ownerUserId: number)
			local guildChannel = autoChannel("Guild")
			if not guildChannel then return end
			Webhook.Discord(guildChannel, {
				title = "Guild created",
				description = `**{guildId}** by user {ownerUserId}`,
				color = Color3.fromRGB(46, 204, 113),
			})
		end)
		GuildService.OnDisband:Connect(function(guildId: string, byUserId: number)
			local guildChannel = autoChannel("Guild")
			if not guildChannel then return end
			Webhook.Discord(guildChannel, {
				title = "Guild disbanded",
				description = `**{guildId}** by user {byUserId}`,
				color = Color3.fromRGB(231, 76, 60),
			})
		end)
		GuildService.OnRoleChange:Connect(function(guildId: string, userId: number, newRole: string)
			local guildChannel = autoChannel("Guild")
			if newRole == "Owner" and guildChannel then
				Webhook.Discord(guildChannel, {
					title = "Guild ownership transferred",
					description = `**{guildId}** → user {userId}`,
					color = Color3.fromRGB(241, 196, 15),
				})
			end
		end)
	end
end

Lifecycle.Define(Webhook, {
	Name = "Webhook",
	Needs = {},
	Start = function()
		game:BindToClose(flushOnClose)
		autoSubscribe()
	end,
})

return Webhook
