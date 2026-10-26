# Discord webhooks and analytics

> Your Discord channel gets a message for every ban, every anti-cheat action and every player who leaves with anti-cheat flags, and every Coins change, level-up, quest and session is sent to Roblox Analytics.

**Use this when** the user asks for: "Discord webhook", "send a message to Discord", "log bans to Discord", "anti-cheat logs", "analytics", "track events", "funnel", "Roblox analytics dashboard", "log player actions" (ไทย: "เว็บฮุค", "ส่งข้อความเข้าดิสคอร์ด", "แจ้งเตือนดิสคอร์ด", "log การแบน", "log กันโกง", "เก็บสถิติ", "analytics", "ติดตามพฤติกรรมผู้เล่น").
**Packages:** `Webhook` (Steps 1–2), `Journal` (it also installs `AntiCheat`; Step 2), `Analytics` (Step 3). `Ban` is optional in Step 2. Each script stops with a clear message if its package is missing.
**You will create:** the Scripts `ServerScriptService/WebhookSetup`, `ServerScriptService/ModerationReports` and `ServerScriptService/AnalyticsSetup`.

Steps 1–2 (Discord) and Step 3 (analytics) are independent. Do only what the user asked for.

How it works:

- **Webhook** sends JSON to a URL from the **server only**. A *channel* is a name (`"Alerts"`) for one secret URL. `Webhook.Discord(channel, {...})` builds a Discord message; `Webhook.Send(channel, table)` sends any JSON.
- Sending never blocks your code: messages wait in a queue per URL, one every 2 seconds, with retries (also after Discord's "too many requests"). At most 100 wait; older ones are dropped.
- HTTP must be on: **Game Settings → Security → Allow HTTP Requests**. When it is off, Output shows `[Webhook] HTTP requests are not enabled ... Webhooks are off.` once, and nothing is sent.
- The URL is a password: anyone who has it can post in your channel. Keep it in a server Script. Never in a LocalScript, ReplicatedStorage or a client remote.
- **Journal** remembers every AntiCheat flag and action in this server (`Journal.GetForPlayer`, `Journal.GetRecent`) and passes each one to a *sink* function you set.
- **Analytics** sends events to one sink function. It already tracks `currency_change` (Economy), `level_up` (Level) and `quest_complete` (Quest) when those packages are installed. You add your own with `Analytics.Track`.

## Step 1 — Connect a Discord channel

In Discord: channel settings → **Integrations** → **Webhooks** → **New Webhook** → **Copy Webhook URL**.

Create a **Script** in **ServerScriptService** named **WebhookSetup**. Paste this whole block into it, then paste the URL into `ALERTS_URL`:

```lua
-- Script: ServerScriptService/WebhookSetup
local RunService = game:GetService("RunService")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Webhook"), "WebhookSetup needs the Webhook package: install it (playbooks/start/01-install-packages.md)")

local Webhook = GaxiaServer.Webhook

-- Paste your Discord webhook URL between the quotes. This Script runs only on the server.
local ALERTS_URL = ""

-- The channel "Alerts" = ALERTS_URL. Kept in your script, so Gaxia updates do not remove it.
GaxiaServer.Config.Webhook.Channels.Alerts = ALERTS_URL

Webhook.OnSend:Connect(function(channel: string, _ok: boolean)
	print(`[WebhookSetup] delivered to {channel}`)
end)
Webhook.OnError:Connect(function(channel: string, reason: string)
	print(`[WebhookSetup] {channel} failed: {reason}`)
end)

if not Webhook.IsConfigured("Alerts") then
	print("[WebhookSetup] paste your Discord webhook URL into ALERTS_URL")
elseif RunService:IsStudio() then
	-- A test message, only when you press Play in Studio (not from every live server).
	Webhook.Discord("Alerts", {
		title = "Webhook test",
		description = "Hello from Roblox Studio",
		color = Color3.fromRGB(46, 204, 113),
	})
end

print("[WebhookSetup] ready")
```

What it does: it registers the channel `Alerts`. In Studio it sends one green test message.

## Step 2 — Report bans and anti-cheat to Discord

Create a **Script** in **ServerScriptService** named **ModerationReports**:

```lua
-- Script: ServerScriptService/ModerationReports
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Webhook"), "ModerationReports needs the Webhook package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Journal"), "ModerationReports needs the Journal package: install it (playbooks/start/01-install-packages.md)")

local Webhook = GaxiaServer.Webhook
local Journal = GaxiaServer.Journal

local CHANNEL = "Alerts" -- set up in WebhookSetup

-- Every AntiCheat flag and action goes through this function.
Journal.SetSink(function(entry)
	print(`[ModerationReports] {entry.name}: {entry.reason} ({entry.severity})`)
	-- Only actions go to Discord. "observe" = it would kick, but enforce mode is off.
	if entry.action and (entry.kind == "hard" or entry.kind == "observe") then
		Webhook.Discord(CHANNEL, {
			title = if entry.kind == "observe" then "AntiCheat (observe only)" else "AntiCheat action",
			color = Color3.fromRGB(230, 126, 34),
			fields = {
				{ name = "Player", value = `{entry.name} ({entry.userId})`, inline = true },
				{ name = "Reason", value = entry.reason, inline = true },
			},
		})
	end
end)

-- When a flagged player leaves, send how many flags they got in this server.
Players.PlayerRemoving:Connect(function(player: Player)
	local entries = Journal.GetForPlayer(player)
	if #entries > 0 then
		Webhook.Discord(CHANNEL, {
			title = "Player left with anti-cheat flags",
			description = `{player.Name} ({player.UserId}): {#entries} flag(s), last: {entries[#entries].reason}`,
			color = Color3.fromRGB(241, 196, 15),
		})
	end
