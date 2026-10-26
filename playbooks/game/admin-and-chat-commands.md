# Admin roles, admin commands and chat commands

> Staff with a role can type `/givecoins <player> <amount>` and use the F2 admin panel, and everyone can type `/rules` and `/coins`.

**Use this when** the user asks for: "admin commands", "admin panel", "make me admin", "moderator", "staff roles", "kick / ban command", "give coins command", "chat command", "slash command", "/command" (ไทย: "คำสั่งแอดมิน", "ให้ยศแอดมิน", "ทำให้เป็นแอดมิน", "แผงแอดมิน", "ม็อด", "ยศ", "คำสั่งแชท", "พิมพ์คำสั่งในแชท", "คำสั่งเสก").
**Packages:** `Admin` (it also installs `Chat`, `Ban` and `Player`) and `Economy`. `AntiCheatAdmin` is optional (it adds `/ac`, `/flag`, …). The scripts below stop with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/StaffRoles`, `ServerScriptService/StaffCommands` and `ServerScriptService/ChatCommands`.

How it works:

- Every player has one role. Roles, lowest to highest: `default` (everyone), `moderator`, `admin`, `owner`. A role can do everything a lower role can.
- The place owner gets `owner` automatically, but only in a **published** place owned by a **user** (not a group). Everyone else starts as `default`.
- `GaxiaServer.Admin.Register(name, opts, handler)` makes a staff command. It works in chat (`/name ...`) and in the F2 admin panel. `opts.role` is the lowest role allowed.
- `GaxiaServer.Chat.Register(name, opts, handler)` makes a command for **everyone** (leave out `roles`).
- A handler gets the typed words as strings (`/givecoins Bob 100` → `{ "Bob", "100" }`). `GaxiaServer.Chat.ParseArgs` turns them into a Player and numbers.
- The text a handler returns is shown to the caller as a chat line. An admin handler returns `message, true` when it **failed** and `message, false` when it worked.

## Step 1 — Give your staff their roles

Create a **Script** in **ServerScriptService** named **StaffRoles**. Paste this whole block into it. Ask the user for the staff UserIds and roles, and add them to `STAFF` (leave it empty if there are none):

```lua
-- Script: ServerScriptService/StaffRoles
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Admin"), "StaffRoles needs the Admin package: install it (playbooks/start/01-install-packages.md)")

local Admin = GaxiaServer.Admin

-- Your staff: [UserId] = role. Roles: "moderator", "admin", "owner".
-- A UserId is the number in a profile link: roblox.com/users/<UserId>/profile
local STAFF: { [number]: string } = {
	-- [123456789] = "admin",
}

local function onPlayerAdded(player: Player)
	local role = STAFF[player.UserId]
	if role ~= nil and not Admin.IsAtLeast(player, role) then
		-- SetRole also saves the role, so it stays after a rejoin.
		Admin.SetRole(player.UserId, role)
	end
	print(`[StaffRoles] {player.Name} ({player.UserId}) role = {Admin.GetRole(player)}`)
end

-- Players who join later, and players who are already in the game.
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[StaffRoles] ready")
```

What it does: when a listed player joins, they get their role. Output shows every player's UserId and role.
Unpublished or group-owned place? Put your own UserId in `STAFF` as `"owner"`. Copy it from the `[StaffRoles]` line in Output.
Without **Enable Studio Access to API Services**, Output warns `failed to persist role`: the role still works until the server closes.

## Step 2 — Add an admin command: /givecoins

Create a **Script** in **ServerScriptService** named **StaffCommands**:

```lua
-- Script: ServerScriptService/StaffCommands
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Admin"), "StaffCommands needs the Admin package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Economy"), "StaffCommands needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Admin = GaxiaServer.Admin
local Chat = GaxiaServer.Chat
local Economy = GaxiaServer.Economy

-- Economy adds at most 1,000,000 per call.
local MAX_GIVE = 1000000

