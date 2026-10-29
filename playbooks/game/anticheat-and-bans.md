# Anti-cheat (observe → enforce) and bans

> Output shows every anti-cheat flag, a speed pad boosts players without being flagged, and you can turn on kicking and ban or unban players.

**Use this when** the user asks for: "anti-cheat", "anticheat", "stop exploiters", "speed hack", "fly hack", "kick cheaters", "ban", "unban", "temp ban", "players get kicked", "false positive", "flagged" (ไทย: "กันโกง", "ระบบกันโปร", "โปรโกง", "กันแฮก", "สปีดแฮก", "แบน", "ปลดแบน", "แบนชั่วคราว", "เตะคนโกง", "โดนเตะเอง"). Staff roles and a custom staff command: [admin-and-chat-commands](admin-and-chat-commands.md).
**Packages:** `AntiCheatAdmin` (it also installs `AntiCheat`, `Ban`, `Journal`, `Admin` and `Player`). The scripts below stop with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/AntiCheatLog`, `ServerScriptService/SpeedPad` and (Step 4) `ServerScriptService/AntiCheatEnforce` (Rojo: `src/ServerScriptService/<Name>.server.lua`).

How it works:

- The anti-cheat runs on the server. Every 0.5 s its detectors check each player. A finding is a **flag**: a reason (`"Speed"`), a severity (`"soft"` or `"hard"`) and a count for this player.
- 3 soft flags with one reason → a **soft action** (a warning only). One hard flag, or 5 of one reason → a **hard action**.
- It starts in **observe mode**: a hard action only warns `[AntiCheat] observe mode — would take HARD action ...`. In **enforce mode** (Step 4) a hard action kicks.
- Never punished automatically: the place owner, and players with the `admin` role or higher. Counts go down by 1 every 60 s and reset when the player leaves.

## Step 1 — Log every flag and action

Create a **Script** in **ServerScriptService** named **AntiCheatLog**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/AntiCheatLog
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("AntiCheatAdmin"), "AntiCheatLog needs the AntiCheatAdmin package: install it (playbooks/start/01-install-packages.md)")

local AntiCheat = GaxiaServer.AntiCheat
local Ban = GaxiaServer.Ban
local Journal = GaxiaServer.Journal

-- Adds the staff commands /acflags /acclear /acban /acunban /ac /flag.
-- Safe to call again from another script: the commands are added only once.
GaxiaServer.AntiCheatAdmin.Register()

-- Every flag: who, why, how bad, and how many times this session.
AntiCheat.OnFlag:Connect(function(player: Player, reason: string, severity: string, count: number)
	print(`[AntiCheatLog] flag {player.Name}: {reason} ({severity}) x{count}`)
end)

-- "soft" = warning only, "observe" = would kick (observe mode), "hard" = kick.
AntiCheat.OnAction:Connect(function(player: Player, reason: string, kind: string)
	if kind == "hard" then
		warn(`[AntiCheatLog] HARD action against {player.Name}: {reason} (kicked unless exempt)`)
	elseif kind == "observe" then
		warn(`[AntiCheatLog] would kick {player.Name}: {reason} (observe mode, nothing done)`)
	else
		print(`[AntiCheatLog] soft action against {player.Name}: {reason}`)
	end
end)
-- Bans from commands, from code, or from the automatic policy.
Ban.OnBan:Connect(function(userId: number, ban)
	local untilText = if ban.expiresAt then os.date("!%Y-%m-%d %H:%M UTC", ban.expiresAt) else "forever"
	warn(`[AntiCheatLog] banned {userId} until {untilText}: {ban.reason}`)
end)
Ban.OnUnban:Connect(function(userId: number)
	print(`[AntiCheatLog] unbanned {userId}`)
end)
-- The Journal keeps each player's last 100 entries. It prints nothing itself (this script prints instead).
Players.PlayerRemoving:Connect(function(player: Player)
	print(`[AntiCheatLog] {player.Name} left with {#Journal.GetForPlayer(player)} anti-cheat entries`)
end)