end)

-- Bans (only when the Ban package is installed).
if GaxiaServer.IsInstalled("Ban") then
	GaxiaServer.Ban.OnBan:Connect(function(userId: number, ban)
		Webhook.Discord(CHANNEL, {
			title = "Player banned",
			color = Color3.fromRGB(231, 76, 60),
			fields = {
				{ name = "UserId", value = tostring(userId), inline = true },
				{ name = "Until", value = if ban.expiresAt then os.date("!%Y-%m-%d %H:%M UTC", ban.expiresAt) else "permanent", inline = true },
				{ name = "Reason", value = ban.reason, inline = false },
			},
		})
	end)
	GaxiaServer.Ban.OnUnban:Connect(function(userId: number)
		Webhook.Discord(CHANNEL, { title = "Player unbanned", description = `UserId {userId}`, color = Color3.fromRGB(46, 204, 113) })
	end)
end

print("[ModerationReports] ready")
```

What it does: anti-cheat actions, bans and unbans become Discord messages. Every flag is also one Output line.

## Step 3 — Send events to Roblox Analytics

Create a **Script** in **ServerScriptService** named **AnalyticsSetup**:

```lua
-- Script: ServerScriptService/AnalyticsSetup
local Players = game:GetService("Players")
local AnalyticsService = game:GetService("AnalyticsService")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Analytics"), "AnalyticsSetup needs the Analytics package: install it (playbooks/start/01-install-packages.md)")

local Analytics = GaxiaServer.Analytics

-- Every event (yours and the automatic ones) goes through this function.
Analytics.SetSink(function(player: Player, event: string, props: { [string]: any })
	print(`[AnalyticsSetup] {player.Name} {event}`)
	-- pcall: an analytics problem must never break the game.
	pcall(function()
		if event ~= "currency_change" then
			AnalyticsService:LogCustomEvent(player, event)
		elseif props.kind ~= "transfer" and typeof(props.delta) == "number" and props.delta ~= 0 then
			-- Coins / Gems changes go to the Economy dashboard. A transfer was already
			-- reported as one "spend" and one "add", so it is skipped here.
			local flow = if props.delta > 0 then Enum.AnalyticsEconomyFlowType.Source else Enum.AnalyticsEconomyFlowType.Sink
			AnalyticsService:LogEconomyEvent(player, flow, props.currency, math.abs(props.delta), props.balance, Enum.AnalyticsEconomyTransactionType.Gameplay.Name)
		end
	end)
end)

-- Your own events: one when a player joins, one with the minutes played when they leave.
local joinedAt: { [Player]: number } = {}

Players.PlayerAdded:Connect(function(player: Player)
	joinedAt[player] = os.time()
	Analytics.Track(player, "session_start")
end)
Players.PlayerRemoving:Connect(function(player: Player)
	local minutes = math.floor((os.time() - (joinedAt[player] or os.time())) / 60)
	joinedAt[player] = nil
	Analytics.Track(player, "session_end", { minutes = minutes })
end)

