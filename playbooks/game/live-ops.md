# Daily rewards, timed events, mail and global leaderboards

> Players get a daily login reward with a streak, a timed "double coins" event runs on a schedule, an inbox holds gifts to claim, and a global top-10 board ranks Coins across all servers.

**Use this when** the user asks for: "daily reward", "login streak", "timed event", "weekend event", "double coins event", "limited-time event", "mail", "inbox", "send a gift to players", "compensation", "global leaderboard", "top 10 players" (ไทย: "รางวัลรายวัน", "ล็อกอินรายวัน", "อีเวนต์", "อีเวนต์จำกัดเวลา", "อีเวนต์เงินx2", "กล่องจดหมาย", "ส่งของขวัญให้ผู้เล่น", "ชดเชย", "ลีดเดอร์บอร์ดโลก", "อันดับ top 10").
**Packages:** `DailyReward`, `Event`, `Mail`, `Leaderboard`, `Economy` (it also installs `Data`). Each script stops with a clear message if its package is missing.
**You will create:** for each step you do, the script(s) named in it: `DailyRewards` (Step 1), `TimedEvents` (Step 2), `Mailbox` + `MailButton` (Step 3), `CoinsLeaderboard` (Step 4).

The four steps are independent. Do only the steps the user asked for. Currency names are free text: `Coins` and `Gems` need no setup.

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
	{ Coins = 100 }, { Coins = 150 }, { Coins = 200 }, { Coins = 250 },
	{ Coins = 300 }, { Coins = 400 }, { Coins = 500, Gems = 10 },
}, { Cycle = true })

