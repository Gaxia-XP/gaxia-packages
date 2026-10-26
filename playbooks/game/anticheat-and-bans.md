# Anti-cheat (observe → enforce) and bans

> Output shows every anti-cheat flag, a speed pad boosts players without being flagged, and you can turn on kicking and ban or unban players.

**Use this when** the user asks for: "anti-cheat", "anticheat", "stop exploiters", "speed hack", "fly hack", "kick cheaters", "ban", "unban", "temp ban", "players get kicked", "false positive", "flagged" (ไทย: "กันโกง", "ระบบกันโปร", "โปรโกง", "กันแฮก", "สปีดแฮก", "แบน", "ปลดแบน", "แบนชั่วคราว", "เตะคนโกง", "โดนเตะเอง").
**Packages:** `AntiCheatAdmin` (it also installs `AntiCheat`, `Ban`, `Journal`, `Admin` and `Player`). The scripts below stop with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/AntiCheatLog`, `ServerScriptService/SpeedPad` and (Step 4) `ServerScriptService/AntiCheatEnforce`.

How it works:

- The anti-cheat runs on the server. Every 0.5 s its detectors check each player (Speed, Fly, NoClip, Teleport, …).
- A finding is a **flag**: a reason (`"Speed"`), a severity (`"soft"` or `"hard"`) and a count for this player.
- 3 soft flags with one reason → a **soft action** (a warning only). One hard flag, or 5 of one reason → a **hard action**.
- It starts in **observe mode**: a hard action only warns `[AntiCheat] observe mode — would take HARD action ...`. Nobody is kicked. In **enforce mode** (Step 4) a hard action kicks.
- Never punished automatically: the place owner, and players with the `admin` role or higher. Counts go down by 1 every 60 s and reset when the player leaves.

## Step 1 — Log every flag and action

Create a **Script** in **ServerScriptService** named **AntiCheatLog**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/AntiCheatLog
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("AntiCheatAdmin"), "AntiCheatLog needs the AntiCheatAdmin package: install it (playbooks/start/01-install-packages.md)")

local AntiCheat = GaxiaServer.AntiCheat
local Ban = GaxiaServer.Ban
local Journal = GaxiaServer.Journal

-- Adds the staff commands /acflags /acclear /acban /acunban /ac /flag.
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

-- The Journal keeps every entry. Its own Output line is turned off (this script prints instead).
Journal.SetSink(function(_entry) end)

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
	part.Position = Vector3.new(0, 0.5, -20)
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

What it does: touching the green pad (20 studs from the center of the map) gives 5 seconds of speed 40, with no `Speed` flag.

## Step 3 — Play-test as a normal player and read the flags

The place owner is never kicked, so test with other players:
1. **Test** tab → **Clients and Servers** → 1 player → **Start**.
2. In the player window, walk, jump, use the speed pad, play your game normally.
3. In the **Server** window's Output, read the `[AntiCheatLog] flag ...` lines.

No flags during normal play means the game is ready for Step 4. A flag during normal play is a false positive: fix it with the table in **Common mistakes** first.

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
To try it in one running server first, an admin types `/flag set AntiCheat.Enforce true` (`/flag clear AntiCheat.Enforce` undoes it).

## Step 5 — Ban and unban

No code. Staff type these in chat (or use the F2 panel):

- `/ban <player> <reason>`: permanent ban (admin).
- `/acban <player> <reason> 3600`: ban for 3600 seconds; leave out the number for permanent (admin).
- `/unban <userId>` or `/acunban <userId>`: remove a ban (admin). The UserId is in the `[AntiCheatLog] banned ...` line.

From server code, use `GaxiaServer.Ban`:

```lua
-- fragment
local saved = Ban.Ban(player.UserId, "Exploiting", 86400) -- 1 day; leave out 86400 for permanent. Kicks now.
local banned, reason, expiresAt = Ban.IsBanned(userId)    -- banned players are kicked when they join
Ban.Unban(userId)
```

`Ban.Ban` returns `false` when the ban could not be saved (Studio without API access): it then lasts until the server closes.

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[AntiCheatLog] ready, enforcing = false`, `[SpeedPad] ready`, and no red errors. After Step 4: `[AntiCheatEnforce] enforcing = true`.
3. Walk onto the green pad. Output shows `[SpeedPad] <YourName> boosted to 40`, then `back to 16`, and no `[AntiCheatLog] flag` line.
4. Type `/ac status`. Chat shows `AntiCheat ON · disabled detectors: HumanoidState`.
5. Type `/acflags me`. Chat shows `<YourName>: no flags` (or the list of flags).

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `humanoid.WalkSpeed = 40` in a LocalScript | `GaxiaServer.Player.SetWalkSpeed(player, 40)` on the server | The server sees a player faster than its WalkSpeed: `Speed` flags. |
| `character.HumanoidRootPart.CFrame = cframe` / `character:PivotTo(cframe)` | `GaxiaServer.Player.Teleport(player, cframe)` | A big jump is a **hard** `Teleport` flag: kicked in enforce mode. |
| A launch pad or knockback with `AssemblyLinearVelocity` | First `AntiCheat.Whitelist(player, "Fly", 3)` and `AntiCheat.Whitelist(player, "Speed", 3)` | Forgives those reasons for 3 seconds. |
| `player.leaderstats.Coins.Value = 10` | `Economy.Add` / `GaxiaServer.Player.SetLeaderstat` | A hard `StatTamper` flag ([currency](currency-and-leaderstats.md)). |
| `Instance.new("Tool")` or `:Clone()` into the Backpack | `GaxiaServer.Tool.Create` ([items](items-and-inventory.md)) | A hard `Backpack` flag. |
| Writing to `_G` or `shared` in a LocalScript | A ModuleScript in ReplicatedStorage | The client check reports `ClientReport:GlobalPollution` every 30 s. |
| Removing `AntiCheat` from `ReplicatedStorage/GaxiaClientFeatures` | Keep `{ Key = "AntiCheat", RequiresServer = "AntiCheat" }` | No client heartbeat: every player gets `Heartbeat` flags. |
| Testing enforce as the place owner (or an admin) | **Clients and Servers** test players | Owners and admins are never kicked or auto-banned. |
| `/ac off Stat` to stop `StatTamper` flags | Fix the cause, or `AntiCheat.Whitelist(player, "StatTamper")` | `/ac off` only stops Speed, Fly, NoClip, Teleport, Heartbeat, Heuristic, WorldBounds, HumanoidState. |
| Setting `Enforce = true` inside `Gaxia_Packages_Server/Config` | `AntiCheatEnforce` (Step 4) | Install / Update replaces the package. |

