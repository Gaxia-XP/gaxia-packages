# Friends, guilds and parties

> Players type `/friend Bob` and `/accept Alice` to become in-game friends, `/party Bob` and `/partyjoin Alice` to group up, and `/guildcreate Wolves WLF`, `/guildinvite Bob` and `/guildjoin` to build a saved guild. Every invite pops up as a toast.

**Use this when** the user asks for: "friends", "friend list", "add friend", "block player", "party", "group up", "team up", "invite to party", "guild", "clan", "create a guild", "guild roles" (ไทย: "เพื่อน", "ระบบเพื่อน", "เพิ่มเพื่อน", "บล็อก", "ปาร์ตี้", "ตั้งปาร์ตี้", "ชวนเข้าปาร์ตี้", "กิลด์", "แคลน", "สร้างกิลด์", "ชวนเข้ากิลด์").
**Packages:** `Chat` and the ones you need of `Friend` (Step 1), `Party` (Step 2), `Guild` (Step 3); `UI.Toast` on the client (Step 4). Each script stops with a clear message if its package is missing.
**You will create:** the Scripts `ServerScriptService/FriendCommands`, `ServerScriptService/PartyCommands`, `ServerScriptService/GuildCommands` and the LocalScript `StarterPlayer/StarterPlayerScripts/SocialNotices`.

Steps 1–3 are independent: do only the ones the user asked for. Always do Step 4 too: it shows the invites, and it needs at least one of Steps 1–3 (they create the `SocialNotice` remote).

How it works:

- **Friend**: friends and blocks are saved in the player's data. Both players must be in the same server to accept. **Party**: a party lives in **one server's memory** (not saved). Invites last 60 seconds. Max 4 players.
- **Guild**: guilds are saved in a DataStore and shared by all servers. Roles: `Owner`, `Officer`, `Member`. Only Officers and the Owner can invite. **Guild needs API access**: publish the place, then *Game Settings → Security → Enable Studio Access to API Services*. Without it every guild change fails with `lock busy`.
- All three are **server only**. Players act through chat commands (`GaxiaServer.Chat`); each answer appears in the player's chat. `Chat.ParseArgs({ "player" }, args)` finds a player in this server by name or the start of a name. It returns `nil` for no match, for two matches, and for an empty name.

## Step 1 — Friends: /friend, /accept

Create a **Script** in **ServerScriptService** named **FriendCommands**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/FriendCommands
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Friend"), "FriendCommands needs the Friend package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Chat"), "FriendCommands needs the Chat package: install it (playbooks/start/01-install-packages.md)")

local Net, Data, Chat, Friend = Gaxia.Net, GaxiaServer.Data, GaxiaServer.Chat, GaxiaServer.Friend
local NO_PLAYER = "No player matches, or more than one does. Type more of the name."
local LOADING = "Data is still loading: try again in a moment"
-- Intentionally empty: it creates the remote now, so the client never waits for it (start/04).
Net.OnServer("SocialNotice", function() end)
local function playerArg(args: { string }): Player?
	local parsed = Chat.ParseArgs({ "player" }, args)
	return if parsed then parsed[1] else nil
end
Friend.OnRequest:Connect(function(toPlayer: Player, fromUserId: number, fromName: string)
	-- A request comes back at every join until it expires: skip it when they are already friends.
	task.spawn(function()
		if Data.WaitFor(toPlayer, 120) == nil then return end
		for _, entry in Friend.GetList(toPlayer) do
			if entry.userId == fromUserId then return end
		end
		print(`[FriendCommands] {fromName} sent {toPlayer.Name} a friend request`)
		Net.FireClient(toPlayer, "SocialNotice", `{fromName} wants to be your friend. Type /accept {fromName}`)
	end)
end)

Chat.Register("friend", { args = { "player" }, help = "Send a friend request: /friend <player>" }, function(caller: Player, args: { string }): string?
	local target = playerArg(args)
	if target == nil then return NO_PLAYER end
	if not (Data.IsLoaded(caller) and Data.IsLoaded(target)) then return LOADING end
	local ok, reason = Friend.SendRequest(caller, target.UserId)
	return if ok then `Friend request sent to {target.Name}` else `Could not send: {reason}`
end)
Chat.Register("accept", { args = { "player" }, help = "Accept a friend request: /accept <player>" }, function(caller: Player, args: { string }): string?
	local sender = playerArg(args) -- the sender must be in this server
	if sender == nil then return NO_PLAYER end
	if not (Data.IsLoaded(caller) and Data.IsLoaded(sender)) then return LOADING end
	local ok, reason = Friend.AcceptRequest(caller, sender.UserId)
	if not ok then return `Could not accept: {reason}` end
	print(`[FriendCommands] {caller.Name} and {sender.Name} are now friends`)
	Net.FireClient(sender, "SocialNotice", `{caller.Name} accepted your friend request`)
	return `You and {sender.Name} are now friends`
end)