-- /givecoins <player> <amount> — for admin and owner. "me" works as the player name.
Admin.Register("givecoins", {
	role = "admin",
	args = { "player", "number" }, -- the input boxes shown in the F2 panel
	help = "Give Coins: /givecoins <player> <amount>",
}, function(_caller: Player, args: { string }): (string?, boolean?)
	-- Turn the typed words into a Player and a number (nil if a word does not fit).
	local parsed = Chat.ParseArgs({ "player", "number" }, args)
	if parsed == nil or parsed[1] == nil or parsed[2] == nil then
		return "Usage: /givecoins <player> <amount> (the player must be in this server)", true
	end
	local target: Player = parsed[1]
	local amount: number = math.floor(parsed[2])
	if not (amount >= 1 and amount <= MAX_GIVE) then
		return `The amount must be 1 to {MAX_GIVE}`, true
	end
	if not Economy.Add(target, "Coins", amount) then
		return `{target.Name}'s data is not loaded yet: try again`, true
	end
	-- false = it worked.
	return `Gave {amount} Coins to {target.Name} (now {Economy.Get(target, "Coins")})`, false
end)

-- Adds /acflags /acclear /acban /acunban /ac /flag when the AntiCheatAdmin package is installed.
if GaxiaServer.IsInstalled("AntiCheatAdmin") then
	GaxiaServer.AntiCheatAdmin.Register()
end

-- One Output line per admin command, from chat or from the F2 panel.
Admin.OnCommand:Connect(function(caller: Player, name: string, _args: { string }, success: boolean, message: string?)
	print(`[StaffCommands] {caller.Name} ran /{name}: {if success then "ok" else "FAILED"} — {message or ""}`)
end)

print("[StaffCommands] ready")
```

What it does: `/givecoins Bob 100` gives Bob 100 Coins. Players below `admin` get "Permission denied.".
An admin handler always returns two values: the message, then `true` (it failed) or `false` (it worked).
A failure shows red in the panel, and `OnCommand` gets `success = false`.

## Step 3 — Add chat commands for everyone: /rules and /coins

Create a **Script** in **ServerScriptService** named **ChatCommands**:

```lua
-- Script: ServerScriptService/ChatCommands
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Chat"), "ChatCommands needs the Chat package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Economy"), "ChatCommands needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Chat = GaxiaServer.Chat
local Economy = GaxiaServer.Economy

local RULES = "Rules: be kind, no cheating, have fun!"

-- /rules — no roles, so everyone can use it.
Chat.Register("rules", { help = "Show the game rules" }, function(_caller: Player, _args: { string }): string?
	return RULES
end)

-- /coins [player] — without a name it shows your own Coins.
Chat.Register("coins", { args = { "player" }, help = "Show Coins: /coins [player]" }, function(caller: Player, args: { string }): string?
	local target = caller
	if args[1] ~= nil then
		local parsed = Chat.ParseArgs({ "player" }, args)
		if parsed == nil then
			return `No player named "{args[1]}" in this server`
		end
		target = parsed[1]
	end
	return `{target.Name} has {Economy.Get(target, "Coins")} Coins`
end)

-- One Output line per typed command (also typos and denied commands).
Chat.OnCommand:Connect(function(caller: Player, name: string, _args: { string }, success: boolean)
	print(`[ChatCommands] {caller.Name} typed /{name} ({if success then "ok" else "unknown or denied"})`)
end)

