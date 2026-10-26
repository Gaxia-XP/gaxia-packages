# Add a built-in anti-cheat detector

> The framework's anti-cheat has a new detector, `Hover`: it samples every player, flags hovering, has a Config section, can be switched off, and does not flag normal play.

**Use this when** the user asks for: "add an anti-cheat detector", "a new cheat check in Gaxia", "detect hover / float exploits", "extend AntiCheat" (ไทย: "เพิ่มตัวตรวจโกง", "เพิ่ม detector ใน AntiCheat", "ตรวจจับคนลอยตัว").
**Job:** B (you change the Gaxia repo). A game that only needs its own check calls `GaxiaServer.AntiCheat.Flag` or `GaxiaServer.AntiCheat.RegisterDetector` from its own Script ([anti-cheat and bans](../game/anticheat-and-bans.md)).
**Tools:** as in [change the framework](change-the-framework.md), Step 1.
**You will create:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/HoverDetector.lua`, edit `AntiCheat/init.lua` and `Config/AntiCheat.lua`, and add a test Script `ServerScriptService/AntiCheatFlagLog` in Studio.

**Code blocks marked `-- fragment: <file>` are repo files.** Do not paste that first line. Run every command from the repo root.

## How a detector works (read once)

- A detector is a ModuleScript in `AntiCheat/` that returns `{ Name, Init?, Sample? }`. The types are in `Types.lua`: `AntiCheatSnapshot`, `AntiCheatFlag`, `DetectorHost`. A detector never requires the orchestrator (the orchestrator requires it).
- When AntiCheat starts, it requires every module listed in `DETECTORS` (in `AntiCheat/init.lua`), then calls each `Init(host)` once, on its own thread.
- Every `Config.AntiCheat.SamplerInterval` (0.5 s) it builds **one snapshot per player** and passes it to every detector's `Sample(player, snapshot)`. The pass is spread over several frames. Each `Sample` runs in a `pcall`, inside a MicroProfiler label `AntiCheat.<Name>`.
- `Sample` returns `nil` or `{ reason = "Hover", severity = "soft" }`. The orchestrator counts flags per player and reason: 3 → a "soft" action, 5 (or one `"hard"` flag) → a "hard" action (kick). Counts drop by 1 every 60 s.
- **Observe mode:** while `Config.AntiCheat.Enforce = false` (the default), a hard action is published as `"observe"`: nobody is kicked.
- A detector is skipped while `Config.AntiCheat.<Name>.Enabled = false` or after `/ac off <Name>`. `AntiCheat.Whitelist(player, "<reason>", seconds)` skips that reason, and also every `<reason>:<kind>`.

## Step 1 — Create the detector module

Create `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/HoverDetector.lua` with this block (without its first line):

```lua
-- fragment: src/ServerStorage/Gaxia_Packages_Server/AntiCheat/HoverDetector.lua
--!strict
--[[
	Module : HoverDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.HoverDetector
	Purpose : Flags a character that stays in Freefall without falling (hover
	          exploits). A real jump or fall passes through Freefall with a clear
	          vertical speed; hovering keeps it near 0 for seconds.
	          Tunables live in Config.AntiCheat.Hover.
]]

local Players = game:GetService("Players")

-- ── Dependencies ──
local Types  = require(script.Parent.Parent.Types)
local Config = require(script.Parent.Parent.Config)

-- ── Types ──
type Snapshot = Types.AntiCheatSnapshot
type Flag = Types.AntiCheatFlag
type DetectorHost = Types.DetectorHost

-- The section is optional: every tunable falls back to its default without it.
local Cfg = Config.AntiCheat.Hover

local MAX_VERTICAL_SPEED : number = if Cfg then Cfg.MaxVerticalSpeed else 2 -- |Y velocity| under this = not falling
local STREAK_REQUIRED    : number = if Cfg then Cfg.StreakRequired else 6 -- samples in a row (6 x 0.5 s = 3 s)
local SPAWN_GRACE        : number = if Cfg then Cfg.SpawnGraceSeconds else 5 -- ignore a new character this long
local SEVERITY           : string = if Cfg then Cfg.Severity else "soft"

local HoverDetector = {}
HoverDetector.Name = "Hover"

-- userId -> samples in a row that looked like hovering
local streaks: { [number]: number } = {}
-- userId -> the character last seen and when it was first seen (grace period)
local spawned: { [number]: { character: Model, clock: number } } = {}

-- Called once when AntiCheat starts (on its own thread). Connect events here,
-- never in the module body.
function HoverDetector.Init(_host: DetectorHost): ()
	Players.PlayerRemoving:Connect(function(player: Player)
		streaks[player.UserId] = nil
		spawned[player.UserId] = nil
	end)
end

