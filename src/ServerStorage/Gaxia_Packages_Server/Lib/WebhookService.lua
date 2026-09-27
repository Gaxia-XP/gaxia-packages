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
-- (ServerStorage, never replicated) and are NEVER driven by client RemoteEvents
-- (a client-triggered webhook is an abuse vector).
--
-- Access  : Gaxia.Webhook  (server)
--   Gaxia.Webhook.Discord("BanReports", { title = "Hi", description = "world", color = Color3.fromRGB(231,76,60) })
--   Gaxia.Webhook.Send("ShopStock", { content = "Stock updated" })   -- raw JSON
--   Gaxia.Webhook.SendUrl("https://discord.com/api/webhooks/...", { content = "ad-hoc" })
--
-- Lifecycle: Start wires the auto-reports (Ban, AntiCheat, Guild signals) for
--            each Config.Webhook.AutoReport source whose channel has a URL.
--            Subscribing never starts those services (Features decides).
-- ─────────────────────────────────────────────────────────────
local HttpService       = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Dependencies ──
local Signal       = require(ReplicatedStorage.Gaxia_Packages.Shared.Signal)
local Lifecycle    = require(script.Parent.ServiceLifecycle)
local Config       = require(script.Parent.Parent.Config)
local EConfig      = require(script.Parent.EffectiveConfig)
local BanService   = require(script.Parent.BanService)
local GuildService = require(script.Parent.GuildService)
local AntiCheat    = require(script.Parent.Parent.AntiCheat)

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
local function channelUrl(channel: string): string?
	-- Channels maps channel name -> secret URL (a free-form map in Config).
	local url = Config.Webhook.Channels[channel]
	if typeof(url) == "string" and #url > 0 then
		return url
	end
	return nil
end

-- ── Module ──
local Webhook = {}

-- (channel, ok) after a 2xx delivery; channel is "(url)" for SendUrl
Webhook.OnSend = Signal.new() :: Signal.Signal<string, boolean>
-- (channel, reason) when a payload is dropped (JSON encode failure, retries exhausted)
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

local function reportFail(channel: string, reason: string): ()
	Webhook.OnError:Fire(channel, reason)
	if string.find(reason, "not enabled", 1, true) then
		if not httpDisabledWarned then
			httpDisabledWarned = true
			warn("[Webhook] HTTP requests are not enabled (Game Settings → Security). Webhooks are off.")
		end
	else
		warn(`[Webhook] '{channel}' dropped: {reason}`)
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
			while true do
				attempt += 1
				local ok, status, retryAfter, err = transport(item.url, item.body)
				if ok then
					Webhook.OnSend:Fire(item.channel, true)
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
			task.wait(rate("MinInterval", Config.Webhook.RateLimit.MinInterval, 2))
		end
		draining[url] = false
	end)
end

local function enqueue(url: string, channel: string, payload: any): boolean
	if not enabled() or httpDisabledWarned then
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
		table.remove(q, 1) -- drop oldest
	end
	drain(url)
	return true
end

-- ── Public send API ──

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

-- `ch` is a Config.Webhook.AutoReport entry: the channel, if it has a URL.
local function autoChannel(ch: string?): string?
	if typeof(ch) == "string" and channelUrl(ch) then
		return ch
	end
	return nil
end

local function autoSubscribe(): ()
	local banCh = autoChannel(Config.Webhook.AutoReport.Bans)
	if banCh then
		BanService.OnBan:Connect(function(userId: number, ban: any)
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
			Webhook.Discord(banCh, {
				title = "✅ Player Unbanned",
				color = GREEN,
				fields = { { name = "UserId", value = userId, inline = true } },
			})
		end)
	end

	local acCh = autoChannel(Config.Webhook.AutoReport.AntiCheat)
	if acCh then
		AntiCheat.OnAction:Connect(function(player: any, reason: string, kind: string)
			-- "observe" = would have been "hard" but Config.AntiCheat.Enforce is false.
			if kind ~= "hard" and kind ~= "observe" then return end
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
	-- Only when a Guild channel is configured. (This used to touch GaxiaServer.Guild
	-- unconditionally, which started GuildService as a side effect; Guild is in the
	-- default Features, and otherwise Features decides whether it runs.)
	local guildChannel = autoChannel(Config.Webhook.AutoReport.Guild)
	if guildChannel then
		GuildService.OnCreate:Connect(function(guildId: string, ownerUserId: number)
			Webhook.Discord(guildChannel, {
				title = "Guild created",
				description = `**{guildId}** by user {ownerUserId}`,
				color = Color3.fromRGB(46, 204, 113),
			})
		end)
		GuildService.OnDisband:Connect(function(guildId: string, byUserId: number)
			Webhook.Discord(guildChannel, {
				title = "Guild disbanded",
				description = `**{guildId}** by user {byUserId}`,
				color = Color3.fromRGB(231, 76, 60),
			})
		end)
		GuildService.OnRoleChange:Connect(function(guildId: string, userId: number, newRole: string)
			if newRole == "Owner" then
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
	Start = autoSubscribe,
})

return Webhook
