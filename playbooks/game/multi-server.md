# Teleport between places and talk between servers

> A portal sends players to another place of your game (with retries and teleport data), staff can post an announcement that appears in every server, and every server knows how many players are online in the whole game.

**Use this when** the user asks for: "teleport to another place", "portal to another world", "lobby to game", "reserved server", "private server for a match", "global announcement", "message all servers", "cross-server", "players online in all servers", "MemoryStore", "MessagingService" (ไทย: "วาร์ปไปอีกแมพ", "พอร์ทัล", "ไปอีกเพลส", "ล็อบบี้ไปเกม", "เซิร์ฟส่วนตัว", "ประกาศทุกเซิร์ฟ", "ข้ามเซิร์ฟเวอร์", "คนออนไลน์ทั้งเกม").
**Packages:** `Teleport` and `Interaction` (Step 1), `Messages` and `Admin` (Step 3), `Memory` (Step 5); `UI.Toast` on the client (Step 4). Each script stops with a clear message if its package is missing.
**You will create:** the Scripts `ServerScriptService/TravelPortal`, `ServerScriptService/ArrivalData`, `ServerScriptService/GlobalAnnouncements`, `ServerScriptService/GlobalPlayerCount` and the LocalScript `StarterPlayer/StarterPlayerScripts/AnnouncementToast`.

The parts are independent: Steps 1–2 (teleport), Steps 3–4 (announcements), Step 5 (online count). Do only what the user asked for.

How it works:

- **Moving inside one place** (to a spot on the map) is not this playbook: use `GaxiaServer.Player.Teleport(player, cframe)`.
- **Teleport** (`GaxiaServer.Teleport`) sends players to **another place of the same game**. `Teleport.To` tries 4 times (waits 1, 2, 4 seconds) and returns `true` or `false, error`. It yields: the call can take up to 7 seconds. `true` means Roblox accepted the teleport; if it still fails later, the player simply stays in this server.
- **Messages** (`GaxiaServer.Messages`) sends a small table to **every server**, including the one that sent it. At most 2 messages per second per server; more return `false`. Keep each message under 1 KB.
- **Memory** (`GaxiaServer.Memory`) is short-lived storage shared by all servers (MemoryStore). Every value has a time to live in seconds. Without API access (Studio) it quietly uses this server's memory only.
- **Studio cannot teleport.** `Teleport.To` fails there after its retries; test teleports in a published game (Step 2). Messages and Memory need *Game Settings → Security → Enable Studio Access to API Services* in a published place.

## Step 1 — A portal to another place

First get the destination's **place ID**: in Studio open **View → Asset Manager → Places**, right-click the place, **Copy ID to Clipboard**. The place must be in the same game (experience).

Create a **Script** in **ServerScriptService** named **TravelPortal**. Paste this whole block into it, then put the ID in `DESTINATION_PLACE_ID`:

```lua
-- Script: ServerScriptService/TravelPortal
local Workspace = game:GetService("Workspace")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Teleport"), "TravelPortal needs the Teleport package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Interaction"), "TravelPortal needs the Interaction package: install it (playbooks/start/01-install-packages.md)")

local Teleport = GaxiaServer.Teleport
local Interaction = GaxiaServer.Interaction

local DESTINATION_PLACE_ID = 0 -- put the place ID here

local portal = Instance.new("Part")
portal.Name = "TravelPortal"
portal.Size = Vector3.new(6, 10, 1)
portal.Position = Vector3.new(0, 5, -30)
portal.Anchored = true
portal.Color = Color3.fromRGB(120, 80, 255)
portal.Material = Enum.Material.Neon
portal.Parent = Workspace

-- Players who are being teleported now, so a second press does nothing.
local traveling: { [Player]: boolean } = {}

local function onPortalUsed(player: Player)
	if DESTINATION_PLACE_ID == 0 then
		print("[TravelPortal] put the destination place ID in DESTINATION_PLACE_ID first")
		return
	end
	if traveling[player] then
		return
	end
	traveling[player] = true
	print(`[TravelPortal] sending {player.Name} to {DESTINATION_PLACE_ID}`)
	-- Teleport data arrives in the destination place (Step 2). Never put Coins or items in it.
	local ok, err = Teleport.To(player, DESTINATION_PLACE_ID, { Data = { from = "Lobby" } })
	if not ok then
		print(`[TravelPortal] {player.Name} could not travel: {tostring(err)}`)
	end
	traveling[player] = nil
end

local handle = Interaction.Register(portal, {
	ActionText = "Travel",
	ObjectText = "Portal",
	MaxDistance = 10,
	OnTrigger = onPortalUsed,
})
assert(handle, "TravelPortal: could not put a prompt on the portal")

Teleport.OnTeleportFailed:Connect(function(players: { Player }, placeId: number, err: any)
	print(`[TravelPortal] gave up on {#players} player(s) to {placeId}: {tostring(err)}`)
end)