print("[FriendCommands] ready")
```

What it does: `/friend Bob` sends a request; Bob sees a toast and types `/accept Alice` while Alice is still in the server. Both friend lists are saved.

## Step 2 — Parties: /party, /partyjoin

Create a **Script** in **ServerScriptService** named **PartyCommands**:

```lua
-- Script: ServerScriptService/PartyCommands
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Party"), "PartyCommands needs the Party package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Chat"), "PartyCommands needs the Chat package: install it (playbooks/start/01-install-packages.md)")

local Net, Chat, Party = Gaxia.Net, GaxiaServer.Chat, GaxiaServer.Party
local NO_PLAYER = "No player matches, or more than one does. Type more of the name."
Net.OnServer("SocialNotice", function() end) -- intentionally empty, see Step 1
local function playerArg(args: { string }): Player?
	local parsed = Chat.ParseArgs({ "player" }, args)
	return if parsed then parsed[1] else nil
end

Party.OnInvite:Connect(function(toPlayer: Player, _partyId: string, fromName: string)
	Net.FireClient(toPlayer, "SocialNotice", `{fromName} invited you to a party. Type /partyjoin {fromName}`)
end)
-- Party does not notice players who leave the game: remove them yourself.
Players.PlayerRemoving:Connect(function(player: Player)
	Party.Leave(player)
end)
Chat.Register("party", { args = { "player" }, help = "Invite to your party: /party <player>" }, function(caller: Player, args: { string }): string?
	local target = playerArg(args)
	if target == nil then return NO_PLAYER end
	if Party.GetParty(caller) == nil then Party.Create(caller) end -- no party yet: the caller leads a new one
	local ok, reason = Party.Invite(caller, target.UserId)
	return if ok then `Invited {target.Name} (60 seconds to accept)` else `Could not invite: {reason}`
end)
Chat.Register("partyjoin", { args = { "player" }, help = "Join the party you were invited to: /partyjoin <leader>" }, function(caller: Player, args: { string }): string?
	local leader = playerArg(args)
	if leader == nil then return NO_PLAYER end
	local partyId = Party.GetParty(leader)
	if partyId == nil then return `{leader.Name} has no party. Ask for a new invite.` end
	local ok, reason = Party.AcceptInvite(caller, partyId)
	if not ok then return `Could not join: {reason}` end
	print(`[PartyCommands] {caller.Name} joined {partyId}: {#Party.GetMembers(partyId)} member(s)`)
	return `You joined {partyId}`
end)

print("[PartyCommands] ready")
```

What it does: `/party Bob` makes a party (if needed) and invites Bob; Bob types `/partyjoin Alice` within 60 seconds.

## Step 3 — Guilds: /guildcreate, /guildinvite, /guildjoin

Create a **Script** in **ServerScriptService** named **GuildCommands**:

```lua
-- Script: ServerScriptService/GuildCommands
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Guild"), "GuildCommands needs the Guild package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Chat"), "GuildCommands needs the Chat package: install it (playbooks/start/01-install-packages.md)")

local Net, Data, Chat, Guild = Gaxia.Net, GaxiaServer.Data, GaxiaServer.Chat, GaxiaServer.Guild
local LOADING = "Data is still loading: try again in a moment"
Net.OnServer("SocialNotice", function() end) -- intentionally empty, see Step 1
Guild.OnInvite:Connect(function(toPlayer: Player, _guildId: string, guildName: string, fromName: string)
	Net.FireClient(toPlayer, "SocialNotice", `{fromName} invited you to the guild {guildName}. Type /guildjoin`)
end)
Chat.Register("guildcreate", { args = { "string", "string" }, help = "Create a guild: /guildcreate <name> <tag>" }, function(caller: Player, args: { string }): string?
	if args[1] == nil or args[2] == nil then return "Usage: /guildcreate <name> <tag> (one word each, tag 2-4 letters)" end
	if not Data.IsLoaded(caller) then return LOADING end
	-- result = the guild id, or why it failed ("name too short", "tag too short", "already in a guild").
	local ok, result = Guild.Create(caller, args[1], args[2])
	if not ok then return `Could not create: {result}` end
	print(`[GuildCommands] {caller.Name} created guild {args[1]} ({result})`)
	return `Guild {args[1]} created. Invite with /guildinvite <player>`
end)
Chat.Register("guildinvite", { args = { "player" }, help = "Invite to your guild: /guildinvite <player>" }, function(caller: Player, args: { string }): string?
	if not Data.IsLoaded(caller) then return LOADING end
	local parsed = Chat.ParseArgs({ "player" }, args)
	local target: Player? = if parsed then parsed[1] else nil
	if target == nil then return "No player matches, or more than one does. Type more of the name." end
	local ok, reason = Guild.Invite(caller, target.UserId) -- Officer or Owner only
	return if ok then `Invited {target.Name}` else `Could not invite: {reason}`
end)
Chat.Register("guildjoin", { help = "Accept your guild invite: /guildjoin" }, function(caller: Player, _args: { string }): string?
	if not Data.IsLoaded(caller) then return LOADING end
	local invite = Guild.GetPendingInvites(caller)[1]
	if invite == nil then return "You have no guild invites" end
	local ok, reason = Guild.AcceptInvite(caller, invite.guildId)
	if not ok then return `Could not join: {reason}` end
	print(`[GuildCommands] {caller.Name} joined {invite.name}`)
	return `You joined {invite.name}`
end)

