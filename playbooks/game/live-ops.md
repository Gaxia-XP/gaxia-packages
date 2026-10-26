# Daily rewards, timed events, mail and global leaderboards

> Players get a daily login reward with a streak, a timed "double coins" event runs on a schedule, an inbox holds gifts to claim, and a global top-10 board ranks Coins across all servers.

**Use this when** the user asks for: "daily reward", "login streak", "timed event", "weekend event", "double coins event", "limited-time event", "mail", "inbox", "send a gift to players", "compensation", "global leaderboard", "top 10 players" (ไทย: "รางวัลรายวัน", "ล็อกอินรายวัน", "อีเวนต์", "อีเวนต์จำกัดเวลา", "อีเวนต์เงินx2", "กล่องจดหมาย", "ส่งของขวัญให้ผู้เล่น", "ชดเชย", "ลีดเดอร์บอร์ดโลก", "อันดับ top 10").
**Packages:** `DailyReward`, `Event`, `Mail`, `Leaderboard`, `Economy` (it also installs `Data`). Each script stops with a clear message if its package is missing.
**You will create:** the Scripts `ServerScriptService/DailyRewards`, `ServerScriptService/TimedEvents`, `ServerScriptService/Mailbox`, `ServerScriptService/CoinsLeaderboard` and the LocalScript `StarterPlayer/StarterPlayerScripts/MailButton`.

The four steps are independent. Do only the steps the user asked for.

How it works:

- **DailyReward** saves the last claim time and the streak. `DailyReward.Claim` works once per 24 hours. Claiming 24–48 hours after the last claim adds 1 to the streak; later resets it to 1. It returns the reward from your ladder; **your code gives it**.
- **Event** runs a clock on every server. `Event.Define` sets a start and end time (Unix seconds, UTC). `Event.OnEventStart` / `Event.OnEventEnd` fire once each, within 5 seconds. `Event.IsActive` answers "is it on now".
- **Mail** saves an inbox in the player's data. `Mail.Send` needs the player in this server with loaded data. `Mail.Claim` returns the attachments once; **your code gives them**.
- **Leaderboard** writes scores to an OrderedDataStore (`Leaderboard.Update`) and reads the top N (`Leaderboard.GetTop`, cached 60 seconds).

## Step 1 — Daily login reward with a streak

Create a **Script** in **ServerScriptService** named **DailyRewards**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/DailyRewards
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("DailyReward"), "DailyRewards needs the DailyReward package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Economy"), "DailyRewards needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data
local DailyReward = GaxiaServer.DailyReward
local Economy = GaxiaServer.Economy

-- Day 1 to day 7. After day 7 the ladder starts again at day 1 (Cycle = true).
DailyReward.DefineLadder({
	{ Coins = 100 },
	{ Coins = 150 },
	{ Coins = 200 },
	{ Coins = 250 },
	{ Coins = 300 },
	{ Coins = 400 },
	{ Coins = 500, Gems = 10 },
}, { Cycle = true })

local function tryClaim(player: Player)
	-- Claim must never run before the data is loaded (it would "succeed" without saving).
	if not Data.IsLoaded(player) then
		return
	end
	local result, reason = DailyReward.Claim(player)
	if result == nil then
		local hours = math.ceil(DailyReward.GetTimeUntilNext(player) / 3600)
		print(`[DailyRewards] {player.Name} cannot claim: {reason}. Next claim in {hours} h`)
		return
	end
	-- result.reward is the ladder entry, for example { Coins = 100 }. Give every currency in it.
	for currency, amount in result.reward do
		Economy.Add(player, currency, amount)
	end
	print(`[DailyRewards] {player.Name} claimed day {result.day}, streak {result.streak}`)
end