print("[TravelPortal] ready")
```

What it does: pressing **E** at the purple portal teleports the player. Their saved data goes with them (Data saves on leave and loads in the new place).

## Step 2 — Read the teleport data in the destination place

Open the **destination place** in Studio (Asset Manager → Places → double-click). Gaxia must be installed there too, with the `Teleport` package.
Create a **Script** in its **ServerScriptService** named **ArrivalData**:

```lua
-- Script: ServerScriptService/ArrivalData
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Teleport"), "ArrivalData needs the Teleport package: install it (playbooks/start/01-install-packages.md)")

local Teleport = GaxiaServer.Teleport

local function onPlayerAdded(player: Player)
	-- nil when the player joined directly, not through a teleport.
	local data = Teleport.GetArrivingData(player)
	if typeof(data) == "table" and typeof(data.from) == "string" then
		print(`[ArrivalData] {player.Name} arrived from {data.from}`)
	else
		print(`[ArrivalData] {player.Name} joined directly`)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[ArrivalData] ready")
```

Test it: **File → Publish to Roblox** for both places, then play the game from the Roblox website or app (not Studio). Press **E** at the portal; the new place loads. To see its Output, open the in-game console (**F9** → **Server**): `[ArrivalData] <YourName> arrived from Lobby`.

## Step 3 — /announce: a message in every server

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

-- Create the server -> client remote now, so the client's Net.OnClient("Announcement") finds it.
Net.OnServer("Announcement", function() end)

-- Every server (this one too) receives every published message here.
local subscribed, subscribeError = pcall(function()
	Messages.Subscribe(TOPIC, function(data: any, _sentTimestamp: number)
		if typeof(data) == "table" and typeof(data.text) == "string" then
			print(`[GlobalAnnouncements] received: {data.text}`)
			Net.FireAllClients("Announcement", data.text)
		end
	end)
end)
if not subscribed then
	warn(`[GlobalAnnouncements] cannot receive messages (publish the place and enable API access): {subscribeError}`)
end

-- /announce <text> for admins. Typed text must pass Roblox's text filter before others see it.
Admin.Register("announce", { role = "admin", args = { "string" }, help = "Message every server: /announce <text>" }, function(caller: Player, args: { string }): (string?, boolean?)
	local text = table.concat(args, " ")
	if #text == 0 or #text > 200 then
		return "Usage: /announce <text> (1 to 200 letters)", true
	end
	local ok, filtered = pcall(function(): string
		local result = TextService:FilterStringAsync(text, caller.UserId, Enum.TextFilterContext.PublicChat)
		return result:GetNonChatStringForBroadcastAsync()
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

What it does: `/announce Double coins in 5 minutes!` reaches every server within a second or two. Each server shows it to all its players (Step 4).

## Step 4 — Show announcements on screen

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **AnnouncementToast**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/AnnouncementToast
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("UI.Toast"), "AnnouncementToast needs the UI.Toast package: install it (playbooks/start/01-install-packages.md)")

local Toast = Gaxia.UI.Toast

Gaxia.Net.OnClient("Announcement", function(text: any)
	print(`[AnnouncementToast] {tostring(text)}`)
	Toast.Show({ Title = "Announcement", Text = tostring(text), Variant = "info", Duration = 8 })
end)

print("[AnnouncementToast] ready")
```

## Step 5 — Count players in all servers

Create a **Script** in **ServerScriptService** named **GlobalPlayerCount**:

```lua
-- Script: ServerScriptService/GlobalPlayerCount
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Memory"), "GlobalPlayerCount needs the Memory package: install it (playbooks/start/01-install-packages.md)")

local Memory = GaxiaServer.Memory

local MAP_NAME = "ServerPlayerCounts"
local UPDATE_SECONDS = 15
-- game.JobId is "" in Studio, and a MemoryStore key cannot be empty.
local SERVER_KEY = if game.JobId ~= "" then game.JobId else "studio"

print(`[GlobalPlayerCount] ready (shared between servers: {not Memory.IsUsingFallback()})`)

-- This loop never ends, so it is the last thing in the script.
while true do
	-- This server's count. It expires after 60 s, so a closed server drops out by itself.
	local here = #Players:GetPlayers()
	Memory.MapSet(MAP_NAME, SERVER_KEY, here, 60, here)
	-- Every server's count (up to 200 servers), and the total.
	local total = 0
	local servers = Memory.MapRange(MAP_NAME, 200, false)
	for _, entry in servers do
		if typeof(entry.value) == "number" then
			total += entry.value
		end
	end
	ReplicatedStorage:SetAttribute("GlobalPlayers", total) -- clients can read this attribute
	print(`[GlobalPlayerCount] {total} player(s) in {#servers} server(s)`)
	task.wait(UPDATE_SECONDS)
end
```

What it does: every 15 seconds each server writes its player count and adds up all servers. The total is in the `GlobalPlayers` attribute of ReplicatedStorage.

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[TravelPortal] ready`, `[GlobalAnnouncements] ready`, `[AnnouncementToast] ready`, `[GlobalPlayerCount] ready (...)` and no red errors.
3. Within 15 seconds Output shows `[GlobalPlayerCount] 1 player(s) in 1 server(s)`.
4. Walk to the purple portal and press **E**. With `DESTINATION_PLACE_ID = 0` Output shows `put the destination place ID ... first`. With a real ID, Studio prints `[TravelPortal] <YourName> could not travel: ...` after about 7 seconds: Studio cannot teleport. Test teleports as in Step 2.
5. As an admin (see [admin-and-chat-commands](admin-and-chat-commands.md)) type `/announce Hello` in chat. Output shows `[GlobalAnnouncements] received: Hello` and a toast says `Hello`. Without API access a yellow `cannot receive messages` line appears and `/announce` answers `Not sent ...` or nothing arrives.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `Teleport.To` to move a player on the same map | `GaxiaServer.Player.Teleport(player, cframe)` | `Teleport.To` loads another place. Moving on the map is a CFrame change. |
| `TeleportService:TeleportAsync(...)` yourself | `Teleport.To(player, placeId, { Data = ... })` | The wrapper retries, packs teleport data and reports `OnTeleportFailed`. |
| Coins, items or "isVIP" in teleport data | Only harmless data (where from, which mode) | Teleport data passes through the player's computer and can be faked. Saved data travels by itself. |
| A place ID of another game | A place in the same experience | Teleport data and saved data only work inside one game. |
| Testing teleports in Studio | Publish and play from the Roblox app | Studio always fails the teleport after the retries. |
| `Messages.Publish` in a loop or every frame | A few messages per minute | Over 2 per second `Publish` returns `false` and warns `Rate limit hit`. |
| Publishing a big table (an inventory) | Small tables under 1 KB | MessagingService refuses large messages. |
| Showing typed text to other players unfiltered | `TextService:FilterStringAsync` first (Step 3) | Roblox requires filtering any player-typed text that others see. |
| `Messages.Subscribe(...)` without `pcall` | Wrap it in `pcall` (Step 3) | Subscribe **errors** when MessagingService is unavailable, which stops the script. |
| Also calling `Net.FireAllClients` right after `Publish` | Only show messages in the `Subscribe` handler | The sending server receives its own message too; it would show twice. |
| `Memory.MapSet(MAP_NAME, game.JobId, ...)` in Studio | Use `SERVER_KEY` as in Step 5 | `game.JobId` is empty in Studio. |
| Using Memory for things that must be kept | Player data → `GaxiaServer.Data`, global boards → `Leaderboard` | MemoryStore entries expire (TTL) and are not backed up. |

## Change it

- Teleport several players together: `Teleport.To({ player1, player2 }, placeId, { Data = { mode = "Duel" } })`.
- A private server for a match: `local code = Teleport.ReserveServer(placeId)`, then `Teleport.ToPrivate(players, placeId, code, { Data = ... })`. `code` is `nil` in Studio. For parties, `GaxiaServer.Party.StartMatch(partyId, placeId)` does both ([social](social.md)).
- Fewer retries or shorter waits: `Teleport.Configure({ MaxAttempts = 2, BaseDelay = 1, MaxDelay = 5 })` once at server start.
- Other message types: use another topic name per kind, for example `"ShutdownWarning"`. Each `Messages.Subscribe` handler gets `(data, sentTimestamp)`.
- See failed publishes: `Messages.OnError:Connect(function(topic, reason) print(topic, reason) end)`.
- A cross-server queue (matchmaking): `Memory.QueueAdd(name, value, ttl)`, `Memory.QueueRead(name, count)` returns `values, readId`; call `Memory.QueueRemove(name, readId)` after handling them.
- Show the online total on screen: read `ReplicatedStorage:GetAttribute("GlobalPlayers")` in a LocalScript ([show-values-on-screen](show-values-on-screen.md)).

## See also

- [API: Teleport](../api/Teleport.md) · [API: Messages](../api/Messages.md) · [API: Memory](../api/Memory.md) · [API: Interaction](../api/Interaction.md)
- [Friends, guilds and parties](social.md) · [Admin and chat commands](admin-and-chat-commands.md) · [Player data](player-data.md) · [Live ops and global leaderboards](live-ops.md)