print("[GuildCommands] ready")
```

What it does: the creator is the `Owner`. `/guildinvite Bob` invites; Bob types `/guildjoin` and becomes a `Member`. Names over 24 letters and tags over 4 are cut.

## Step 4 — Show invites as toasts

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **SocialNotices**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/SocialNotices
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("UI.Toast"), "SocialNotices needs the UI.Toast package: install it (playbooks/start/01-install-packages.md)")
Gaxia.Net.OnClient("SocialNotice", function(text: any)
	print(`[SocialNotices] {tostring(text)}`)
	Gaxia.UI.Toast.Show({ Title = "Social", Text = tostring(text), Variant = "info", Duration = 6 })
end)
print("[SocialNotices] ready")
```

## Check that it works

1. Open **Test** → **Clients and Servers**, choose **2** players, press **Start** (one server window, two player windows `Player1`, `Player2`). The **server** Output shows a `ready` line for each server Script you created, and no red errors. Each player window shows `[SocialNotices] ready`.
2. **Player1** types `/friend Player2`. Player2 sees the toast `Player1 wants to be your friend. Type /accept Player1`. Player2 types `/accept Player1`: server Output shows `[FriendCommands] Player2 and Player1 are now friends`.
3. Player1 types `/party Player2`; Player2 types `/partyjoin Player1`. Server Output shows `[PartyCommands] Player2 joined party_1: 2 member(s)`.
4. Guild (API access needed): Player1 types `/guildcreate Wolves WLF`, then `/guildinvite Player2`; Player2 types `/guildjoin`: `You joined Wolves`.
5. Yellow `[InviteQueue] ... failed` lines in Studio without API access are expected: only the cross-server queue is off. An agent cannot run these 2-player tests: give the user these steps and say they are still open.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Accepting after the sender left the server | Accept while both are in the same server | The sender's list is only updated when the sender is in this server. |
| Relying on `UI.InviteToast` for Accept / Decline buttons | Toasts from Step 4 plus the chat commands | Today `UI.InviteToast` only warns `accept/decline unavailable`. It has no buttons. |
| No `PlayerRemoving` → `Party.Leave` | Keep those lines from Step 2 | Party never removes players who left the game. |
| `/partyjoin` after 60 seconds | Invite again with `/party` | The answer is `Could not join: no such invite or it expired`. |
| A friend, party or guild call before the data loads | `Data.IsLoaded` first (as in the commands) | Before it loads, nothing is saved and guild checks see "no guild". |

## Change it

- Friend list and guild panels: from a button in a LocalScript, `Gaxia.UI.FriendListPanel.Toggle()` (Friend package) or `Gaxia.UI.GuildPanel.Toggle()` (Guild package). Check `Gaxia.IsInstalled("UI.GuildPanel")` first.
- List friends: `Friend.GetList(player)` (online first; `{ userId, name, online, ... }`). Remove or block: `Friend.Remove(player, otherUserId)`, `Friend.Block(...)`, `Friend.Unblock(...)`; each returns `ok, reason`.
- Leave a party: `Party.Leave(player)`. Party size: `Party.SetMaxSize(6)` once at server start. Private server for a party: `Party.StartMatch(partyId, PLACE_ID)` ([multi-server](multi-server.md); not in Studio).
- Matchmaking between servers (MemoryStore, published place): each server calls `Party.QueueForMatch(partyId, "Duel", PLACE_ID)`; one server calls `Party.PollMatch("Duel", 4)` every few seconds. It returns `{ parties, accessCode, placeId }` or `nil`, and fires `Party.OnMatchFound`.
- Show a guild: `Guild.GetGuild(player)` (`{ Name, Tag, Id, ... }` or `nil`), `Guild.RoleOf(player)`. Roles: `Guild.Promote(owner, userId)`, `Guild.Demote(owner, userId)`, `Guild.Kick(officer, userId)`, `Guild.Transfer(owner, newOwnerUserId)`, `Guild.Disband(owner)`. The Owner cannot `Guild.Leave`: transfer or disband first.

## See also

- [API: Friend](../api/Friend.md) · [API: Party](../api/Party.md) · [API: Guild](../api/Guild.md) · [API: Chat](../api/Chat.md)
- [Admin and chat commands](admin-and-chat-commands.md) · [Multi-server](multi-server.md) · [UI and toasts](ui.md) · [Player data](player-data.md)
