# Teleport between places and talk between servers

> A portal sends players to another place of your game (with retries and teleport data), staff can send everyone in a server to a private match server, post an announcement that appears in every server, and every server knows how many players are online in the whole game.

**Use this when** the user asks for: "teleport to another place", "portal to another world", "lobby to game", "reserved server", "private server for a match", "global announcement", "message all servers", "cross-server", "players online in all servers", "MemoryStore", "MessagingService" (ไทย: "วาร์ปไปอีกแมพ", "พอร์ทัล", "ไปอีกเพลส", "ล็อบบี้ไปเกม", "เซิร์ฟส่วนตัว", "ประกาศทุกเซิร์ฟ", "ข้ามเซิร์ฟเวอร์", "คนออนไลน์ทั้งเกม").
**Packages:** `Teleport` and `Interaction` (Step 1; also `Admin` for `/match`), `Messages` and `Admin` (Step 2), `Memory` (Step 4); `UI.Toast` on the client (Step 3). Each script stops with a clear message if its package is missing.
**You will create:** the Scripts `ServerScriptService/TravelPortal`, `ServerScriptService/GlobalAnnouncements`, `ServerScriptService/GlobalPlayerCount` and the LocalScript `StarterPlayer/StarterPlayerScripts/AnnouncementToast`.

The parts are independent: Step 1 (teleport), Steps 2–3 (announcements), Step 4 (online count). Do only what the user asked for.

How it works:

- **Teleport** sends players to **another place of the same game** (to move on the map, use `GaxiaServer.Player.Teleport(player, cframe)`). `Teleport.To` tries 4 times (waits 1, 2, 4 seconds), so it can take 7 seconds. It returns `true` (Roblox accepted it) or `false, error`. A **reserved server** is a new server only teleported players can join.
- **Messages** sends a small table (under 1 KB) to **every server**, the sender too: show it only in the `Subscribe` handler. Up to 10 messages at once, then 2 per second per server; more return `false`.
- **Memory** is short-lived storage shared by all servers (MemoryStore). When MemoryStore fails (no API access, or one error in a live game), it uses this server's memory only, and tries MemoryStore again 60 seconds later. `Memory.IsUsingFallback()` tells you.
- **Studio cannot teleport or reserve servers.** Messages and Memory need a published place with *Game Settings → Security → Enable Studio Access to API Services*. An agent cannot run these tests: give the user the steps and say which checks are still open.

## Step 1 — A portal to another place, and /match for a private server

Get the destination's **place ID**: in Studio open **View → Asset Manager → Places**, right-click the place, **Copy ID to Clipboard**. Or open that place in Studio and type `print(game.PlaceId)` in the Command Bar. It must be a place of the same game (experience).

Create a **Script** in **ServerScriptService** named **TravelPortal**. Paste this whole block into it, then put the ID in `DESTINATION_PLACE_ID`:

```lua
-- Script: ServerScriptService/TravelPortal
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Teleport"), "TravelPortal needs the Teleport package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Interaction"), "TravelPortal needs the Interaction package: install it (playbooks/start/01-install-packages.md)")

local Teleport = GaxiaServer.Teleport
local Interaction = GaxiaServer.Interaction
local DESTINATION_PLACE_ID = 0 -- put the place ID here

local portal = Instance.new("Part")
portal.Size = Vector3.new(6, 10, 1)
portal.Position = Vector3.new(0, 5, -40) -- 40 studs from the middle of the Baseplate, toward -Z
portal.Anchored = true
portal.Parent = Workspace
local traveling: { [Player]: boolean } = {} -- players being teleported now: a second press does nothing

local function onPortalUsed(player: Player)
	if DESTINATION_PLACE_ID == 0 then
		print("[TravelPortal] put the destination place ID in DESTINATION_PLACE_ID first")
		return
	end
	if traveling[player] then return end
	traveling[player] = true
	print(`[TravelPortal] sending {player.Name} to {DESTINATION_PLACE_ID}`)
	-- Teleport data arrives in the destination place. Never put Coins or items in it.
	local ok, err = Teleport.To(player, DESTINATION_PLACE_ID, { Data = { mode = "Normal" } })
	if not ok then
		print(`[TravelPortal] {player.Name} could not travel: {tostring(err)}`)
	end
	traveling[player] = nil
end
local handle = Interaction.Register(portal, { ActionText = "Travel", ObjectText = "Portal", MaxDistance = 10, OnTrigger = onPortalUsed })
assert(handle, "TravelPortal: could not put a prompt on the portal")
-- /match (moderator and above): every player in this server goes to one new private server.
if not GaxiaServer.IsInstalled("Admin") then
	print("[TravelPortal] no Admin package: /match is off")
else
	GaxiaServer.Admin.Register("match", { role = "moderator", help = "Send everyone here to a private server: /match" }, function(_caller: Player, _args: { string }): (string?, boolean?)
		if DESTINATION_PLACE_ID == 0 then
			return "Put the place ID in DESTINATION_PLACE_ID first", true
		end
		-- code = the access code. The second value (private server id) is not needed; err = why it failed.
		local code, _privateServerId, err = Teleport.ReserveServer(DESTINATION_PLACE_ID)
		if code == nil then
			print(`[TravelPortal] could not reserve a server (Studio cannot): {tostring(err)}`)
			return "Could not reserve a server. It only works in the published game.", true
		end
		local players = Players:GetPlayers()
		local ok, tpErr = Teleport.ToPrivate(players, DESTINATION_PLACE_ID, code, { Data = { mode = "Match" } })
		print(`[TravelPortal] /match with {#players} player(s): {if ok then "sent" else tostring(tpErr)}`)
		return if ok then `Sent {#players} player(s) to a private server` else "Teleport failed: try again", not ok
	end)
