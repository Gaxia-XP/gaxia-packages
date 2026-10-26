# Install Gaxia and pick the packages your game needs

> The place has Gaxia installed with only the packages the game uses, and a check script proves they are there.

**Use this when** the user asks for: "install Gaxia", "set up the framework", "add a package", "which packages do I need", "update Gaxia" (ไทย: "ติดตั้ง Gaxia", "เลือก package", "เพิ่ม package", "ต้องใช้ package อะไรบ้าง", "อัปเดต Gaxia").
**Packages:** any (this playbook installs them).
**You will create:** a Script `ServerScriptService/CheckInstall` and a LocalScript `StarterPlayer/StarterPlayerScripts/CheckInstallClient`.

## What gets installed

Installing puts exactly four things in the place. **Install / Update replaces all four.** Never put game code inside them.

| Instance | What it is |
|---|---|
| `ReplicatedStorage/Gaxia_Packages` | Shared and client modules (`Gaxia`) |
| `ServerStorage/Gaxia_Packages_Server` | Server services (`GaxiaServer`) |
| `ServerScriptService/Gaxia_ServerBootstrap` | Starts the server side |
| `StarterPlayer/StarterPlayerScripts/Gaxia_ClientBootstrap` | Starts the client side |

You get the packages you pick, the packages they need, and **Core** (always installed: Signal, Trove, Net, State, Flags, Config, …).

## Step 1 — Choose the packages

Pick the **Every game** row, plus the row that matches the game. Then add packages for any other feature the user asked for ([full list](../api/README.md)).

| Game type | Pick these packages |
|---|---|
| Every game | `Data`, `Player`, `AntiCheat`, `Admin` |
| Simulator (collect, upgrade, rebirth) | `Economy`, `Item`, `Pet`, `Level`, `Quest`, `DailyReward`, `Leaderboard`, `Shop`, `UI.Toast`, `Input` |
| Obby | `Zone`, `Cooldown`, `Leaderboard`, `Monetization`, `UI.Toast` |
| Tycoon | `Economy`, `Idle`, `Placement`, `Visit`, `Interaction`, `Shop`, `UI.Toast` |
| RPG / adventure | `Inventory`, `ItemDef`, `Level`, `Quest`, `Loot`, `Interaction`, `Zone`, `Dialog`, `AI`, `Anim`, `Shop`, `UI.Toast` |
| Social hangout | `Friend`, `Party`, `Settings`, `Chat`, `Anim`, `UI.Toast` |
| Fighting | `Cooldown`, `Anim`, `Ragdoll`, `VFX`, `SFX`, `Camera`, `Input`, `Level`, `Leaderboard`, `UI.Toast` |

- Sells Robux items? Add `Monetization` ([Robux purchases](../game/robux-purchases.md)).
- You do not need to pick dependencies. `Shop` brings `Economy`, `Level` and `Monetization` with it.
- **Do not pick everything.** A full install boots only the old default list, and unused packages slow the game.

**Boot or first use:**

- The packages you **pick** start at server boot.
- Packages marked **Boot** (`● starts at boot`) start at boot whenever they are installed, even as a dependency: `Data`, `Player`, `Monetization`, `Settings`, `Cooldown`, `AntiCheat`, `Admin`, `Chat`, …
- Every other installed package starts the first time game code uses it.

## Step 2 — Install

Do **2A** if the game is edited in Roblox Studio only. Do **2B** if the game uses Rojo (it has a `default.project.json`).
An agent that cannot click in Studio gives the user the steps of 2A, word for word.

### 2A — In Roblox Studio (Gaxia Companion plugin)

1. Open the place in Studio. Open the **Plugins** tab and click **Companion** (in the **Gaxia** toolbar).
   No Gaxia toolbar? Build the plugin in the Gaxia repo: `rojo build plugin.project.json -o GaxiaCompanion.rbxmx`. Put the file in the Studio plugins folder (**Plugins → Plugins Folder**) and restart Studio.
