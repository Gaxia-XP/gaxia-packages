# Friends, guilds and parties

> Players type `/friend Bob` and `/accept Alice` to become in-game friends, `/party Bob` and `/partyjoin Alice` to group up, and `/guildcreate Wolves WLF`, `/guildinvite Bob` and `/guildjoin` to build a saved guild. Invites pop up as toasts, and **Friends** / **Guild** buttons open the built-in lists.

**Use this when** the user asks for: "friends", "friend list", "add friend", "block player", "party", "group up", "team up", "invite to party", "guild", "clan", "create a guild", "guild roles" (ไทย: "เพื่อน", "ระบบเพื่อน", "เพิ่มเพื่อน", "บล็อก", "ปาร์ตี้", "ตั้งปาร์ตี้", "ชวนเข้าปาร์ตี้", "กิลด์", "แคลน", "สร้างกิลด์", "ชวนเข้ากิลด์").
**Packages:** `Friend`, `Party`, `Guild` (they also install `Data`, `InviteQueue`, `GuildLock`, `Messages`, `Memory`, `Teleport`) and `Chat` on the server; `UI.Toast` on the client. Each script stops with a clear message if its package is missing.
**You will create:** the Scripts `ServerScriptService/FriendCommands`, `ServerScriptService/PartyCommands`, `ServerScriptService/GuildCommands` and the LocalScript `StarterPlayer/StarterPlayerScripts/SocialNotices`.

Steps 1–3 are independent: do only the ones the user asked for. Always do Step 4.

How it works:

- **Friend**: friends and blocks are saved in the player's data. A request to a player in another server waits in a cross-server queue until that player joins a server.
- **Party**: a party lives in **one server's memory** (not saved). It is gone when the server closes. Invites last 60 seconds. Max 4 players.
- **Guild**: guilds are saved in a DataStore and shared by all servers. Roles: `Owner`, `Officer`, `Member`. Only Officers and the Owner can invite.
- All three are **server only**. The player acts through chat commands (`GaxiaServer.Chat`). Each command's answer appears in the player's chat. The server tells the invited player with a toast (Step 4).
- **Studio:** Friend and Party work in Studio (test with 2 players, see *Check that it works*). **Guild needs API access**: publish the place, then *Game Settings → Security → Enable Studio Access to API Services*. Without it every guild change fails with `lock busy`.

## Step 1 — Friends: /friend, /accept, /friends

Create a **Script** in **ServerScriptService** named **FriendCommands**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/FriendCommands
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Friend"), "FriendCommands needs the Friend package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Chat"), "FriendCommands needs the Chat package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Chat = GaxiaServer.Chat
local Friend = GaxiaServer.Friend

-- Create the server -> client remote now, so the client's Net.OnClient("SocialNotice") finds it.
Net.OnServer("SocialNotice", function() end)

-- Requests each player got: [player][sender name in lowercase] = sender UserId.
-- Remembered here so /accept also works when the sender is in another server.
local requests: { [Player]: { [string]: number } } = {}

-- The player who gets a request sees a toast (Step 4).
Friend.OnRequest:Connect(function(toPlayer: Player, fromUserId: number, fromName: string)
	requests[toPlayer] = requests[toPlayer] or {}
	requests[toPlayer][string.lower(fromName)] = fromUserId
	print(`[FriendCommands] {fromName} sent {toPlayer.Name} a friend request`)
	Net.FireClient(toPlayer, "SocialNotice", `{fromName} wants to be your friend. Type /accept {fromName}`)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	requests[player] = nil
end)

Chat.Register("friend", { args = { "player" }, help = "Send a friend request: /friend <player>" }, function(caller: Player, args: { string }): string?
	-- ParseArgs finds a player in this server by full name or the start of the name.
	local parsed = Chat.ParseArgs({ "player" }, args)
	local target: Player? = if parsed then parsed[1] else nil
	if target == nil then
		return "Usage: /friend <player> (the player must be in this server)"
	end
	if not (Data.IsLoaded(caller) and Data.IsLoaded(target)) then
		return "Data is still loading: try again in a moment"
	end
	local ok, reason = Friend.SendRequest(caller, target.UserId)
	return if ok then `Friend request sent to {target.Name}` else `Could not send: {reason}`
end)