## Change it

- To turn one detector off on every server: add `GaxiaServer.AntiCheat.SetDetectorEnabled("Fly", false)` to `AntiCheatEnforce`. Live, in one server: `/ac off Fly`. The whole anti-cheat: `/ac off` / `/ac on`. `/ac reset` undoes every `/ac on` / `/ac off`.
- Detector names: `Speed`, `Fly`, `NoClip`, `Teleport`, `Heartbeat`, `Heuristic`, `WorldBounds`, `HumanoidState` (off by default), `Animation`, `Backpack`, `Combat`, `Stat`, `ToolDupe`, `RemoteRate`, `ExploitSig`.
- To forgive one reason for one player: `AntiCheat.Whitelist(player, "Teleport", 5)` (seconds; no number = this whole session).
- To flag something from your own code (for example an impossible score): `AntiCheat.Flag(player, "ImpossibleScore", "hard")`. It counts like any other flag.
- To clear a player's flags: `/acclear <player>` or `AntiCheat.ClearFlags(player)`.
- To send flags to Discord or a DataStore: replace the empty function in `Journal.SetSink(...)` with your own ([webhooks](webhooks-and-analytics.md)).
- Automatic bans (`BanPolicy` in `GaxiaServer.Config.AntiCheat`): in enforce mode the first hard action in a session kicks. Strikes reset when the player leaves, so with the default policy the anti-cheat kicks but never bans. Ban repeat cheaters yourself with `/acban`.

## See also

- [API: AntiCheat](../api/AntiCheat.md) · [API: Ban](../api/Ban.md) · [API: Journal](../api/Journal.md) · [API: AntiCheatAdmin](../api/AntiCheatAdmin.md)
- [Admin and chat commands](admin-and-chat-commands.md) · [Config and flags](config-and-flags.md) · [Add an anti-cheat detector](../framework/add-an-anticheat-detector.md) · [Troubleshooting](../troubleshooting.md)
