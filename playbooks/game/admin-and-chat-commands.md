# Admin roles, admin commands and chat commands

> Staff with a role can type `/givecoins <player> <amount>` and use the F2 admin panel, and everyone can type `/rules` and `/coins`.

**Use this when** the user asks for: "admin commands", "admin panel", "make me admin", "moderator", "staff roles", "kick / ban command", "give coins command", "chat command", "slash command", "/command" (ไทย: "คำสั่งแอดมิน", "ให้ยศแอดมิน", "ทำให้เป็นแอดมิน", "แผงแอดมิน", "ม็อด", "ยศ", "คำสั่งแชท", "พิมพ์คำสั่งในแชท", "คำสั่งเสก"). Anti-cheat kicks and automatic bans: [anticheat-and-bans](anticheat-and-bans.md).
**Packages:** `Admin` (it also installs `Chat`, `Ban` and `Player`) and `Economy` (it also installs `Data`). `AntiCheatAdmin` is optional (it adds `/ac`, `/flag`, …). The scripts below stop with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/StaffRoles`, `ServerScriptService/StaffCommands` and `ServerScriptService/ChatCommands` (Rojo: `src/ServerScriptService/<Name>.server.lua`, see [02-server-script](../start/02-server-script.md)).

How it works:

- Roles, lowest to highest: `default` (everyone), `moderator`, `admin`, `owner`. A role can do everything a lower role can.
- The place creator gets `owner` automatically in a place owned by a **user**. In a group-owned place nobody does: use `STAFF` (Step 1).
- Admin saves roles in a DataStore, so the place must be **published**. Unpublished, every staff command answers "Permission denied.".
- `GaxiaServer.Admin.Register` makes a staff command (chat and F2 panel); `GaxiaServer.Chat.Register` one for **everyone**. A handler gets the typed words as strings (`/givecoins Bob 100` → `{ "Bob", "100" }`) and returns the chat line shown to the caller.

## Step 1 — Give your staff their roles

1. Publish the place (**File → Publish to Roblox**). Ask the user to turn on **Game Settings → Security → Enable Studio Access to API Services**. Until then a role lasts only until the server closes.
2. Create a **Script** in **ServerScriptService** named **StaffRoles** and paste the block below. Press **Play** once.
3. Read the `[StaffRoles] <YourName> (<UserId>) role = ...` line in Output. If the role is `default`, add `[<UserId>] = "owner"` to `STAFF`.
4. Ask the user for the other staff UserIds and roles. Add them to `STAFF`. Press **Play** again.

```lua
-- Script: ServerScriptService/StaffRoles
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Admin"), "StaffRoles needs the Admin package: install it (playbooks/start/01-install-packages.md)")

local Admin = GaxiaServer.Admin

-- Your staff: [UserId] = role. Roles: "moderator", "admin", "owner".
-- A UserId is the number in a profile link: roblox.com/users/<UserId>/profile
local STAFF: { [number]: string } = {
	-- [123456789] = "admin",
}
-- Former staff: their UserIds. Their saved role goes back to "default". Leave them here.
local REMOVED: { number } = {
	-- 123456789,
}
for _, userId in REMOVED do
	Admin.SetRole(userId, "default")
	print(`[StaffRoles] {userId} is no longer staff`)
end

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

What it does: a listed player gets their role when they join. Output shows every player's UserId and role.
To remove a staff member: delete their `STAFF` line **and** add their UserId to `REMOVED`, then Play.

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

-- /givecoins <player> <amount> — for admin and owner. In admin commands "me" means yourself.
Admin.Register("givecoins", {
	role = "admin",
	args = { "player", "number" }, -- the input boxes shown in the F2 panel
	help = "Give Coins: /givecoins <player> <amount>",
}, function(_caller: Player, args: { string }): (string?, boolean?)
	local parsed = Chat.ParseArgs({ "player", "number" }, args)
	if parsed == nil or parsed[1] == nil or parsed[2] == nil then
		return "Usage: /givecoins <player> <amount> (the player must be in this server)", true
	end
	local target: Player = parsed[1]
	local amount: number = math.floor(parsed[2])
	-- Economy refuses more than "Economy.MaxTransaction" per call. Read it here: a game can change it.
	local max = Economy.GetMaxTransaction()
	if not (amount >= 1 and amount <= max) then
		return `The amount must be 1 to {max}`, true
	end
	if not Economy.Add(target, "Coins", amount) then
		return `{target.Name}'s data is not loaded yet: try again`, true
	end
	return `Gave {amount} Coins to {target.Name} (now {Economy.Get(target, "Coins")})`, false
end)