local function tryClaim(player: Player)
	-- Claim refuses ("data not loaded") until the data is loaded: check first.
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
	if Data.WaitFor(player, 120) == nil then
		return -- the player left, or the data did not load in 120 seconds
	end
	tryClaim(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[DailyRewards] ready")
```

What it does: when a player's data loads, it claims today's reward and adds the Coins/Gems. `Claim` works once per 24 hours; a claim 24–48 hours after the last one adds 1 to the streak, later resets it.

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

-- EVENT DEFINITION (keep). Both signals fire once per server, also on a server that starts
-- mid-event. The clock checks every 5 seconds, so connect/define order does not matter.
Event.OnEventStart:Connect(function(eventId: string, data: any)
	print(`[TimedEvents] {eventId} started, multiplier x{data.Multiplier}`)
end)
Event.OnEventEnd:Connect(function(eventId: string)
	print(`[TimedEvents] {eventId} ended`)
end)

-- For testing: starts now, lasts 10 minutes. For a real event use fixed UTC dates.
-- Midnight Dec 24 in Thailand (UTC+7) is 17:00 UTC on Dec 23:
-- StartsAt = DateTime.fromUniversalTime(2026, 12, 23, 17, 0, 0).UnixTimestamp
local now = os.time()
Event.Define("DoubleCoins", { StartsAt = now, EndsAt = now + 10 * 60, Data = { Multiplier = 2 } })

print("[TimedEvents] ready")

-- EXAMPLE PAYOUT (replace with your own; check item 3 expects it). It pays 5 Coins every
-- 30 seconds forever, also after the event; only the doubling depends on the event.
while true do
	task.wait(30)
	local multiplier = if Event.IsActive("DoubleCoins") then Event.GetData("DoubleCoins").Multiplier else 1
	local amount = 5 * multiplier
	for _, player in Players:GetPlayers() do
		if Economy.Add(player, "Coins", amount) then
			print(`[TimedEvents] {player.Name} +{amount} Coins ({Event.GetTimeRemaining("DoubleCoins")} s of DoubleCoins left)`)
		end
	end
end
```

What it does: `Event.Define` sets a start and an end (Unix seconds, UTC); the loop pays Coins, doubled while `Event.IsActive`.

## Step 3 — An inbox with claimable gifts

Create a **Script** in **ServerScriptService** named **Mailbox**:

```lua
-- Script: ServerScriptService/Mailbox
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages) -- for Gaxia.Net

assert(GaxiaServer.IsInstalled("Mail"), "Mailbox needs the Mail package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Economy"), "Mailbox needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Mail = GaxiaServer.Mail
local Economy = GaxiaServer.Economy

-- Client asks: "claim all my gifts". It sends nothing, so it cannot fake an amount.
Net.OnInvoke("MailClaimAll", function(player: Player): number
	if not Data.IsLoaded(player) then
		return 0
	end
	local claimed = 0
	for _, mail in Mail.GetMailbox(player) do
		-- Mail read back has lowercase fields: id, subject, attachments, claimed.
		if mail.attachments ~= nil and not mail.claimed then
			local attachments = Mail.Claim(player, mail.id) -- nil when already claimed
			if attachments ~= nil then
				for currency, amount in attachments do -- { Coins = 250 } style tables
					Economy.Add(player, currency, amount)
				end
				claimed += 1
				print(`[Mailbox] {player.Name} claimed {mail.id} ({mail.subject})`)
			end
		end
	end
	return claimed
end, { rate = 1, burst = 2 })

-- A welcome gift, sent once per player (remembered in the saved field GotWelcomeMail).
local function onPlayerAdded(player: Player)
	if Data.WaitFor(player, 120) == nil then
		return -- the player left, or the data did not load in 120 seconds
	end
	if Data.Get(player, "GotWelcomeMail") ~= true then
		-- Send takes capitalized keys: Subject, Body, From, Attachments.
		-- It returns the mail id, or nil and a reason (the data is not loaded): remember the gift only when sent.
		local mailId, reason = Mail.Send(player, { Subject = "Welcome!", Body = "A gift to start.", From = "The Team", Attachments = { Coins = 250 } })
		if mailId ~= nil then
			Data.Set(player, "GotWelcomeMail", true)
		else
			warn(`[Mailbox] welcome mail not sent to {player.Name}: {reason}`)
		end
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
button.Text = "Claim mail"
button.Parent = screenGui

button.Activated:Connect(function()
	local claimed = Net.InvokeServer("MailClaimAll")
	if claimed == nil then
		print("[MailButton] request dropped (too many clicks): click again")
		return
	end
	print(`[MailButton] claimed {claimed} gift(s)`)
end)

print("[MailButton] ready")
```

What it does: the server sends a welcome mail with 250 Coins (saved in the inbox). The inbox keeps at most `Mail.MaxMail` (50) mails: past that, `Send` removes claimed or expired mail first, then the oldest, never the new one. A click on the button claims every gift; **your code gives** what `Mail.Claim` returns.

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

-- The OrderedDataStore name; a new name starts an empty board. Studio uses its own board,
-- so test scores stay off the live one.
local BOARD = if game:GetService("RunService"):IsStudio() then "TopCoins_Studio" else "TopCoins_v1"
local TOP_COUNT = 10 -- at most 100

print("[CoinsLeaderboard] ready")

-- This loop never ends, so it is the last thing in the script.
while true do
	task.wait(60)
	-- 1. Send every loaded player's score (whole numbers only).
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

What it does: once a minute it saves each player's Coins and prints the top 10 of all servers. `GetTop` is cached 60 seconds; `Update` clears this server's cache. `Update` stores whole numbers only (it rounds down: 12.7 is saved as 12) and `GetTop` returns at most 100 entries (the count is clamped to 1–100).

## Check that it works

Before you press Play: in **Game Settings → Security**, turn on **Enable Studio Access to API Services** (the place must be published). Without it, nothing saves and Output shows `[LeaderboardService] Update failed …` warnings. With it, Studio uses the live game's saved data: your test play uses your real daily claim and welcome mail.

1. Press **Play**. Output shows the `ready` line of each script you created (`[DailyRewards] ready`, `[TimedEvents] ready`, `[Mailbox] ready` + `[MailButton] ready`, `[CoinsLeaderboard] ready`) and no red errors.
2. (Step 1) Within a few seconds: `[DailyRewards] <YourName> claimed day <N>, streak <N>` (day 1 on a new save). Stop and **Play** again: `cannot claim: already claimed today. Next claim in 24 h`.
3. (Step 2) Within 5 seconds: `[TimedEvents] DoubleCoins started, multiplier x2`. After 30 seconds: `[TimedEvents] <YourName> +10 Coins (… s of DoubleCoins left)`.
4. (Step 3) `[Mailbox] <YourName> has 1 unread mail` (on a new save). Click the **Claim mail** button (bottom left): `[Mailbox] <YourName> claimed mail_1 (Welcome!)` and `[MailButton] claimed 1 gift(s)`. Click again: `[MailButton] claimed 0 gift(s)`.
5. (Step 4) After 60 seconds: `[CoinsLeaderboard] #1 <YourName>: <your Coins>`.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `DailyReward.Claim(player)` in `PlayerAdded` right away | `Data.WaitFor(player, 120)`, then check `Data.IsLoaded` | Before data loads, `Claim` returns `nil, "data not loaded"`: the player gets nothing. |
| `Mail.Send` to a player whose data is not loaded, or who is in another server | Send after `Data.WaitFor(player, 120)`, to players in this server; check its result | Before data loads, `Send` returns `nil, "data not loaded"` and stores nothing. There is no offline delivery. |
| The client sends the reward amount to claim | The client sends nothing; the server gives `Mail.Claim`'s attachments (Step 3) | A cheater can send any amount. |
| Midnight Dec 24 in Thailand as `DateTime.fromUniversalTime(2026, 12, 24, 0, 0, 0)` | `DateTime.fromUniversalTime(2026, 12, 23, 17, 0, 0).UnixTimestamp` | Event times are UTC. Thailand is UTC+7: subtract 7 hours. |
| `Leaderboard.Update(...)` on every Coins change | Once per player per minute (Step 4) | OrderedDataStore writes are limited (about 60 + 10 × players per minute per server). Extra writes fail with a warning. |
| `Leaderboard.Update(BOARD, player.UserId, Economy.Get(player, "Coins"))` in `PlayerRemoving` | Only submit while `Data.IsLoaded(player)` is true (Step 4) | After the player leaves, `Economy.Get` returns 0 and the board score becomes 0. |
| `Leaderboard.Update(BOARD, player.UserId, 12.5)` and expecting `12.5` on the board | `math.floor(value)` yourself, or keep scores whole | OrderedDataStore stores whole numbers only: `Update` rounds down and saves `12`. |
| `Leaderboard.GetTop(BOARD, 500)` | 100 or fewer | The count is clamped to 1–100: you get at most 100 entries. |

## Change it

- Daily rewards: edit the `DefineLadder` list (`{ Cycle = false }` keeps giving day 7 after day 7). To claim with a button: copy `MailClaimAll`'s pattern (`Net.OnInvoke("DailyClaim", ...)` calling `tryClaim`); ask `DailyReward.CanClaim(player)` / `DailyReward.GetTimeUntilNext(player)` before showing it.
- To test the daily streak fast: never edit `GaxiaServer.Config`. In `ConfigOverrides` ([config-and-flags](config-and-flags.md)) add `GaxiaServer.EConfig.Set("Daily.DaySeconds", 60)` and `GaxiaServer.EConfig.Set("Daily.ResetWindow", 120)`. Remove them before publishing.
- To add events: one `Event.Define` per event, each with its own id. `Event.GetActive()` lists the ids that are on now; `Event.GetTimeUntilStart(id)` counts down to one.
- To send compensation to everyone: call `Mail.Send` in `onPlayerAdded` with a new saved flag (like `GotWelcomeMail`) per gift.
- To show the top 10 or the event timer on screen: put them in a state container ([show-values-on-screen](show-values-on-screen.md)). A player's own rank: `Leaderboard.GetRank(BOARD, player.UserId)` (nil past the top 100).

## See also

- [API: DailyReward](../api/DailyReward.md) · [API: Event](../api/Event.md) · [API: Mail](../api/Mail.md) · [API: Leaderboard](../api/Leaderboard.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Player data](player-data.md) · [Client ↔ server](../start/04-client-server-communication.md) · [Multi-server](multi-server.md)