2. In the **Gaxia Companion** window, click the **Install** tab.
3. Click **None** to clear the ticks. Then click each package from Step 1. A picked row shows `[x]`.
   - Rows marked `[+]` are added because a picked package needs them. Do not click them.
   - **Default** ticks the classic set (Data, Player, Economy, Pet, Admin, Quest, …). **All** ticks everything: do not use it.
4. Click **Install / Update Gaxia in this place**.
5. Read the status line at the bottom:
   - `✓ Installed N package(s) (...)` = done.
   - `! Click Install again to remove ...` = the install would delete packages this place has. Check the list. Click **Install / Update** again only if the game does not use them.
   - `could not trim ... types` = Studio blocked script edits. Open **Plugins → Manage Plugins**, turn on **Script Injection** for Gaxia Companion, and click **Install / Update** again. (Without it Gaxia works, but Script Analysis shows type warnings in the loaders.)
6. Ctrl+Z undoes the whole install.

### 2B — With Rojo

Run these in the Gaxia repo folder. `--out` must be a folder **outside** the Gaxia repo that is empty or a previous build:

```sh
node tools/packages.mjs list                                   # every package; ● = starts at boot
node tools/packages.mjs resolve Data,Player,Economy,UI.Toast    # what this pick installs and boots
node tools/packages.mjs build --select Data,Player,Economy,UI.Toast --out ../MyGame/gaxia
rojo serve ../MyGame/gaxia/default.project.json
```

Then in Studio: **Plugins → Rojo → Connect**. `../MyGame/gaxia/INSTALLED.md` lists what was installed.
`build` deletes and rewrites `src/`, `playbooks/` and the files it made in `--out`. Never put game files there.

## Step 3 — Check what is installed

Split the packages from Step 1 into two lists:

- **Client and shared packages:** names that start with `UI.`, the "Client systems" (`Input`, `Camera`, `Sound`, `Effects`, `Dialog`, `Cutscene`, `Tooltip`, `DebugConsole`) and the "Shared utilities" ([list](../api/README.md)). They go in `CheckInstallClient`.
- **Server packages:** all the others (`Data`, `Economy`, `Shop`, …). They go in `CheckInstall`.

Create a **Script** in **ServerScriptService** named **CheckInstall**. Put the server packages in `NEEDED`:

```lua
-- Script: ServerScriptService/CheckInstall
local ServerStorage = game:GetService("ServerStorage")

local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Server packages this game needs (the names you write after GaxiaServer.).
local NEEDED = { "Data", "Player", "Economy" }

local missing = 0
for _, name in NEEDED do
	if GaxiaServer.IsInstalled(name) then
		print(`[CheckInstall] {name}: installed`)
	else
		missing += 1
		warn(`[CheckInstall] {name}: MISSING - install it (playbooks/start/01-install-packages.md)`)
	end
end

-- The pick is saved on the package roots. No attribute = everything was installed.
local picked = ServerStorage.Gaxia_Packages_Server:GetAttribute("GaxiaPackages")
if picked == nil then
	print("[CheckInstall] full install (every package)")
elseif picked == "" then
	print("[CheckInstall] Core only (nothing picked)")
else
	print(`[CheckInstall] picked: {picked}`)
end

print(`[CheckInstall] started services: {table.concat(GaxiaServer.Lifecycle.GetStarted(), ", ")}`)
print(`[CheckInstall] done, {missing} missing`)
```

`GaxiaServer.IsInstalled` knows only server packages. Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **CheckInstallClient**. Put the client and shared packages in `NEEDED`:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/CheckInstallClient
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

-- Client and shared packages this game needs (the names you write after Gaxia.).
-- For the Util package use "Util.Table".
local NEEDED = { "Input", "UI.Toast", "Util.Table" }

local missing = 0
for _, key in NEEDED do
	if Gaxia.IsInstalled(key) then
		print(`[CheckInstallClient] {key}: installed`)
	else
		missing += 1
		warn(`[CheckInstallClient] {key}: MISSING - install it (playbooks/start/01-install-packages.md)`)
	end