print("[AnalyticsSetup] ready")
```

What it does: Coins changes appear in the Creator Dashboard (**Analytics → Economy**), everything else under **Custom events**.

## Check that it works

1. Turn on **Game Settings → Security → Allow HTTP Requests** (the place must be published).
2. Press **Play** in Studio.
3. Output shows `[WebhookSetup] ready`, `[ModerationReports] ready`, `[AnalyticsSetup] ready`, and no red errors.
4. Without a URL, Output shows `[WebhookSetup] paste your Discord webhook URL into ALERTS_URL`. With a URL, a green **Webhook test** message appears in Discord and Output shows `[WebhookSetup] delivered to Alerts`.
5. Output shows `[AnalyticsSetup] <YourName> session_start`. Give yourself Coins (any script from [currency-and-leaderstats](currency-and-leaderstats.md)): Output shows `[AnalyticsSetup] <YourName> currency_change`.
6. Ban test (Ban package, admin role): `/ban <player> test` in chat posts **Player banned** in Discord.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| The webhook URL in a LocalScript, a ModuleScript in ReplicatedStorage, or a StringValue | Only in a server Script (`WebhookSetup`) | Everything the client can see can be copied; anyone could spam your Discord. |
| A client remote that sends a webhook with text from the player | The server decides what to send | Players would use your game to spam or post bad words. |
| Editing `Config/Webhook.lua` inside `Gaxia_Packages_Server` | Set the URL in `WebhookSetup` (Step 1) | Install / Update replaces the package and your URL is lost. |
| Expecting the built-in auto-reports (`BanReports`, `GuildEvents`) to work after Step 1 | Use Step 2 | The built-in reports read their channels once at boot, before your Script can set a URL. |
| `Webhook.Discord("alerts", ...)` | `Webhook.Discord("Alerts", ...)` | Channel names are case-sensitive. An unknown channel returns `false` and sends nothing. |
| A message for every Coins change or every second | Only rare, important events | One message per 2 seconds per URL; at most 100 wait, older ones are dropped. |
| `HttpService:PostAsync` to Discord yourself | `Webhook.Discord` / `Webhook.Send` | The queue handles Discord's rate limits and retries. |
| Testing with HTTP requests off | Turn on **Allow HTTP Requests** | Webhook stops after the first failure and warns once. |
| `Analytics.Track(player, "Bought Sword!!")` | Short names like `"item_bought"`, details in the props | Roblox Analytics groups custom events by name; keep few, stable names. |
| Forgetting that `SetSink` replaces the default | Print inside your sink (Step 3) | The default sink printed every event. Yours is now the only one. |
| `Analytics.Track` from a LocalScript | Track on the server | Analytics is server only. The client cannot require `Gaxia_Packages_Server`. |

## Change it

- A second channel (for example shop logs): in `WebhookSetup`, copy the `Channels.Alerts = ALERTS_URL` line, change `Alerts` to `Shop` and put the second URL there. Send with `Webhook.Discord("Shop", { content = "..." })`.
- Plain text: `Webhook.Discord("Alerts", { content = "Server is restarting" })`. Another bot name: add `username = "Moderation"`.
- Any JSON service (not Discord): `Webhook.Send("Alerts", { event = "test", value = 1 })`.
- Guild news: connect `GaxiaServer.Guild.OnCreate` / `OnDisband` like the ban reports in Step 2 ([social](social.md)).
- Recent anti-cheat history in this server: `Journal.GetRecent(20)` returns the last 20 entries (`name`, `reason`, `severity`, `action`, `time`). Admins can also type `/acflags <player>` ([anticheat-and-bans](anticheat-and-bans.md)).
- Track your own event with details: `Analytics.Track(player, "egg_hatched", { pet = "pet_Cat" })`.
- Listen to every event without replacing the sink: `Analytics.OnEvent:Connect(function(player, event, props) ... end)`.
- Turn all webhooks off at runtime (for example, an admin switch): `GaxiaServer.EConfig.Set("Webhook.Enabled", false)`.

## See also

- [API: Webhook](../api/Webhook.md) · [API: Journal](../api/Journal.md) · [API: Analytics](../api/Analytics.md) · [API: Ban](../api/Ban.md)
- [Anti-cheat and bans](anticheat-and-bans.md) · [Admin and chat commands](admin-and-chat-commands.md) · [Config and flags](config-and-flags.md)