-- Called for every player every Config.AntiCheat.SamplerInterval. Read the shared
-- snapshot; never change it, never yield.
function HoverDetector.Sample(player: Player, snapshot: Snapshot): Flag?
	local uid = player.UserId
	local character = snapshot.character
	local velocity = snapshot.velocity
	if character == nil or velocity == nil then
		streaks[uid] = 0
		return nil
	end

	-- Grace period: a new character may spawn in the air.
	local seen = spawned[uid]
	if seen == nil or seen.character ~= character then
		spawned[uid] = { character = character, clock = snapshot.clock }
		streaks[uid] = 0
		return nil
	end
	if snapshot.clock - seen.clock < SPAWN_GRACE then
		return nil
	end

	if snapshot.state == Enum.HumanoidStateType.Freefall and math.abs(velocity.Y) < MAX_VERTICAL_SPEED then
		local streak = (streaks[uid] or 0) + 1
		if streak >= STREAK_REQUIRED then
			streaks[uid] = 0 -- one flag per streak, not one per sample
			return { reason = "Hover", severity = SEVERITY }
		end
		streaks[uid] = streak
	else
		streaks[uid] = 0
	end
	return nil
end

return HoverDetector
```

Rules it follows: the body only defines things (R4), requires are static and at the top (R3, R6), no `Lifecycle.Define` (R5: the orchestrator registers detectors), per-player state is freed on leave, and one flag needs several bad samples in a row.

## Step 2 — Register it in AntiCheat/init.lua

Open `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/init.lua`.

1. In the `DETECTORS` table, add this line in A→Z order (after `HeuristicDetector`):

```lua
-- fragment: add to DETECTORS in src/ServerStorage/Gaxia_Packages_Server/AntiCheat/init.lua
	{ Module = "HoverDetector",           Load = function() return require(script.HoverDetector) end },
```

2. In `export type DetectorAccess`, add this line after `Heuristic: …`:

```lua
-- fragment: add to DetectorAccess in src/ServerStorage/Gaxia_Packages_Server/AntiCheat/init.lua
	Hover: typeof(require(script.HoverDetector))?,
```

The `DETECTORS` entry loads it when AntiCheat starts. The `DetectorAccess` line types **GaxiaServer.AntiCheat.Hover** (the detector's own functions, if it has any). Without the entry the module would still load as an unknown extra child, after every built-in one: always add it.

## Step 3 — Add its Config section

Open `src/ServerStorage/Gaxia_Packages_Server/Config/AntiCheat.lua`.

1. In `export type AntiCheatConfig`, under the comment `-- Optional sections: …`, add after the `WorldBounds: …` line:

```lua
-- fragment: add to AntiCheatConfig in src/ServerStorage/Gaxia_Packages_Server/Config/AntiCheat.lua
	Hover: { MaxVerticalSpeed: number, StreakRequired: number, SpawnGraceSeconds: number, Enabled: boolean?, Severity: Severity }?,
```

2. In the `AntiCheat` table, add after the `WorldBounds = …` line:

```lua
-- fragment: add to the AntiCheat table in src/ServerStorage/Gaxia_Packages_Server/Config/AntiCheat.lua
	-- Freefall without falling for StreakRequired samples in a row (hover exploits)
	Hover         = { MaxVerticalSpeed   = 2, StreakRequired = 6, SpawnGraceSeconds = 5, Severity = "soft" },
```

Every detector section has `Severity` and may have `Enabled = false`. The `?` makes the section optional, so the detector's fallbacks are used when a config has no `Hover`.

## Step 4 — Run the checks

```sh
node tools/packages.mjs check
node tools/gen-api.mjs
node tools/gen-api.mjs --check
node tools/check-architecture.mjs --complete
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau --ignore="**/ProfileService.lua" src 2>&1 | grep -E "AntiCheat/(HoverDetector|init)|Config/AntiCheat"
luau-lsp analyze --flag:LuauSolverV2=true --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau --ignore="**/ProfileService.lua" src 2>&1 | grep -E "AntiCheat/(HoverDetector|init)|Config/AntiCheat"
```

The new module is already part of the `AntiCheat` package (its `Server` list is the whole `AntiCheat` folder), so `packages.mjs check` passes without a change. The two `grep` commands must print nothing.

## Step 5 — Test it in Studio

1. Run `rojo serve` and connect from Studio. Create a **Script** in **ServerScriptService** named **AntiCheatFlagLog** (a test Script; delete it after):

```lua
-- Script: ServerScriptService/AntiCheatFlagLog
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("AntiCheat"), "AntiCheatFlagLog needs the AntiCheat package: install it (playbooks/start/01-install-packages.md)")

local AntiCheat = GaxiaServer.AntiCheat

-- Print every flag and every action, so a test shows what the detectors see.
AntiCheat.OnFlag:Connect(function(player: Player, reason: string, severity: string, count: number)
	print(`[AntiCheatFlagLog] flag {player.Name}: {reason} ({severity}) x{count}`)
end)
AntiCheat.OnAction:Connect(function(player: Player, reason: string, kind: string)
	print(`[AntiCheatFlagLog] action {player.Name}: {reason} -> {kind}`)
end)