Chat.Register("accept", { args = { "string" }, help = "Accept a friend request: /accept <name>" }, function(caller: Player, args: { string }): string?
	local name = string.lower(args[1] or "")
	local fromUserId = (requests[caller] or {})[name]
	if fromUserId == nil then
		return `No friend request from "{args[1] or ""}". Type the full name from the request.`
	end
	if not Data.IsLoaded(caller) then
		return "Data is still loading: try again in a moment"
	end
	local ok, reason = Friend.AcceptRequest(caller, fromUserId)
	if not ok then
		return `Could not accept: {reason}`
	end
	requests[caller][name] = nil
	print(`[FriendCommands] {caller.Name} and {args[1]} are now friends`)
	local sender = Players:GetPlayerByUserId(fromUserId) -- nil when the sender is in another server
	if sender then
		Net.FireClient(sender, "SocialNotice", `{caller.Name} accepted your friend request`)
	end
	return `You and {args[1]} are now friends`
end)

Chat.Register("friends", { help = "List your friends: /friends" }, function(caller: Player, _args: { string }): string?
	local list = Friend.GetList(caller) -- online friends first
	if #list == 0 then
		return "No friends yet. Type /friend <player>"
	end
	local names = {}
	for _, entry in list do
		table.insert(names, (if entry.online then "[online] " else "") .. entry.name)
	end
	return `Friends ({#list}): {table.concat(names, ", ")}`
end)

print("[FriendCommands] ready")
```

What it does: `/friend Bob` sends a request; Bob sees a toast and types `/accept Alice`. Both lists are saved.
A request to a player who is offline or in another server is delivered when they next join; `/accept` still works then.

## Step 2 — Parties: /party, /partyjoin, /partyleave

Create a **Script** in **ServerScriptService** named **PartyCommands**:

```lua
-- Script: ServerScriptService/PartyCommands
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Party"), "PartyCommands needs the Party package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Chat"), "PartyCommands needs the Chat package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Chat = GaxiaServer.Chat
local Party = GaxiaServer.Party

Net.OnServer("SocialNotice", function() end)

Party.OnInvite:Connect(function(toPlayer: Player, _partyId: string, fromName: string)
	Net.FireClient(toPlayer, "SocialNotice", `{fromName} invited you to a party. Type /partyjoin {fromName}`)
end)

-- One Output line with the members every time a party changes.
Party.OnPartyChanged:Connect(function(partyId: string)
	local names = {}
	for _, member in Party.GetMembers(partyId) do
		table.insert(names, member.Name)
	end
	print(`[PartyCommands] {partyId}: {table.concat(names, ", ")}`)
end)

-- Party does not notice players who leave the game: remove them yourself.
Players.PlayerRemoving:Connect(function(player: Player)
	Party.Leave(player)
end)

local function targetOf(args: { string }): Player?
	local parsed = Chat.ParseArgs({ "player" }, args)
	return if parsed then parsed[1] else nil
end

Chat.Register("party", { args = { "player" }, help = "Invite to your party: /party <player>" }, function(caller: Player, args: { string }): string?
	local target = targetOf(args)
	if target == nil then
		return "Usage: /party <player> (the player must be in this server)"
	end
	if Party.GetParty(caller) == nil then
		Party.Create(caller) -- no party yet: make one, with the caller as leader
	end
	local ok, reason = Party.Invite(caller, target.UserId)
	return if ok then `Invited {target.Name} (60 seconds to accept)` else `Could not invite: {reason}`
end)

Chat.Register("partyjoin", { args = { "player" }, help = "Join the party you were invited to: /partyjoin <leader>" }, function(caller: Player, args: { string }): string?
	local leader = targetOf(args)
	local partyId = if leader then Party.GetParty(leader) else nil
	if partyId == nil then
		return "Usage: /partyjoin <player who invited you>"
	end
	local ok, reason = Party.AcceptInvite(caller, partyId)
	return if ok then `You joined {partyId}` else `Could not join: {reason}`
end)

Chat.Register("partyleave", { help = "Leave your party: /partyleave" }, function(caller: Player, _args: { string }): string?
	if Party.GetParty(caller) == nil then
		return "You are not in a party"
	end
	Party.Leave(caller) -- if the leader leaves, the next member becomes leader
	return "You left the party"
end)

print("[PartyCommands] ready")
```

What it does: `/party Bob` makes a party (if needed) and invites Bob; Bob types `/partyjoin Alice` within 60 seconds.

## Step 3 — Guilds: /guildcreate, /guildinvite, /guildjoin, /guild

Create a **Script** in **ServerScriptService** named **GuildCommands**:

```lua
-- Script: ServerScriptService/GuildCommands
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Guild"), "GuildCommands needs the Guild package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Chat"), "GuildCommands needs the Chat package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Chat = GaxiaServer.Chat
local Guild = GaxiaServer.Guild

Net.OnServer("SocialNotice", function() end)