-- Adds /acflags /acclear /acban /acunban /ac /flag (only with the AntiCheatAdmin package).
-- Safe to call again from another script: the commands are added only once.
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
An admin handler always returns two values: the message, then `true` (failed: red in the panel, `success = false`) or `false` (worked).

## Step 3 — Add chat commands for everyone: /rules and /coins

Create a **Script** in **ServerScriptService** named **ChatCommands**:

```lua
-- Script: ServerScriptService/ChatCommands
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Chat"), "ChatCommands needs the Chat package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Economy"), "ChatCommands needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Chat = GaxiaServer.Chat
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy

local RULES = "Rules: be kind, no cheating, have fun!"
-- /rules — no roles, so everyone can use it.
Chat.Register("rules", { help = "Show the game rules" }, function(_caller: Player, _args: { string }): string?
	return RULES
end)

-- /coins [player] — without a name (or with "me") it shows your own Coins.
Chat.Register("coins", { args = { "player" }, help = "Show Coins: /coins [player]" }, function(caller: Player, args: { string }): string?
	local target = caller
	if args[1] ~= nil and args[1]:lower() ~= "me" then
		local parsed = Chat.ParseArgs({ "player" }, args)
		if parsed == nil then
			return `No player named "{args[1]}" in this server`
		end
		target = parsed[1]
	end
	-- Before the data loads, Economy.Get returns 0: do not show that number.
	if not Data.IsLoaded(target) then
		return `{target.Name}'s data is still loading: try again`
	end
	return `{target.Name} has {Economy.Get(target, "Coins")} Coins`
end)

-- One Output line per typed command. Admin commands typed in chat also show "ran" here,
-- even when they failed: their real result is in the [StaffCommands] line.
Chat.OnCommand:Connect(function(caller: Player, name: string, _args: { string }, success: boolean)
	print(`[ChatCommands] {caller.Name} typed /{name} ({if success then "ran" else "unknown or denied"})`)
end)

