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
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local HttpService       = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

-- ── Lazy server (Config + EConfig + Ban + AntiCheat) ──
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

-- ── Effective config (call-time: Config default <- runtime Flag override) ──
local function wcfg(): any
	return (server().Config or {}).Webhook or {}
end
local function flag(key: string, fallback: any): any
	-- key is the dotted path under "Webhook." e.g. flag("Enabled", true)
	return server().EConfig.Get("Webhook." .. key, fallback)
end
local function enabled(): boolean
	return flag("Enabled", wcfg().Enabled ~= false) == true
end
local function rate(key: string, fallback: number): number
	local rl = wcfg().RateLimit or {}
	return flag("RateLimit." .. key, rl[key] or fallback)
end
local function channelUrl(channel: string): string?
	local url = (wcfg().Channels or {})[channel]
	if typeof(url) == "string" and #url > 0 then
		return url
	end
	return nil
end

-- ── Module ──
local Webhook = {}

Webhook.OnSend = Signal.new()   -- (channel: string, ok: boolean)
Webhook.OnError = Signal.new()  -- (channel: string, reason: string)

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
			local maxR = rate("MaxRetries", 3)
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
			task.wait(rate("MinInterval", 2))
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
	local cap = rate("MaxQueue", 100)
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

function Webhook.Embed(opts: EmbedOpts): any
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
	payload.username = o.username or flag("Username", wcfg().Username or "Gaxia")
	if o.title or o.description or o.color or o.fields or o.url then
		payload.embeds = { Webhook.Embed(o) }
	end
	return Webhook.Send(channel, payload)
end

-- ── Auto-reports (zero-wiring) — deferred off the load path ──
local RED, GREEN, ORANGE = 0xE74C3C, 0x2ECC71, 0xE67E22

local function autoChannel(key: string): string?
	local ch = (wcfg().AutoReport or {})[key]
	if typeof(ch) == "string" and channelUrl(ch) then
		return ch
	end
	return nil
end

local subscribed = false
local function autoSubscribe(): ()
	if subscribed then return end
	subscribed = true
	local s = server()

	local banCh = autoChannel("Bans")
	if banCh and s.Ban then
		if s.Ban.OnBan then
			s.Ban.OnBan:Connect(function(userId: number, ban: any)
				ban = ban or {}
				local duration = if ban.expiresAt
					then string.format("temp (until %d)", ban.expiresAt)
					else "permanent"
				Webhook.Discord(banCh, {
					title = "🔨 Player Banned",
					color = RED,
					fields = {
						{ name = "UserId", value = userId, inline = true },
						{ name = "Duration", value = duration, inline = true },
						{ name = "Reason", value = ban.reason or "—" },
					},
				})
			end)
		end
		if s.Ban.OnUnban then
			s.Ban.OnUnban:Connect(function(userId: number)
				Webhook.Discord(banCh, {
					title = "✅ Player Unbanned",
					color = GREEN,
					fields = { { name = "UserId", value = userId, inline = true } },
				})
			end)
		end
	end

	local acCh = autoChannel("AntiCheat")
	if acCh and s.AntiCheat and s.AntiCheat.OnAction then
		s.AntiCheat.OnAction:Connect(function(player: any, reason: string, kind: string)
			if kind ~= "hard" then return end
			Webhook.Discord(acCh, {
				title = "⚠️ AntiCheat Action",
				color = ORANGE,
				fields = {
					{ name = "Player", value = (typeof(player) == "Instance" and player.Name or tostring(player)), inline = true },
					{ name = "Kind", value = kind, inline = true },
					{ name = "Reason", value = reason or "—" },
				},
			})
		end)
	end

	-- ── Guild auto-report (Phase 26 · Social) ──
	-- Placed LAST: `s.Guild` resolution goes through the GaxiaServer __index proxy,
	-- which may trigger a require on first access. Bans + AntiCheat hookups are
	-- already done above, so even if this line yields the earlier subscribers are live.
	local Guild = s.Guild
	if Guild then
		local guildChannel = autoChannel("Guild")
		if guildChannel and channelUrl(guildChannel) then
			if Guild.OnCreate then
				Guild.OnCreate:Connect(function(guildId: string, ownerUserId: number)
					Webhook.Discord(guildChannel, {
						title = "Guild created",
						description = `**{guildId}** by user {ownerUserId}`,
						color = Color3.fromRGB(46, 204, 113),
					})
				end)
			end
			if Guild.OnDisband then
				Guild.OnDisband:Connect(function(guildId: string, byUserId: number)
					Webhook.Discord(guildChannel, {
						title = "Guild disbanded",
						description = `**{guildId}** by user {byUserId}`,
						color = Color3.fromRGB(231, 76, 60),
					})
				end)
			end
			if Guild.OnRoleChange then
				Guild.OnRoleChange:Connect(function(guildId: string, userId: number, newRole: string)
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
	end
end

-- Run once, after the package + Ban/AntiCheat are resolvable. task.spawn keeps it
-- off the loader's no-yield __index path (matching AnalyticsService).
task.spawn(autoSubscribe)

return Webhook