Guild.OnInvite:Connect(function(toPlayer: Player, _guildId: string, guildName: string, fromName: string)
	Net.FireClient(toPlayer, "SocialNotice", `{fromName} invited you to the guild {guildName}. Type /guildjoin`)
end)

Chat.Register("guildcreate", { args = { "string", "string" }, help = "Create a guild: /guildcreate <name> <tag>" }, function(caller: Player, args: { string }): string?
	if args[1] == nil or args[2] == nil then
		return "Usage: /guildcreate <name> <tag> (one word each, tag 2-4 letters)"
	end
	if not Data.IsLoaded(caller) then
		return "Data is still loading: try again in a moment"
	end
	local ok, result = Guild.Create(caller, args[1], args[2]) -- result = the guild id, or why it failed
	if not ok then
		return `Could not create: {result}`
	end
	print(`[GuildCommands] {caller.Name} created guild {args[1]} ({result})`)
	return `Guild {args[1]} created. Invite with /guildinvite <player>`
end)

Chat.Register("guildinvite", { args = { "player" }, help = "Invite to your guild: /guildinvite <player>" }, function(caller: Player, args: { string }): string?
	local parsed = Chat.ParseArgs({ "player" }, args)
	local target: Player? = if parsed then parsed[1] else nil
	if target == nil then
		return "Usage: /guildinvite <player> (the player must be in this server)"
	end
	local ok, reason = Guild.Invite(caller, target.UserId) -- Officer or Owner only
	return if ok then `Invited {target.Name}` else `Could not invite: {reason}`
end)

Chat.Register("guildjoin", { help = "Accept your newest guild invite: /guildjoin" }, function(caller: Player, _args: { string }): string?
	local newest = nil
	for _, invite in Guild.GetPendingInvites(caller) do
		if newest == nil or invite.expiresAt > newest.expiresAt then
			newest = invite
		end
	end
	if newest == nil then
		return "You have no guild invites"
	end
	local ok, reason = Guild.AcceptInvite(caller, newest.guildId)
	if not ok then
		return `Could not join: {reason}`
	end
	print(`[GuildCommands] {caller.Name} joined {newest.name}`)
	return `You joined {newest.name}`
end)

Chat.Register("guild", { help = "Show your guild: /guild" }, function(caller: Player, _args: { string }): string?
	local data = Guild.GetGuild(caller)
	if data == nil then
		return "You are not in a guild. Create one with /guildcreate <name> <tag>"
	end
	return `[{data.Tag}] {data.Name}: {#Guild.GetMembers(data.Id)} member(s), your role: {Guild.RoleOf(caller) or "?"}`
end)

print("[GuildCommands] ready")
```

What it does: the creator is the `Owner`. `/guildinvite Bob` invites; Bob types `/guildjoin` and becomes a `Member`.

## Step 4 — Show invites as toasts, and add Friends / Guild buttons

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **SocialNotices**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/SocialNotices
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("UI.Toast"), "SocialNotices needs the UI.Toast package: install it (playbooks/start/01-install-packages.md)")

local Toast = Gaxia.UI.Toast

Gaxia.Net.OnClient("SocialNotice", function(text: any)
	print(`[SocialNotices] {tostring(text)}`)
	Toast.Show({ Title = "Social", Text = tostring(text), Variant = "info", Duration = 6 })
end)

-- Buttons on the right of the screen, only for the lists that are installed.
local gui = Instance.new("ScreenGui")
gui.Name = "SocialButtons"
gui.ResetOnSpawn = false
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local function addButton(text: string, order: number, onClick: () -> ())
	local button = Instance.new("TextButton")
	button.Name = text
	button.Text = text
	button.Size = UDim2.fromOffset(110, 40)
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -12, 0.5, (order - 1) * 48)
	button.TextSize = 18
	button.Font = Enum.Font.GothamBold
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.BackgroundColor3 = Color3.fromRGB(60, 130, 90)
	button.Parent = gui
	button.Activated:Connect(function()
		onClick()
	end)
end

if Gaxia.IsInstalled("UI.FriendListPanel") then
	addButton("Friends", 1, function()
		Gaxia.UI.FriendListPanel.Toggle()
	end)
end
if Gaxia.IsInstalled("UI.GuildPanel") then
	addButton("Guild", 2, function()
		Gaxia.UI.GuildPanel.Toggle()
	end)
end

print("[SocialNotices] ready")
```

What it does: every `SocialNotice` from the server becomes a toast. **Friends** shows the friend list (● = online). **Guild** shows the guild and its members.

## Check that it works