print(`[AntiCheatLog] ready, enforcing = {AntiCheat.IsEnforcing()}`)
```

What it does: Output shows one line per flag and per action. `/acflags <player>` shows the same history in chat.

## Step 2 — Give speed the right way (a speed pad)

Create a **Script** in **ServerScriptService** named **SpeedPad**:

```lua
-- Script: ServerScriptService/SpeedPad
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Player"), "SpeedPad needs the Player package: install it (playbooks/start/01-install-packages.md)")

local PlayerService = GaxiaServer.Player

local BOOST_SPEED = 40
local NORMAL_SPEED = 16
local BOOST_SECONDS = 5

-- The pad: a part in Workspace named SpeedPad. Made here if it does not exist.
local function getPad(): BasePart
	local existing = Workspace:FindFirstChild("SpeedPad")
	if existing and existing:IsA("BasePart") then
		return existing
	end
	local part = Instance.new("Part")
	part.Name = "SpeedPad"
	part.Size = Vector3.new(8, 1, 8)
	part.Position = Vector3.new(24, 0.5, 0) -- 24 studs from the middle of the Baseplate, toward +X
	part.Anchored = true
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(80, 255, 120)
	part.Parent = Workspace
	return part
end

local boosted: { [Player]: boolean } = {}

getPad().Touched:Connect(function(hit: BasePart)
	local character = hit:FindFirstAncestorOfClass("Model")
	local player = if character then Players:GetPlayerFromCharacter(character) else nil
	if player == nil or boosted[player] then
		return
	end
	boosted[player] = true
	-- The SERVER sets WalkSpeed, so the Speed detector expects the faster movement.
	PlayerService.SetWalkSpeed(player, BOOST_SPEED)
	print(`[SpeedPad] {player.Name} boosted to {BOOST_SPEED}`)
	task.delay(BOOST_SECONDS, function()
		boosted[player] = nil
		if player.Parent ~= nil then
			PlayerService.SetWalkSpeed(player, NORMAL_SPEED)
			print(`[SpeedPad] {player.Name} back to {NORMAL_SPEED}`)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	boosted[player] = nil
end)

print("[SpeedPad] ready")
```

What it does: touching the green pad (24 studs from the middle of the Baseplate, toward +X) gives 5 seconds of speed 40, with no `Speed` flag.

## Step 3 — Play-test as a normal player and fix false positives

The place owner is never kicked, so test with other players: **Test** tab → **Clients and Servers** → 1 player → **Start**. In the player window, play your game normally. In the **Server** window's Output, read the `[AntiCheatLog] flag ...` lines.
No flags means the game is ready for Step 4. A flag during normal play is a false positive. For each one:
1. Read the reason: `flag <Name>: <reason> (...)`.
2. Find its detector in this table.
3. Do the **Right** column of the matching row in **Common mistakes**.
4. No row fits? Stop. Tell the user the reason, the detector, and what the player was doing.

| Reason in the flag line | Detector | `/ac off <Detector>` works? |
|---|---|---|
| `Speed`, `Fly`, `NoClip`, `Teleport`, `Heartbeat`, `WorldBounds` | same as the reason | Yes |
| `Heuristic:SustainedSpeed` / `HumanoidState:<kind>` | `Heuristic` / `HumanoidState` (off by default) | Yes |
| `StatTamper` | `Stat` | Yes |
| `Backpack`, `ToolDupe`, `Combat`, `Animation`, `RemoteRate` | same as the reason | Yes |
| `ClientReport:<kind>` | `ExploitSig` | Yes |
| `RemoteRate:<remote>`, `RemoteValidation:<remote>` | your `Net` remotes ([04-client-server](../start/04-client-server-communication.md)) | No: always on |

Prefer fixing the cause, or forgive one player: `AntiCheat.Whitelist(player, reason, seconds)`. Turning a detector off stops it for everyone.

## Step 4 — Turn on enforce (kick on hard actions)

Do this step only when the user asks to kick cheaters, and only after Step 3 shows no flags. Create a **Script** in **ServerScriptService** named **AntiCheatEnforce**:

```lua
-- Script: ServerScriptService/AntiCheatEnforce
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("AntiCheat"), "AntiCheatEnforce needs the AntiCheat package: install it (playbooks/start/01-install-packages.md)")