print("[ChatCommands] ready")
```

What it does: the returned text appears only in the caller's chat. Nobody else sees the command.

## Step 4 — Use the admin panel (F2)

No code. Press **F2** in game (or click the **🛡 Admin** button, top left, shown to moderators and up).

- **Commands** tab: every command your role may run, with input boxes from `args`. `givecoins` is there.
- **Players** tab: click a player, then an action.
- **Audit** tab: every command run in this server and its result.

The server checks the role again for every click, so a cheater cannot use the panel.

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[StaffRoles] ready`, `[StaffCommands] ready`, `[ChatCommands] ready`, and no red errors.
3. Output shows `[StaffRoles] <YourName> (<id>) role = owner`. If it says `default`, add your UserId to `STAFF` as `"owner"`, then Play again.
4. In chat, type `/givecoins me 100`. Chat shows `Gave 100 Coins to <YourName> (now 100)`. Output shows `[StaffCommands] <YourName> ran /givecoins: ok — Gave 100 Coins ...`.
5. Type `/rules`, then `/coins`. Chat shows the rules, then `<YourName> has 100 Coins`.
6. Press **F2**. The panel opens; the **Commands** tab lists `givecoins`.
7. Test as a normal player: **Test** tab → **Clients and Servers** → 1 player → **Start**. In the player window type `/givecoins me 5`. Chat shows `Permission denied.` (test players are never the owner).

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `if player.Name == "MyName" then` | `Admin.IsAtLeast(player, "admin")` | Names change; roles are checked the same way everywhere. |
| A staff command made with `Chat.Register(name, { roles = { "admin" } }, ...)` | `Admin.Register(name, { role = "admin" }, ...)` | Only `Admin.Register` adds it to the F2 panel, the audit log and the anti-cheat grace. |
| `local amount = args[2]` used as a number | `Chat.ParseArgs({ "player", "number" }, args)` | Every arg is a string. `"100"` is not `100`. |
| `return "Player not found"` in an admin handler | `return "Player not found", true` | Without `true` the failure counts as a success (green in the panel). Always return two values. |
| No range check on an amount | `if not (amount >= 1 and amount <= MAX_GIVE) then` | `/givecoins me nan` or `-5` must be refused. |
| A command named `help`, `credits`, `kick`, `ban`, `give`, `role`, … | A new name, such as `givecoins` | The same name replaces the built-in command. |
| The same name in `Chat.Register` and `Admin.Register` | One name per command | The later one replaces the other in chat. |
| Editing `Config.Admin` inside `Gaxia_Packages_Server` | The `STAFF` table in `StaffRoles` | Install / Update replaces the package. |
| Removing someone from `STAFF` to demote them | `/role <player> default` while they are in the server | `SetRole` saved the role; removing the line changes nothing. |
| Testing "normal player" behaviour alone in **Play** as the place owner | **Clients and Servers** test players | The owner may run everything and is never auto-kicked. |

## Change it

- **Built-in staff commands** (role needed): `/kick <player> [reason]`, `/teleport <player> <toPlayer>` (alias `/tp`), `/heal <player>`, `/respawn <player>` (moderator); `/speed <player> <number>` (alias `/sp`), `/give <player> <itemId> [count]` (needs `Item`), `/ban <player> [reason]` (permanent), `/unban <userId>` (admin); `/role <player> <role>` (owner).
- **AntiCheatAdmin commands:** `/acflags <player>` (moderator); `/acclear <player>`, `/acban <player> <reason> [seconds]`, `/acunban <userId>`, `/ac <on|off|status|reset> [Detector]`, `/flag <set|get|clear> <key> [value]` (admin). See [anticheat-and-bans](anticheat-and-bans.md).
- **Everyone:** `/help` lists all command names, `/help <name>` shows one. `/credits`.
- Nobody can kick, ban or change the role of themselves, the place owner, or an equal or higher role. `/role` only grants roles below your own.
- To let moderators use `/givecoins`: change `role = "admin"` to `role = "moderator"`.
- To check a role in your own server code: `if Admin.IsAtLeast(player, "moderator") then ... end`.
- To make your own kick/ban command safe, ask the guard first: `local blocked = Admin.ProtectTarget(caller, target)`; if `blocked` is a string, `return blocked, true`.
- To open the panel from your own button (LocalScript): `Gaxia.UI.AdminPanel.Open()` (also `Close`, `Toggle`).
- **Chat without Admin** (Admin not installed): commands without `roles` work; commands with `roles` always answer "Permission denied.".
- Staff are not flagged by the anti-cheat for 30 seconds after an admin command (caller and target), so `/speed` and `/tp` are safe.

## See also

- [API: Admin](../api/Admin.md) · [API: Chat](../api/Chat.md) · [API: AntiCheatAdmin](../api/AntiCheatAdmin.md)
- [Anti-cheat and bans](anticheat-and-bans.md) · [Currency and leaderstats](currency-and-leaderstats.md) · [Config and flags](config-and-flags.md)