-- The detectors register when AntiCheat starts at boot: list them a moment later.
task.delay(3, function()
	print(`[AntiCheatFlagLog] detectors: {table.concat(AntiCheat.GetDetectorNames(), ", ")}`)
end)

print("[AntiCheatFlagLog] ready")
```

2. Press **Play**. Output shows `[AntiCheatFlagLog] ready`, then `[AntiCheatFlagLog] detectors: …` with `Hover` in the list, and no red errors.
3. Check the logic. While playing, switch to the **Server** view and run this in the command bar:

```lua
-- fragment: Studio command bar (server view), during Play
local Hover = require(game.ServerStorage.Gaxia_Packages_Server.AntiCheat.HoverDetector) local p = game.Players:GetPlayers()[1] local m = Instance.new("Model") for i = 1, 20 do local f = Hover.Sample(p, { clock = i * 0.5, character = m, velocity = Vector3.zero, state = Enum.HumanoidStateType.Freefall }) if f then print("sample", i, f.reason, f.severity) end end
```

   Output shows `sample 16 Hover soft` (1 sample to see the character, 10 samples of grace, 6 in a row).
4. Check for false positives: play normally for 5 minutes. Jump a lot, fall from a high place, climb, swim, sit, respawn. Output must show no `[AntiCheatFlagLog] flag … Hover` line.
5. Check enforcement as a player who is not the place creator (the creator is never kicked or banned): **Test → Clients and Servers** with 1 player, or a published test place with a second account.
6. Check the cost: in the server MicroProfiler (Developer Console → MicroProfiler) the label `AntiCheat.Hover` must stay tiny next to `AntiCheat.Sampler`.

## Check that it works

1. Step 4: `0 violation(s)`, `✓ playbooks/api is up to date`, and both `grep` commands print nothing.
2. Step 5: the `detectors:` line contains `Hover`, the command bar prints `sample 16 Hover soft`, and normal play shows no `Hover` flag.
3. `Config.AntiCheat.Hover.Enabled = false` (or `/ac off Hover` with AntiCheatAdmin) stops all `Hover` flags.
4. `CHANGELOG.md` lists the new detector ([change the framework](change-the-framework.md), Step 8).

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `Players.PlayerRemoving:Connect(...)` at the top of the module | Inside `Init` | R4: requiring a detector must not connect anything. |
| `require(script.Parent)` (the orchestrator) in a detector | Use the `host` passed to `Init` | The orchestrator requires the detectors: a cycle. |
| `Lifecycle.Define(...)` in a detector | No Define | R5: the orchestrator registers detectors. |
| Flagging on one bad sample | A streak of several samples, then reset the streak | Lag, knockback and jump apexes look bad for one sample. |
| `severity = "hard"` for something a normal player can cause | `"soft"` (3 flags → soft action, 5 → hard) | One hard flag is a hard action. Use hard only when no honest player can trigger it. |
| `snapshot.character:FindFirstChild(...)` or a raycast every sample | Use the snapshot fields; do slow work every few samples | `Sample` runs for every player twice a second. |
| Changing the snapshot table | Read it only | All detectors share the same snapshot. |
| An event-based detector calls `host.Flag(...)` directly | First check `host.IsDetectorEnabled("Hover")` | `Enabled = false` and `/ac off` only skip `Sample`, not your own events. |
| Destroying or moving things when cheating is detected | Only when `host.IsEnforcing()` is true | Observe mode must not change the game. |
| A reason that differs from `Name` | `reason = "Hover"` or `"Hover:<kind>"` | `Whitelist(player, "Hover")` then covers every Hover reason. |
| Testing kicks as the place creator | A non-creator player (Step 5) | The creator is never kicked or banned. |

## Change it

- A game feature that moves or launches players (jetpack, glider, cutscene): the game calls `GaxiaServer.AntiCheat.Whitelist(player, "Hover", seconds)` first. Say so in the detector's playbook docs.
- A detector driven by events instead of samples: leave out `Sample`; in `Init` keep `host` in a local, connect the events, and call `host.Flag(player, "Hover", SEVERITY)` after the `IsDetectorEnabled` check.
- Helper functions for games (like `AntiCheat.Combat.RegisterDamage`): add them to the detector table. The `DetectorAccess` line from Step 2 types them.
- To update the docs for games, add the name to the detector list in [anti-cheat and bans](../game/anticheat-and-bans.md) and to `MANUAL.md` §9.2.

## See also

- [Change the framework safely](change-the-framework.md) · [Add a service](add-a-service.md)
- [Anti-cheat and bans](../game/anticheat-and-bans.md) · [API: AntiCheat](../api/AntiCheat.md) · [API: Types](../api/Core.Types.md)