print("[ChatCommands] ready")
```

What it does: the returned text appears only in the caller's chat. Nobody else sees the command.

## Step 4 — Use the admin panel (F2)

No code. Press **F2** in game (or click the **🛡 Admin** button, top left, shown to moderators and up). No button after a role change? Press F2, or rejoin.
Tabs: **Commands** (every command your role may run, `givecoins` too), **Players** (click a player, then an action), **Audit** (the last 50 admin commands since you joined).
The server checks the role again for every click, so a cheater cannot use the panel.

## Check that it works

Agent: check your scripts against Steps 1–3. The user runs these in Studio. No Studio? Send: "Please press Play, do the checks in the playbook, and paste the Output lines that start with `[StaffRoles]`, `[StaffCommands]` and `[ChatCommands]`."

1. Press **Play** in Studio.
2. Output shows `[StaffRoles] ready`, `[StaffCommands] ready`, `[ChatCommands] ready`, and no red errors.
3. Output shows `[StaffRoles] <YourName> (<id>) role = owner`. If it says `default`, do Step 1 item 3.
4. In chat, type `/givecoins me 100`. Chat shows `Gave 100 Coins to <YourName> (now <total>)`. Output shows `[StaffCommands] <YourName> ran /givecoins: ok — Gave 100 Coins ...` and `[ChatCommands] <YourName> typed /givecoins (ran)`.
5. Type `/rules`, then `/coins`. Chat shows the rules, then `<YourName> has <total> Coins`.
6. Press **F2**. The panel opens; the **Commands** tab lists `givecoins`.
7. Test as a normal player: **Test** tab → **Clients and Servers** → 1 player → **Start**. In the player window type `/givecoins me 5`. Chat shows `Permission denied.` (test players have UserIds -1, -2, …, so they are never the owner).

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `if player.Name == "MyName" then` | `Admin.IsAtLeast(player, "admin")` | Names change; roles are checked the same way everywhere. |
| A staff command made with `Chat.Register(name, { roles = { "admin" } }, ...)` | `Admin.Register(name, { role = "admin" }, ...)` | Only `Admin.Register` adds it to the F2 panel, the audit log and the anti-cheat grace. |
| `local amount = args[2]` used as a number | `Chat.ParseArgs({ "player", "number" }, args)` | Every arg is a string. `"100"` is not `100`. |
| `return "Player not found"` in an admin handler | `return "Player not found", true` | Without `true` the failure counts as a success (green in the panel). Always return two values. |
| No range check on an amount | `if not (amount >= 1 and amount <= max) then` | `/givecoins me nan` or `-5` must be refused. |
| A command named `help`, `kick`, `ban`, `give`, `role`, …, or one name in both `Chat.Register` and `Admin.Register` | A new name, such as `givecoins` | The later one replaces the other, with no warning. |
| Only deleting someone's `STAFF` line, or only `/role <player> default` | Delete the `STAFF` line **and** add the UserId to `REMOVED` | The role is saved in a DataStore, and a `STAFF` line gives it back on every join. |
| "Permission denied." for your own staff command in Studio | Publish the place, then Play | Admin cannot start in an unpublished place. |
| Testing "normal player" behaviour alone in **Play** as the place owner | **Clients and Servers** test players | The owner may run everything and is never auto-kicked. |

## Change it

- **Built-in staff commands** (lowest role): moderator: `/kick <player> [reason]`, `/teleport <player> <toPlayer>` (alias `/tp`), `/heal <player>`, `/respawn <player>`.
  admin: `/speed <player> <number>` (alias `/sp`), `/ban <player> [reason]` (permanent), `/unban <userId>`, `/give <player> <itemId> [count]` (without the `Item` package it answers "/give needs the Item package").
  owner: `/role <player> <role>` (only roles below your own; it cannot demote another owner: use `REMOVED`).
- **AntiCheatAdmin commands:** `/acflags <player>` (moderator); `/acclear <player>`, `/acban <player> <reason> [seconds]`, `/acunban <userId>`, `/ac <on|off|status|reset> [Detector]`, `/flag <set|get|clear> <key> [value]` (admin). The `/acban` reason is one word, or in quotes: `/acban Bob "speed hacking" 3600`. See [anticheat-and-bans](anticheat-and-bans.md).
- **Everyone:** `/help` lists all command names, `/help <name>` shows one. `/credits`. Nobody can kick, ban or change the role of themselves, the place owner, or an equal or higher role.
- To let moderators use `/givecoins`: change `role = "admin"` to `role = "moderator"`.
- Custom role names (such as `helper`) need `Config.Admin.Tiers`, which a game cannot change today: use `moderator`, `admin` or `owner`. For `Config.Admin.Bootstrap` and `AutoGrantCreator`, use `STAFF` instead.
- To check a role in server code: `Admin.IsAtLeast(player, "moderator")`. To make your own kick/ban command safe: `local blocked = Admin.ProtectTarget(caller, target)`; if `blocked` is a string, `return blocked, true`.
- To open the panel from your own button (LocalScript): `Gaxia.UI.AdminPanel.Open()` (also `Close`, `Toggle`).
- **Chat without Admin** (Admin not installed): commands without `roles` work; commands with `roles` always answer "Permission denied.".
- Staff are not flagged by the anti-cheat for 30 seconds after an admin command (caller and target), so `/speed` and `/tp` are safe.

## See also

- [API: Admin](../api/Admin.md) · [API: Chat](../api/Chat.md) · [API: AntiCheatAdmin](../api/AntiCheatAdmin.md)
- [Anti-cheat and bans](anticheat-and-bans.md) · [Currency and leaderstats](currency-and-leaderstats.md) · [Config and flags](config-and-flags.md)