-- Runs when every server starts, so every server enforces.
GaxiaServer.EConfig.Set("AntiCheat.Enforce", true)

print(`[AntiCheatEnforce] enforcing = {GaxiaServer.AntiCheat.IsEnforcing()}`)
```

What it does: a hard action now kicks the player. Admins and the owner are still never kicked.

## Step 5 — Ban and unban

No code. Staff with the `admin` role type these in chat (or use the F2 panel). You are `owner` in a published place you own; otherwise add your UserId to `STAFF` ([admin-and-chat-commands](admin-and-chat-commands.md) Step 1).

- `/acban <player> <reason> 3600`: ban for 3600 seconds, for example `/acban Bob speed hacking 3600`. The reason can be several words; a number at the end is the seconds, or use a unit: `30m`, `1h`, `2d`, `1w` (`/acban Bob speed hacking 1h`). Leave out the duration for a permanent ban.
- `/acunban <userId>`: remove a ban. The UserId is in the `[AntiCheatLog] banned ...` line.

## Check that it works

Agent: check your scripts against Steps 1–4. The user runs these in Studio. No Studio? Send: "Please press Play, do the checks in the playbook, and paste the Output lines that start with `[AntiCheatLog]` and `[SpeedPad]`."

1. Press **Play** in Studio.
2. Output shows `[AntiCheatLog] ready, enforcing = false` (`true` once you did Step 4), `[SpeedPad] ready`, and no red errors. After Step 4: `[AntiCheatEnforce] enforcing = true`.
3. Walk onto the green pad. Output shows `[SpeedPad] <YourName> boosted to 40`, then `back to 16`, and no `[AntiCheatLog] flag` line.
4. Steps 4–5 need the `admin` role (see Step 5). Type `/ac status`. Chat shows `AntiCheat ON · disabled detectors: HumanoidState`.
5. Type `/acflags me`. Chat shows `<YourName>: no flags` (or the list of flags).

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `humanoid.WalkSpeed = 40` in a LocalScript | `GaxiaServer.Player.SetWalkSpeed(player, 40)` on the server | The server sees a player faster than its WalkSpeed: `Speed` flags. |
| `character.HumanoidRootPart.CFrame = cframe` / `character:PivotTo(cframe)` | `GaxiaServer.Player.Teleport(player, cframe)` | A big jump is a **hard** `Teleport` flag: kicked in enforce mode. |
| A launch pad or knockback with `AssemblyLinearVelocity` | First `AntiCheat.Whitelist(player, "Teleport", 3)` and `AntiCheat.Whitelist(player, "Speed", 3)` (also `"Fly"` if the flag says `Fly`) | A launch over ~100 studs/s is a hard `Teleport` flag: kicked in enforce mode. |
| Whitelisting `"Speed"` / `"Teleport"` for long drops, cars or seats | Nothing to do | `Speed` and `Teleport` skip players sitting on a `Seat`/`VehicleSeat` (`Humanoid.SeatPart`). While falling, `Teleport` ignores the drop and `Speed` allows 2x its limit (`Config.AntiCheat.Speed.FreefallMultiplier`). |
| `player.leaderstats.Coins.Value = 10` | `Economy.Add` / `GaxiaServer.Player.SetLeaderstat` | A hard `StatTamper` flag ([currency](currency-and-leaderstats.md)). |
| `Instance.new("Tool")` or `:Clone()` into the Backpack | `GaxiaServer.Tool.Create` ([items](items-and-inventory.md)) | A hard `Backpack` flag. |
| Writing to `_G` or `shared` in a LocalScript | A ModuleScript in ReplicatedStorage | The client reports `ClientReport:GlobalPollution` every 30 s; after 5 reports it is a hard action (kick in enforce mode). |
| A `ReplicatedStorage/GaxiaClientFeatures` module without the anti-cheat entry | Only if your place has that module: it returns `{ Client = { ... } }` and must keep `{ Key = "AntiCheat", RequiresServer = "AntiCheat" }` | No client heartbeat: every player gets `Heartbeat` flags. |
| Testing enforce as the place owner (or an admin) | **Clients and Servers** test players | Owners and admins are never kicked or auto-banned. |
| `/ac off Stat` to stop `StatTamper` flags | Fix the cause (`Economy.Add` / `SetLeaderstat`), or `AntiCheat.Whitelist(player, "StatTamper")` | `/ac off Stat` stops the check for every player: real stat tampering is then never flagged. |
| `/acban Bob 3600` for a 1-hour ban | `/acban Bob <reason> 3600` or `/acban Bob 1h` | A bare number right after the name is read as the reason and the ban is permanent. A unit (`1h`, `30m`) right after the name is a timed ban. |
| "Permission denied." for `/ac` or `/acban` | Give yourself a role (`STAFF` in [admin-and-chat-commands](admin-and-chat-commands.md)) | These commands need `admin` (`/acflags`: `moderator`). |

## Change it

- To try enforce in one running server first: an admin types `/flag set AntiCheat.Enforce true` (`/flag clear AntiCheat.Enforce` undoes it).
- To turn one detector off on every server: create a Script `ServerScriptService/AntiCheatSettings` with the require line and `GaxiaServer.AntiCheat.SetDetectorEnabled("Fly", false)`. Live, in one server: `/ac off Fly`. The whole anti-cheat: `/ac off` / `/ac on`. `/ac reset` undoes every `/ac on` / `/ac off` (and `AntiCheatSettings`, until the next server start).
- To forgive one reason for one player: `AntiCheat.Whitelist(player, "Teleport", 5)` (seconds; no number = this whole session). To clear a player's flags: `/acclear <player>` or `AntiCheat.ClearFlags(player)`.
- To flag something from your own code (for example an impossible score): `AntiCheat.Flag(player, "ImpossibleScore", "hard")`. It counts like any other flag.
- To ban from server code: `local Ban = GaxiaServer.Ban`, then `Ban.Ban(player.UserId, "Exploiting", 86400)` (seconds; leave out for permanent; kicks now). `Ban.IsBanned(userId)` and `Ban.Unban(userId)`. `Ban.Ban` returns `false` when the ban could not be saved (Studio without API access). In chat, `/ban <player> [reason]` (permanent; the rest of the line is the reason) and `/unban <userId>` also work.
- To send flags to Discord or a DataStore: `Journal.OnEntry:Connect(function(entry) ... end)` ([webhooks](webhooks-and-analytics.md)). To see every entry in Output: `Journal.SetSink(Journal.WarnSink)`.
- Automatic bans (`BanPolicy` in `GaxiaServer.Config.AntiCheat`): in enforce mode each hard action is a strike. Strikes last for the whole server: with the default policy strike 1 kicks, strike 2 (after a rejoin to the same server) bans for 1 hour, strike 3 bans forever. A new server starts at 0. `/acunban`, `Ban.Unban` and `/acclear` reset the player's strikes (`Ban.ResetStrikes(userId)` from code).

## See also

- [API: AntiCheat](../api/AntiCheat.md) · [API: Ban](../api/Ban.md) · [API: Journal](../api/Journal.md) · [API: AntiCheatAdmin](../api/AntiCheatAdmin.md)
- [Combat and enemy NPCs](combat-and-npcs.md) (enemy hits with `RegisterDamage`) · [Admin and chat commands](admin-and-chat-commands.md) · [Config and flags](config-and-flags.md) · [Add an anti-cheat detector](../framework/add-an-anticheat-detector.md) · [Troubleshooting](../troubleshooting.md)
