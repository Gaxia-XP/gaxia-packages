# Add a built-in anti-cheat detector

> The framework's anti-cheat has a new detector, `Hover`: it samples every player, flags hovering, has a Config section, can be switched off, and does not flag normal play.

**Use this when** the user asks for: "add an anti-cheat detector", "a new cheat check in Gaxia", "detect hover / float exploits", "extend AntiCheat" (ไทย: "เพิ่มตัวตรวจโกง", "เพิ่ม detector ใน AntiCheat", "ตรวจจับคนลอยตัว").
**Job:** B (you change the Gaxia repo). A game that only needs its own check calls `GaxiaServer.AntiCheat.Flag` or `GaxiaServer.AntiCheat.RegisterDetector` from its own Script ([anti-cheat and bans](../game/anticheat-and-bans.md)).
**Before you start:** do [change the framework](change-the-framework.md), Step 1 (tools and the type-error baseline `lsp-before.txt`, `lsp-v2-before.txt`).
**You will create:** `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/HoverDetector.lua`. You will edit `AntiCheat/init.lua`, `Config/AntiCheat.lua`, `CHANGELOG.md`, `MANUAL.md` and `playbooks/game/anticheat-and-bans.md`, and add a test Script `ServerScriptService/AntiCheatFlagLog` in Studio.

**Code blocks marked `-- fragment: <file>` are repo files.** Do not paste that first line. Run every command from the repo root.

## How a detector works (read once)

- A detector is a ModuleScript in `AntiCheat/` that returns `{ Name, Init?, Sample? }` (types in `Types.lua`: `AntiCheatSnapshot`, `AntiCheatFlag`, `DetectorHost`). It never requires the orchestrator.
- When AntiCheat starts, it loads every module in `DETECTORS` (`AntiCheat/init.lua`) and calls each `Init(host)` once, on its own thread.
- Every 0.5 s (`Config.AntiCheat.SamplerInterval`) it builds **one snapshot per player** and calls every enabled detector's `Sample(player, snapshot)` in a `pcall`, inside a MicroProfiler label `AntiCheat.<Name>`.
- `Sample` returns `nil` or `{ reason = "Hover", severity = "soft" }`. Per player and reason: flag 3 and 4 → a "soft" action (a warning), flag 5 or one `"hard"` flag → a "hard" action (kick). While `Config.AntiCheat.Enforce = false` (the default), a hard action becomes `"observe"`: nobody is kicked.

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
local GROUND_CHECK       : number = 6 -- studs below the root part; a part there = resting on something

local HoverDetector = {}
HoverDetector.Name = "Hover"

-- userId -> samples in a row that looked like hovering
local streaks: { [number]: number } = {}
-- userId -> the character last seen and when it was first seen (grace period)
local spawned: { [number]: { character: Model, clock: number } } = {}

-- True when a part is just below the character (a ledge, a head, a wedge).
local function standingOnSomething(hrp: BasePart, character: Model): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	return workspace:Raycast(hrp.Position, Vector3.new(0, -GROUND_CHECK, 0), params) ~= nil
end

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
			-- One raycast, only when a streak completes: stuck on a ledge is not hovering.
			local hrp = snapshot.hrp
			if hrp and standingOnSomething(hrp, character) then
				return nil
			end
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

It follows the rules: the body only defines things (R4), requires are static and at the top (R3, R6), no `Lifecycle.Define` (R5), per-player state is freed on leave, and one flag needs 6 bad samples in a row and no ground below.

## Step 2 — Register it in AntiCheat/init.lua

Open `src/ServerStorage/Gaxia_Packages_Server/AntiCheat/init.lua`.

1. In the `DETECTORS` table, add this line in A→Z order (after `HeuristicDetector`). Copy it exactly. The `require` inside `Load` is allowed (R6 allow-list): detectors must not load when AntiCheat is required, so never move it to the top.

```lua
-- fragment: add to DETECTORS in src/ServerStorage/Gaxia_Packages_Server/AntiCheat/init.lua
	{ Module = "HoverDetector",           Load = function() return require(script.HoverDetector) end },
```

2. In `export type DetectorAccess`, add this line after `Heuristic: …`:

```lua
-- fragment: add to DetectorAccess in src/ServerStorage/Gaxia_Packages_Server/AntiCheat/init.lua
	Hover: typeof(require(script.HoverDetector))?,
```

The `DETECTORS` entry loads it when AntiCheat starts. The `DetectorAccess` line types **GaxiaServer.AntiCheat.Hover** (the detector's own functions, if it has any).

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

## Step 4 — Run the checks and update the docs

```sh
node tools/packages.mjs fix
node tools/packages.mjs check
node tools/gen-api.mjs
node tools/gen-api.mjs --check
node tools/check-architecture.mjs --complete
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau --ignore="**/ProfileService.lua" src > lsp-after.txt 2>&1
luau-lsp analyze --flag:LuauSolverV2=true --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau --ignore="**/ProfileService.lua" src > lsp-v2-after.txt 2>&1
grep -c "HoverDetector.lua.*TypeError" lsp-after.txt lsp-v2-after.txt
grep -c "AntiCheat/init.lua.*TypeError" lsp-before.txt lsp-after.txt lsp-v2-before.txt lsp-v2-after.txt
grep -c "Config/AntiCheat.lua.*TypeError" lsp-before.txt lsp-after.txt lsp-v2-before.txt lsp-v2-after.txt
```

`packages.mjs fix` changes nothing here: the `AntiCheat` package already holds the whole folder. The first `grep` must print `:0` twice. In the other two, each `after` count must not be higher than its `before` count.

Then update the docs:

1. `CHANGELOG.md`, under `## Unreleased`: `### Added — Hover anti-cheat detector`, then one bullet on what it flags.
2. `MANUAL.md` §9.2: add `Hover` to the list, and change the count in the heading `### 9.2 Detectors (15 ตัว …` to 16.
3. `playbooks/game/anticheat-and-bans.md`: add a row for the `Hover` reason to its detector table.

## Step 5 — Test it in Studio

1. Run `rojo serve` and connect from Studio. Create a **Script** in **ServerScriptService** named **AntiCheatFlagLog** (a test Script; delete it after):

```lua
-- Script: ServerScriptService/AntiCheatFlagLog
local Players = game:GetService("Players")
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

-- 5 s after the first player joins: list the detectors, test the switch, send 5 test flags.
Players.PlayerAdded:Once(function(player: Player)
	task.wait(5)
	print(`[AntiCheatFlagLog] detectors: {table.concat(AntiCheat.GetDetectorNames(), ", ")}`)
	AntiCheat.SetDetectorEnabled("Hover", false)
	print(`[AntiCheatFlagLog] Hover enabled after off: {AntiCheat.IsDetectorEnabled("Hover")}`)
	AntiCheat.ClearOverrides() -- back to the Config value
	print(`[AntiCheatFlagLog] enforcing = {AntiCheat.IsEnforcing()}`)
	for _ = 1, 5 do
		AntiCheat.Flag(player, "Hover", "soft")
	end
	AntiCheat.ClearFlags(player, "Hover")
	print("[AntiCheatFlagLog] test flags done")
end)

print("[AntiCheatFlagLog] ready")
```

2. Press **Play**. Output shows, in order: `[AntiCheatFlagLog] ready`; `detectors: …` with `Hover` in the list; `Hover enabled after off: false`; `enforcing = false`; `flag <YourName>: Hover (soft) x1` up to `x5`; `action <YourName>: Hover -> soft` after x3 and x4; `-> observe` after x5; `test flags done`. No red errors. The yellow warnings `soft action against …` and `observe mode — would take HARD action …` come from the test flags: they are expected.
3. Check the logic. While playing, switch to the **Server** view and run this in the command bar:

```lua
-- fragment: Studio command bar (server view), during Play
local Hover = require(game.ServerStorage.Gaxia_Packages_Server.AntiCheat.HoverDetector) local p = game.Players:GetPlayers()[1] local m = Instance.new("Model") for i = 1, 20 do local f = Hover.Sample(p, { clock = i * 0.5, character = m, velocity = Vector3.zero, state = Enum.HumanoidStateType.Freefall }) if f then print("sample", i, f.reason, f.severity) end end
```

   Output shows `sample 16 Hover soft`: sample 1 sees the character, samples 2 to 10 are grace (9 samples), samples 11 to 16 are the streak (6 in a row).
4. Check enforcement. In `Config/AntiCheat.lua` set `Enforce = true`. Start **Test → Clients and Servers** with 1 player (that player is not the place creator). In the Server Output, after the 5 test flags: `-> hard`, and the player window shows a kick message. Set `Enforce = false` again.
5. Check for false positives. Ask the user to play normally for 5 minutes: jump a lot, fall from a high place, climb, swim, sit, stand on ledges, respawn. Wait for their report. After `test flags done`, Output must show no `flag … Hover` line.
6. Check the cost: in the server MicroProfiler (Developer Console → MicroProfiler) the label `AntiCheat.Hover` must stay tiny next to `AntiCheat.Sampler`.

No Studio? Run Step 4, report items 2 to 6 as NOT RUN, and tell the user before you say done.

## Check that it works

1. Step 4: `0 violation(s)`, `✓ playbooks/api is up to date`, and the `grep` counts are as Step 4 says.
2. Step 5: the lines of item 2, `sample 16 Hover soft`, a kick with `Enforce = true`, and no `Hover` flag in the user's normal play.
3. `CHANGELOG.md`, `MANUAL.md` §9.2 (count 16) and `anticheat-and-bans.md` list `Hover`.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `Players.PlayerRemoving:Connect(...)` at the top of the module | Inside `Init` | R4: requiring a detector must not connect anything. |
| `require(script.Parent)` (the orchestrator) or `Lifecycle.Define(...)` in a detector | Use the `host` passed to `Init`; no Define | The orchestrator requires and registers detectors (R5). |
| Flagging on one bad sample | A streak of several samples, then reset the streak | Lag, knockback and jump apexes look bad for one sample. |
| Flagging Freefall without checking for ground below | One raycast when the streak completes | Players get stuck in Freefall on ledges and heads. |
| `severity = "hard"` for something a normal player can cause | `"soft"` (flags 3 and 4 → soft action, 5 → hard) | One hard flag is a hard action. |
| A raycast or `FindFirstChild` on every sample | Use the snapshot fields; do slow work only when needed | `Sample` runs for every player twice a second. |
| Changing the snapshot table | Read it only | All detectors share the same snapshot. |
| An event-based detector calls `require(script.Parent).Flag(...)` or keeps `GaxiaServer.AntiCheat` | Call `host.Flag(...)` on the `host` passed to `Init` | Only `host.Flag` is ignored while the detector is off (`Enabled = false`, `/ac off Hover`). |
| Destroying or moving things when cheating is detected | Only when `host.IsEnforcing()` is true | Observe mode must not change the game. |
| A reason that differs from `Name` | `reason = "Hover"` or `"Hover:<kind>"` | `Whitelist(player, "Hover")` then covers every Hover reason. |
| Testing kicks as the place creator, or with `Enforce = false` | `Enforce = true` and a **Clients and Servers** player | With Ban installed, the creator is never kicked. Nothing is kicked while `Enforce = false`. |

## Change it

- A game feature that moves or launches players (jetpack, glider) calls `GaxiaServer.AntiCheat.Whitelist(player, "Hover", seconds)` first. Add that tip to the `Hover` row in [anti-cheat and bans](../game/anticheat-and-bans.md).
- A detector driven by events instead of samples: leave out `Sample`; in `Init` keep `host` in a local, connect the events, and call `host.Flag(player, "Hover", SEVERITY)`. While the detector is off, `host.Flag` does nothing (skip expensive work first with `host.IsDetectorEnabled("Hover")`).
- Helper functions for games (like `AntiCheat.Combat.RegisterDamage`): add them to the detector table. The `DetectorAccess` line from Step 2 types them.

## See also

- [Change the framework safely](change-the-framework.md) · [Add a service](add-a-service.md)
- [Anti-cheat and bans](../game/anticheat-and-bans.md) · [API: AntiCheat](../api/AntiCheat.md) · [API: Types](../api/Core.Types.md)