end

print("[TravelPortal] ready")
```

What it does: **E** at the portal teleports one player; `/match` sends everyone to a new private server. Saved data goes with them (Data saves on leave and loads in the new place).
To read the teleport data, install Gaxia with `Teleport` in the destination place too ([install](../start/01-install-packages.md)). There, `GaxiaServer.Teleport.GetArrivingData(player)` in `Players.PlayerAdded` returns the `Data` table (`{ mode = "Match" }`), or `nil` after a direct join.

## Step 2 — /announce: a message in every server

Create a **Script** in **ServerScriptService** named **GlobalAnnouncements**:

```lua
-- Script: ServerScriptService/GlobalAnnouncements
local TextService = game:GetService("TextService")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Messages"), "GlobalAnnouncements needs the Messages package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Admin"), "GlobalAnnouncements needs the Admin package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Admin = GaxiaServer.Admin
local Messages = GaxiaServer.Messages
local TOPIC = "GlobalAnnouncement"
-- Create the server -> client remote now, so the client's Net.OnClient("Announcement")
-- finds it at once (playbooks/start/04-client-server-communication.md).
Net.DeclareEvent("Announcement")

-- Every server (this one too) receives every published message here.
local function onAnnouncement(data: any, _sentTimestamp: number)
	if typeof(data) == "table" and typeof(data.text) == "string" then
		print(`[GlobalAnnouncements] received: {data.text}`)
		Net.FireAllClients("Announcement", data.text)
	end
end
-- Subscribe returns nil and the reason (it does not error) when MessagingService is unavailable.
local subscription, subscribeError = Messages.Subscribe(TOPIC, onAnnouncement)
if not subscription then
	warn(`[GlobalAnnouncements] cannot receive messages (publish the place and enable API access): {subscribeError}`)