end
print(`[CheckInstallClient] done, {missing} missing`)
```

You may delete both scripts once the check passes.

## Check that it works

1. The Explorer shows the four instances from "What gets installed".
2. Press **Play**. Output shows `[Gaxia_ServerBootstrap] complete` and `[Gaxia_ClientBootstrap] complete — client features loaded`, with no red errors.
3. Output shows `[CheckInstall] done, 0 missing` and `[CheckInstallClient] done, 0 missing`.
4. `[CheckInstall] started services:` lists every package you picked that is a service.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Editing modules inside `Gaxia_Packages_Server` (Config too) | Settings: [config and flags](../game/config-and-flags.md); boot list: `ServerStorage/GaxiaFeatures` | Install / Update replaces the whole package. |
| Game Scripts inside `Gaxia_Packages` or `Gaxia_Packages_Server` | Your own Scripts in `ServerScriptService` / `StarterPlayerScripts` | They are deleted by the next Install / Update. |
| Ticking **All** | Tick only what the game uses | A full install skips the Boot list of picked installs. |
| Clicking a `[+]` row to remove it | Untick the package that needs it | `[+]` packages come back while a picked package needs them. |
| Copying modules from another place into `Gaxia_Packages` | Install the package with the Companion or `packages.mjs` | Copied modules miss their dependencies. |
| `--out` inside the Gaxia repo, or a folder with other files | An empty folder outside the repo, such as `../MyGame/gaxia` | `build` refuses, or would delete files. |
| `GaxiaServer.IsInstalled("UI.Toast")` on the server | `Gaxia.IsInstalled("UI.Toast")` in a LocalScript | Server `IsInstalled` only knows server services. |

## Change it

- **Add or remove a package later:** repeat Step 2. The Companion starts with this place's current pick ticked. With Rojo, edit `--select` and build again.
- **Update Gaxia to a new version:** install the new Companion plugin, then click **Install / Update** (the pick stays ticked). With Rojo: update the Gaxia repo, then run `node tools/packages.mjs build --from ../MyGame/gaxia/gaxia-packages.json --out ../MyGame/gaxia`. Game code is outside the four instances, so it is kept.
- **Only if the user asks to choose exactly which services start at boot:** create a ModuleScript `ServerStorage/GaxiaFeatures`. It **replaces** the boot list, so list every service that must boot (always `Data`, `Player`; `Monetization` if the game sells Robux items). List only installed packages:

```lua
-- ModuleScript: ServerStorage/GaxiaFeatures
local Types = require(game:GetService("ServerStorage").Gaxia_Packages_Server.Types)

-- ONLY these services start at server boot. Every other installed service starts on first use.
local Features: Types.Features = {
	Services = { "AntiCheat", "Data", "Player", "Economy" },
}

return Features
```

- **Only if the user asks to load more client modules at spawn:** create a ModuleScript `ReplicatedStorage/GaxiaClientFeatures`. It replaces the client list, so this one keeps Gaxia's defaults and adds `Effects`:

```lua
-- ModuleScript: ReplicatedStorage/GaxiaClientFeatures
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local Features = require(ReplicatedStorage.Gaxia_Packages.Features)

-- This game's extra client modules, loaded when the player spawns.
local EXTRA: { Features.ClientEntry } = {
	{ Key = "Effects" },
}

local result: Features.ClientFeatures = { Client = {} }
for _, list in { Features.Client, EXTRA } do
	for _, entry in list do
		if Gaxia.IsInstalled(entry.Key) then -- skip packages this place does not have
			table.insert(result.Client, entry)
		end
	end
end

return result
```

## See also

- [Write your first server script](02-server-script.md)
- [Write your first client script](03-client-script.md)
- [API reference: every package](../api/README.md)
- [Lifecycle (started services)](../api/Core.ServiceLifecycle.md) · [Client Features](../api/Core.Features.md)
- [Troubleshooting](../troubleshooting.md)