1. Open **Test** → **Clients and Servers**, choose **2** players, press **Start**. Studio opens a server window and two player windows (`Player1`, `Player2`).
2. In the **server** window, Output shows `[FriendCommands] ready`, `[PartyCommands] ready`, `[GuildCommands] ready` and no red errors. Each player window shows `[SocialNotices] ready`.
3. In **Player1**'s chat type `/friend Player2`. Player1's chat shows `Friend request sent to Player2`. Player2 sees a toast `Player1 wants to be your friend. Type /accept Player1`.
4. In **Player2**'s chat type `/accept Player1`. Server Output shows `[FriendCommands] Player2 and Player1 are now friends`. Type `/friends`: chat shows `Friends (1): [online] Player1`. Click **Friends**: the list shows `● Player1`.
5. Player1 types `/party Player2`; Player2 types `/partyjoin Player1`. Server Output shows `[PartyCommands] party_1: Player1, Player2`.
6. Guild (needs API access, see *How it works*): Player1 types `/guildcreate Wolves WLF`, then `/guildinvite Player2`; Player2 types `/guildjoin`, then `/guild`. Chat shows `[WLF] Wolves: 2 member(s), your role: Member`.
7. Yellow `[InviteQueue] ... failed` lines in Studio without API access are expected: only the cross-server queue is off.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Testing with one player in **Play** | **Clients and Servers** with 2 players | You cannot friend or invite yourself (`cannot friend self`). |
| Testing guilds without API access | Publish, then enable *Studio Access to API Services* | Guilds use DataStore and MemoryStore. Without them every change returns `lock busy`. |
| Relying on `UI.InviteToast` for Accept / Decline buttons | Toasts from Step 4 plus the chat commands | Today `UI.InviteToast` only prints a warning (`accept/decline unavailable`). It has no buttons. |
| No `PlayerRemoving` → `Party.Leave` | Keep those lines from Step 2 | Party never removes players who left the game; they would stay in the party. |
| Expecting a party to follow players to another server | Teleport the whole party with `Party.StartMatch` | Parties live in one server's memory only. |
| `/partyjoin` after 60 seconds | Invite again with `/party` | Party invites expire after 60 seconds (`no such invite or it expired`). |
| `Friend.SendRequest(player, ...)` right after join | Check `Data.IsLoaded` first (as in the commands) | Friends are in the saved data. Before it loads, the change is not saved. |
| Owner types a leave command | Transfer the guild first (`Guild.Transfer`) or disband (`Guild.Disband`) | `Guild.Leave` refuses the Owner: `owner must transfer or disband first`. |
| A guild name with spaces in `/guildcreate` | One word for the name, 2–4 letters for the tag | Chat splits words at spaces. The name is cut at 24 letters, the tag at 4. |
| Trusting a userId or guild id sent by a client | Use `Chat.ParseArgs` or the server's own lists | The server decides who is invited; chat commands only pass words. |

## Change it

- Remove or block a friend: `Friend.Remove(player, otherUserId)`, `Friend.Block(player, otherUserId)`, `Friend.Unblock(player, otherUserId)`. Each returns `ok, reason`. A blocked player cannot send the blocker a friend request.
- Mark a favorite: `Friend.SetFavorite(player, otherUserId, true)`. Favorites come first in `Friend.GetList` (after online friends).
- Party size: `Party.SetMaxSize(6)` once at server start.
- Send a party to its own private server: `Party.StartMatch(partyId, PLACE_ID)` reserves a server and teleports every member ([multi-server](multi-server.md)). It cannot work in Studio.
- Guild roles: `Guild.Promote(owner, userId)` (Member → Officer, max 5 Officers), `Guild.Demote(owner, userId)`, `Guild.Kick(officer, userId)`, `Guild.Transfer(owner, newOwnerUserId)`, `Guild.Disband(owner)`, `Guild.SetDescription(officer, text)`.
- Guild vault (shared item storage): `Guild.VaultDeposit(player, itemId, count)`, `Guild.VaultWithdraw(player, itemId, count)` (Officer or Owner), `Guild.VaultGetContents(player)`.
- Guild limits (50 members, name 24 letters, tag 4) are in `Config.Social.Guild`: see [config-and-flags](config-and-flags.md).
- Discord messages when a guild is created or disbanded: [webhooks-and-analytics](webhooks-and-analytics.md).

## See also

- [API: Friend](../api/Friend.md) · [API: Party](../api/Party.md) · [API: Guild](../api/Guild.md) · [API: Chat](../api/Chat.md) · [API: UI.InviteToast](../api/UI.InviteToast.md)
- [Admin and chat commands](admin-and-chat-commands.md) · [Multi-server](multi-server.md) · [UI and toasts](ui.md) · [Player data](player-data.md)