end
-- /announce <text> for admins. Chat passes each word as its own entry in args.
Admin.Register("announce", { role = "admin", args = { "string" }, help = "Message every server: /announce <text>" }, function(caller: Player, args: { string }): (string?, boolean?)
	local text = table.concat(args, " ")
	if #text == 0 or #text > 200 then
		return "Usage: /announce <text> (1 to 200 characters)", true
	end
	local ok, filtered = pcall(function(): string -- Roblox requires filtering typed text that others see
		return TextService:FilterStringAsync(text, caller.UserId, Enum.TextFilterContext.PublicChat):GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		return "The text filter is not available: try again", true
	end
	if not Messages.Publish(TOPIC, { text = filtered, from = caller.Name }) then
		return "Not sent (too many messages, or no API access)", true
	end
	return "Announcement sent to every server", false
end)

print("[GlobalAnnouncements] ready")
```

## Step 3 — Show announcements on screen

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **AnnouncementToast**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/AnnouncementToast
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("UI.Toast"), "AnnouncementToast needs the UI.Toast package: install it (playbooks/start/01-install-packages.md)")
Gaxia.Net.OnClient("Announcement", function(text: any)
	print(`[AnnouncementToast] {tostring(text)}`)
	Gaxia.UI.Toast.Show({ Title = "Announcement", Text = tostring(text), Variant = "info", Duration = 8 })
end)
print("[AnnouncementToast] ready")
```

## Step 4 — Count players in all servers

Create a **Script** in **ServerScriptService** named **GlobalPlayerCount**:

```lua
-- Script: ServerScriptService/GlobalPlayerCount
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Memory"), "GlobalPlayerCount needs the Memory package: install it (playbooks/start/01-install-packages.md)")

local Memory = GaxiaServer.Memory
local MAP_NAME = "ServerPlayerCounts"
-- game.JobId is "" in Studio, and a MemoryStore key cannot be empty.
local SERVER_KEY = if game.JobId ~= "" then game.JobId else "studio"
print("[GlobalPlayerCount] ready")
-- Every 15 seconds. This loop never ends, so it is the last thing in the script.
while true do
	-- Kept 60 s, so a closed server drops out. Last value = sort key (order in MapRange): the count again.
	local here = #Players:GetPlayers()
	Memory.MapSet(MAP_NAME, SERVER_KEY, here, 60, here)
	local total = 0
	local servers = Memory.MapRange(MAP_NAME, 200, false) -- every server's count (up to 200 servers)
	for _, entry in servers do
		if typeof(entry.value) == "number" then
			total += entry.value
		end
	end
	ReplicatedStorage:SetAttribute("GlobalPlayers", total) -- clients can read this attribute
	print(`[GlobalPlayerCount] {total} player(s) in {#servers} server(s), shared: {not Memory.IsUsingFallback()}`)
	task.wait(15)
end
```

## Check that it works

1. Press **Play** in Studio. Output shows a `ready` line for each script you created, and no red errors. Within 15 seconds: `[GlobalPlayerCount] 1 player(s) in 1 server(s), shared: ...`.
2. Press **E** at the grey portal (40 studs from the middle of the Baseplate, toward -Z). With `DESTINATION_PLACE_ID = 0`: `put the destination place ID ... first`. With a real ID, after about 7 seconds: `[TravelPortal] <YourName> could not travel: ...` (Studio cannot teleport).
3. Give yourself a role ([admin-and-chat-commands](admin-and-chat-commands.md) Step 1; roles from `Config.Admin.Tiers`: `default` < `moderator` < `admin` < `owner`). Type `/match`: Output shows `[TravelPortal] could not reserve a server ...` in Studio. Type `/announce Hello`: Output shows `[GlobalAnnouncements] received: Hello` and a toast says `Hello`. Without API access a yellow `cannot receive messages` line appears and nothing arrives.
4. Teleports and `/match` work only in the published game. Give the user these steps: **File → Publish to Roblox** for both places, play from the Roblox website or app, press **F9** → **Server** to see Output.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Coins, items or "isVIP" in teleport data | Only harmless data (which mode, where from) | Teleport data passes through the player's computer and can be faked. Saved data travels by itself. |
| `Teleport.ToPrivate(players, id, code)` without checking `code` | Stop when `code == nil` (Step 1) | `ReserveServer` returns `nil` in Studio and on errors. |
| `Messages.Publish` in a loop or every frame | A few messages per minute | After 10 quick messages, more than 2 per second return `false` and warn `Rate limit hit`. |
| `Messages.Subscribe(...)` without checking the result | `local subscription, err = Messages.Subscribe(...)`, warn when `subscription` is `nil` (Step 2) | Without API access (Studio, an outage) Subscribe returns `nil` and the reason, and no message arrives. |
| Trusting the total after a MemoryStore error | Watch `shared:` in the `GlobalPlayerCount` line | After a failure Memory counts only this server for 60 seconds, then tries MemoryStore again. Values written meanwhile are never sent to MemoryStore: other servers never see them, but this server still reads them (`MapGet`, `MapRange`, `QueueRead`) until their TTL ends. |
| Memory for things that must be kept | Player data → `GaxiaServer.Data`, global boards → `Leaderboard` | MemoryStore entries expire and are not backed up. |

## Change it

- Several players: `Teleport.To({ player1, player2 }, placeId, { Data = { mode = "Duel" } })`. If the teleport fails after Roblox accepted it, a group going to a public server is not retried one player at a time (they would land in different servers): `OnTeleportFailed` fires for that player. To keep a group together and get retries, reserve a server and use `Teleport.ToPrivate`. A party: `GaxiaServer.Party.StartMatch(partyId, placeId)` ([social](social.md)). Fewer retries: `Teleport.Configure({ MaxAttempts = 2, BaseDelay = 1, MaxDelay = 5 })` at server start.
- Other message types: one topic per kind (`"ShutdownWarning"`). Failed publishes: `Messages.OnError:Connect(function(topic, reason) print(topic, reason) end)`. A cross-server queue: `Memory.QueueAdd(name, value, ttl)`; `Memory.QueueRead(name, count)` returns `values, readId`; then `Memory.QueueRemove(name, readId)`.
- Online total on screen: read `ReplicatedStorage:GetAttribute("GlobalPlayers")` in a LocalScript ([show-values-on-screen](show-values-on-screen.md)).

## See also

- [API: Teleport](../api/Teleport.md) · [API: Messages](../api/Messages.md) · [API: Memory](../api/Memory.md) · [API: Admin](../api/Admin.md)
- [Friends, guilds and parties](social.md) · [Admin and chat commands](admin-and-chat-commands.md) · [Player data](player-data.md) · [Live ops and global leaderboards](live-ops.md)