local function onPlayerAdded(player: Player)
	if Data.WaitFor(player) == nil then
		return -- the player left before the data loaded
	end
	tryClaim(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[DailyRewards] ready")
```

What it does: when a player's data loads, it claims today's reward and adds the Coins/Gems.

## Step 2 — A timed event (double coins)

Create a **Script** in **ServerScriptService** named **TimedEvents**:

```lua
-- Script: ServerScriptService/TimedEvents
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Event"), "TimedEvents needs the Event package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Economy"), "TimedEvents needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Event = GaxiaServer.Event
local Economy = GaxiaServer.Economy

-- Connect first, then define. Both fire once per server, also when it starts mid-event.
Event.OnEventStart:Connect(function(eventId: string, data: any)
	print(`[TimedEvents] {eventId} started, multiplier x{data.Multiplier}`)
end)
Event.OnEventEnd:Connect(function(eventId: string)
	print(`[TimedEvents] {eventId} ended`)
end)

-- For testing: starts now, lasts 10 minutes. For a real event use fixed UTC dates, for example
-- StartsAt = DateTime.fromUniversalTime(2026, 12, 24, 0, 0, 0).UnixTimestamp
local now = os.time()
Event.Define("DoubleCoins", {
	StartsAt = now,
	EndsAt = now + 10 * 60,
	Data = { Multiplier = 2 },
})

-- Ask the event anywhere on the server.
local function coinMultiplier(): number
	if Event.IsActive("DoubleCoins") then
		return Event.GetData("DoubleCoins").Multiplier
	end
	return 1
end

print("[TimedEvents] ready")

-- Example use: 5 Coins every 30 seconds, doubled during the event.
while true do
	task.wait(30)
	local amount = 5 * coinMultiplier()
	for _, player in Players:GetPlayers() do
		if Economy.Add(player, "Coins", amount) then
			print(`[TimedEvents] {player.Name} +{amount} Coins ({Event.GetTimeRemaining("DoubleCoins")} s of DoubleCoins left)`)
		end
	end
end
```

What it does: it defines one event window and doubles a Coins payout while the window is open.

## Step 3 — An inbox with claimable gifts

Create a **Script** in **ServerScriptService** named **Mailbox**:

```lua
-- Script: ServerScriptService/Mailbox
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Mail"), "Mailbox needs the Mail package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Economy"), "Mailbox needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Mail = GaxiaServer.Mail
local Economy = GaxiaServer.Economy

-- Client asks: "which mails can I claim?" Answer only ids and subjects.
Net.OnInvoke("MailList", function(player: Player)
	local list = {}
	if Data.IsLoaded(player) then
		for _, mail in Mail.GetMailbox(player) do
			if mail.attachments ~= nil and not mail.claimed then
				table.insert(list, { id = mail.id, subject = mail.subject })
			end
		end
	end
	return list
end, { rate = 2, burst = 4 })

-- Client asks: "claim this mail". Mail.Claim only works once per mail, on the player's own inbox.
Net.OnInvoke("MailClaim", function(player: Player, mailId: any): (boolean, string)
	if typeof(mailId) ~= "string" then
		return false, "Bad request"
	end
	if not Data.IsLoaded(player) then
		return false, "Your data is still loading"
	end
	local attachments, reason = Mail.Claim(player, mailId)
	if attachments == nil then
		return false, reason or "Cannot claim"
	end
	for currency, amount in attachments do -- attachments are { Coins = 250 } style tables
		Economy.Add(player, currency, amount)
	end
	print(`[Mailbox] {player.Name} claimed {mailId}`)
	return true, "Claimed"
end, { rate = 4, burst = 8 })

-- A welcome gift, sent once per player (remembered in the saved field GotWelcomeMail).
local function onPlayerAdded(player: Player)
	if Data.WaitFor(player) == nil then
		return
	end
	if Data.Get(player, "GotWelcomeMail") ~= true then
		Mail.Send(player, { Subject = "Welcome!", Body = "A gift to start.", From = "The Team", Attachments = { Coins = 250 } })
		Data.Set(player, "GotWelcomeMail", true)
	end
	print(`[Mailbox] {player.Name} has {Mail.GetUnreadCount(player)} unread mail`)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[Mailbox] ready")
```

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **MailButton**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/MailButton
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

local Net = Gaxia.Net

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MailGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local button = Instance.new("TextButton")
button.Name = "MailButton"
button.Size = UDim2.fromOffset(180, 44)
button.Position = UDim2.new(0, 10, 1, -150)
button.TextScaled = true
button.Text = "Mail"
button.Parent = screenGui

-- Ask the server for claimable mail and show how many.
local function refresh(): { any }
	local list = Net.InvokeServer("MailList")
	if typeof(list) ~= "table" then
		list = {} -- nil = request dropped (too many requests)
	end
	button.Text = `Mail ({#list})`
	return list
end

button.Activated:Connect(function()
	for _, mail in refresh() do
		local ok, message = Net.InvokeServer("MailClaim", mail.id)
		print(`[MailButton] {mail.subject}: {tostring(ok)} {tostring(message)}`)
	end
	refresh()
end)

print("[MailButton] ready")

-- Refresh every 10 seconds: new mail shows up without a click.
while true do
	refresh()
	task.wait(10)
end
```

What it does: the server sends a welcome mail with 250 Coins. The button shows `Mail (1)`; a click claims every gift.

## Step 4 — A global top-10 board

Create a **Script** in **ServerScriptService** named **CoinsLeaderboard**:

```lua
-- Script: ServerScriptService/CoinsLeaderboard
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Leaderboard"), "CoinsLeaderboard needs the Leaderboard package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Economy"), "CoinsLeaderboard needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data
local Leaderboard = GaxiaServer.Leaderboard
local Economy = GaxiaServer.Economy

local BOARD = "TopCoins_v1" -- the OrderedDataStore name; a new name starts an empty board
local UPDATE_SECONDS = 60
local TOP_COUNT = 10 -- at most 100

print("[CoinsLeaderboard] ready")

-- This loop never ends, so it is the last thing in the script.
while true do
	task.wait(UPDATE_SECONDS)
	-- 1. Send every loaded player's score. Scores must be whole numbers.
	for _, player in Players:GetPlayers() do
		if Data.IsLoaded(player) then
			Leaderboard.Update(BOARD, player.UserId, math.floor(Economy.Get(player, "Coins")))
		end
	end
	-- 2. Read the top list (all servers together).
	for _, entry in Leaderboard.GetTop(BOARD, TOP_COUNT) do
		print(`[CoinsLeaderboard] #{entry.rank} {entry.name or tostring(entry.userId)}: {entry.value}`)
	end
end
```

What it does: once a minute it saves each player's Coins to the board and prints the top 10.

## Check that it works

1. In **Game Settings → Security**, turn on **Enable Studio Access to API Services** (the place must be published). Without it, data does not save and Output shows `[LeaderboardService] Update failed …` warnings.
2. Press **Play**. Output shows `[DailyRewards] ready`, `[TimedEvents] ready`, `[Mailbox] ready`, `[MailButton] ready`, `[CoinsLeaderboard] ready`, and no red errors.
3. Daily: within a few seconds `[DailyRewards] <YourName> claimed day 1, streak 1`. Stop and **Play** again: `cannot claim: already claimed today. Next claim in 24 h`.
4. Event: within 5 seconds `[TimedEvents] DoubleCoins started, multiplier x2`. After 30 seconds `[TimedEvents] <YourName> +10 Coins (… s of DoubleCoins left)`.
5. Mail: `[Mailbox] <YourName> has 1 unread mail`. Within 10 seconds the button (bottom left) shows `Mail (1)`. Click it: `[Mailbox] <YourName> claimed mail_1`, `[MailButton] Welcome!: true Claimed`, and the button shows `Mail (0)`.
6. Leaderboard: after 60 seconds `[CoinsLeaderboard] #1 <YourName>: <your Coins>`.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `DailyReward.Claim(player)` in `PlayerAdded` right away | `Data.WaitFor(player)`, then check `Data.IsLoaded` | Before data loads, `Claim` returns a reward but saves nothing, so it can be claimed again. |
| Giving the reward in `DailyReward.OnClaim` **and** from the `Claim` result | Give it once, from the `Claim` result (Step 1) | Both run for every claim: the player gets it twice. |
| `Mail.Send` to a player whose data is not loaded, or who is in another server | Send after `Data.WaitFor(player)`, to players in this server | `Send` returns an id but the mail is lost. There is no offline delivery. |
| The client sends the reward amount to claim | The client sends only the mail id; the server gives `Mail.Claim`'s attachments | A cheater can send any amount. |
| Midnight Dec 24 in Thailand as `DateTime.fromUniversalTime(2026, 12, 24, 0, 0, 0)` | `DateTime.fromUniversalTime(2026, 12, 23, 17, 0, 0).UnixTimestamp` | Event times are UTC. Thailand is UTC+7: subtract 7 hours. |
| `Leaderboard.Update(...)` on every Coins change | Once per player per minute (Step 4) | OrderedDataStore writes are limited (about 60 + 10 × players per minute per server). Extra writes fail with a warning. |
| `Leaderboard.Update(BOARD, player.UserId, 12.5)` | `math.floor(value)` | OrderedDataStore stores whole numbers only; the write fails. |
| `Leaderboard.GetTop(BOARD, 500)` | 100 or fewer | More than 100 fails and returns an empty list. |
| Expecting a new score on the board at once | Wait up to 60 seconds | `GetTop` is cached for 60 seconds on each server (`CacheTTL` in `GaxiaServer.Config.Leaderboard`). |

## Change it

- To change the daily rewards: edit the `DefineLadder` list. `{ Cycle = false }` keeps giving the last day's reward after day 7.
- Players who stay in the game past the next claim time get it when they rejoin. To also give it in-game: at the end of `DailyRewards`, loop every 60 seconds and call `tryClaim(player)` for each player where `DailyReward.CanClaim(player)` is `true`.
- To claim with a button instead of on join: copy `MailClaim`'s pattern (`Net.OnInvoke("DailyClaim", ...)` calling `tryClaim`). Before showing a button, ask `DailyReward.CanClaim(player)` / `DailyReward.GetTimeUntilNext(player)`.
- To test the daily streak fast: set `DaySeconds` (and `ResetWindow`) in `GaxiaServer.Config.Daily` to small numbers ([config-and-flags](config-and-flags.md)). Put them back before publishing.
- To add events: one `Event.Define` per event, each with its own id. `Event.GetActive()` lists the ids that are on now; `Event.GetTimeUntilStart(id)` counts down to one.
- To send compensation to everyone: call `Mail.Send` in `onPlayerAdded` with a new saved flag (like `GotWelcomeMail`) per gift.
- To show the top 10 or the event timer on screen: put them in a state container ([show-values-on-screen](show-values-on-screen.md)). A player's own rank: `Leaderboard.GetRank(BOARD, player.UserId)` (nil past the top 100).

## See also

- [API: DailyReward](../api/DailyReward.md) · [API: Event](../api/Event.md) · [API: Mail](../api/Mail.md) · [API: Leaderboard](../api/Leaderboard.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Player data](player-data.md) · [Client ↔ server](../start/04-client-server-communication.md) · [Multi-server](multi-server.md)
