# Install Gaxia and pick the packages your game needs

> The place has Gaxia installed with only the packages the game uses, and a check script proves they are there.

**Use this when** the user asks for: "install Gaxia", "set up the framework", "add a package", "which packages do I need", "update Gaxia" (ไทย: "ติดตั้ง Gaxia", "เลือก package", "เพิ่ม package", "ต้องใช้ package อะไรบ้าง", "อัปเดต Gaxia").
**Packages:** any (this playbook installs them).
**You will create:** a Script `ServerScriptService/CheckInstall` and a LocalScript `StarterPlayer/StarterPlayerScripts/CheckInstallClient`.

## What gets installed

Installing puts exactly four things in the place. **Install / Update replaces all four.** Never put game code inside them.
You get the packages you pick, the packages they need, and **Core** (always installed: Signal, Trove, Net, State, Flags, Config, …).

| Instance | What it is |
|---|---|
| `ReplicatedStorage/Gaxia_Packages` | Shared and client modules (`Gaxia`) |
| `ServerStorage/Gaxia_Packages_Server` | Server services (`GaxiaServer`) |
| `ServerScriptService/Gaxia_ServerBootstrap` | Starts the server side (boots the framework) |
| `StarterPlayer/StarterPlayerScripts/Gaxia_ClientBootstrap` | Starts the client side |

## Step 1 — Choose the packages

If the user did not say what kind of game it is, ask. Pick the **Every game** row, plus the row that matches the game.
No row fits (farm, shooter, racing, …)? Pick **Every game**, then one package per feature the user asked for.

| Game type | Pick these packages |
|---|---|
| Every game | `Data`, `Player`, `AntiCheat`, `Admin`, `Input` |
| Simulator (collect, upgrade, rebirth) | `Economy`, `Item`, `Pet`, `Level`, `Quest`, `DailyReward`, `Leaderboard`, `Shop`, `UI.Toast` |
| Obby | `Zone`, `Cooldown`, `Leaderboard`, `Monetization`, `UI.Toast` |
| Tycoon | `Economy` (+ `Player` from the row above) is all [game/tycoon](../game/tycoon.md) needs. Add later: `Idle`, `Placement`, `Visit`, `Interaction`, `Shop`, `UI.Toast` |
| RPG / adventure | `Inventory`, `ItemDef`, `Level`, `Quest`, `Loot`, `Interaction`, `Zone`, `Dialog`, `AI`, `Anim`, `Shop`, `UI.Toast` |
| Social hangout | `Friend`, `Party`, `Settings`, `Chat`, `Anim`, `UI.Toast` |
| Fighting | `Cooldown`, `Anim`, `Ragdoll`, `VFX`, `SFX`, `Camera`, `Level`, `Leaderboard`, `UI.Toast` |

Feature → package: coins/gems `Economy` · items `Item` · shop `Shop` · Robux sales `Monetization` · pets `Pet` · XP/levels `Level` · quests `Quest` · daily reward `DailyReward` · leaderboard `Leaderboard` · areas `Zone` · "press E" `Interaction` · pop-up messages `UI.Toast`. Anything else: [full list](../api/README.md).

- You do not need to pick dependencies. `Shop` brings `Economy`, `Level` and `Monetization` with it.
- **Do not pick everything** (**All** / `--all`). Unused packages make the place bigger and slower.

**Boot or first use** (true after Step 2 with a pick):
- These start at server boot: every **server** package you picked, and every installed package marked **Boot** (`Data`, `Player`, `Monetization`, `Settings`, `Cooldown`, `AntiCheat`, `Admin`, `Chat`, …), even as a dependency. Boot rows show `· starts at boot` after the name in the Companion, and `●` before the name in `packages.mjs list`.
- Every other installed server package starts the first time game code uses it. Client packages load on the client when code uses them.
- Exceptions: a **full install** records no pick. A full install is the Companion's **All**, `packages.mjs build --all`, or a pick that holds every package. It boots only the fixed list in `Gaxia_Packages_Server/Config/Features` (it has no `Monetization` and no `Settings`); every other package starts on first use. A `ServerStorage/GaxiaFeatures` module replaces the list completely (see Change it).

## Step 2 — Install

Ask the user: "Do you use Rojo? (Is there a `default.project.json` in your game folder?)" Yes → do **2B**. No or not sure → do **2A**.

### 2A — In Roblox Studio (Gaxia Companion plugin)

If you cannot click in Studio, give the user these steps word for word. Ask them to paste the status line from step 5. Wait for it, then continue at Step 3.

1. Open the place in Studio. Open the **Plugins** tab and click **Companion** (in the **Gaxia** toolbar).
   No Gaxia toolbar? Do 2B step 1 (get the Gaxia repo), then run `rojo build plugin.project.json -o GaxiaCompanion.rbxmx` in the `gaxia-packages` folder. Put the file in the Studio plugins folder (**Plugins → Plugins Folder**) and restart Studio.
2. In the **Gaxia Companion** window, click the **Install** tab.
3. Click **None** to clear the ticks. Then click each package from Step 1. A picked row shows `[x]`.
   - Rows marked `[+]` are added because a picked package needs them. Do not click them.
   - **Default** ticks a classic set (Data, Player, Economy, Pet, Admin, Quest, Input, …). Do not click **All**.
4. Click **Install / Update Gaxia in this place**. (Ctrl+Z undoes the whole install.)
5. Read the status line at the bottom:
   - `✓ Installed N package(s) (...)` = done.
   - `! Click Install again to remove ...` = the install would delete packages this place has. Check the list. Click **Install / Update** again only if the game does not use them.
   - `could not trim ... types` = Studio blocked script edits. Open **Plugins → Manage Plugins**, turn on **Script Injection** for Gaxia Companion, and click **Install / Update** again. (Without it Gaxia works, but Script Analysis shows type warnings in the loaders.)

### 2B — With Rojo

`MyGame` below is a placeholder. Ask the user for the game folder, and use its name. The Gaxia repo sits **next to** it.

1. Once: install `git`, Node.js and [rokit](https://github.com/rojo-rbx/rokit). In the folder that contains `MyGame`, run `git clone https://github.com/Gaxia-XP/gaxia-packages`. Then run `rokit install` inside `gaxia-packages` (it installs `rojo`).
2. Inside `gaxia-packages`, run these. Replace the list after `resolve` and `--select` with your Step 1 packages: exact names, commas, no spaces. Never put game files in `MyGame/gaxia`: `build` deletes and rewrites it.

```sh
node tools/packages.mjs list                                            # every package; ● = starts at boot
node tools/packages.mjs resolve Data,Player,AntiCheat,Admin,Input,Economy    # what this pick installs and boots
node tools/packages.mjs build --select Data,Player,AntiCheat,Admin,Input,Economy --out ../MyGame/gaxia
```

3. Serve it. **The game has no `default.project.json` of its own:** run `rojo serve ../MyGame/gaxia/default.project.json` (still inside `gaxia-packages`).
   **The game has its own `default.project.json`:** do not serve the Gaxia one. Copy its four nodes (`Gaxia_Packages`, `Gaxia_Packages_Server`, `Gaxia_ServerBootstrap`, `Gaxia_ClientBootstrap`) into the same services of the game's project. Keep `$attributes` and `$ignoreUnknownInstances`. Put `gaxia/` in front of every `$path` (paths are relative to `MyGame`):

```json
"ReplicatedStorage": {
  "Gaxia_Packages": { "$path": "gaxia/src/ReplicatedStorage/Gaxia_Packages", "$ignoreUnknownInstances": false,
    "$attributes": { "GaxiaPackages": "Data,Player,AntiCheat,Admin,Input,Economy" } }
}
```

   Then `rojo serve` the game's own project as before. In Studio: **Plugins → Rojo → Connect**. `MyGame/gaxia/INSTALLED.md` lists what was installed.
   Your own Scripts go in the game's own project, never inside `gaxia/`. File names: [server](02-server-script.md#where-server-code-goes), [client](03-client-script.md#where-client-code-goes).

## Step 3 — Check what is installed

Split the packages from Step 1 into two lists. Use exactly your picks: the sample lists below are only examples.

- **Client and shared packages:** names that start with `UI.`, the "Client systems" (`Input`, `Camera`, `Sound`, `Effects`, `Dialog`, `Cutscene`, `Tooltip`, `DebugConsole`) and the "Shared utilities" ([list](../api/README.md)). They go in `CheckInstallClient`.
- **Server packages:** all the others (`Data`, `Economy`, `Shop`, …). They go in `CheckInstall`.

Create a **Script** in **ServerScriptService** named **CheckInstall**. Replace `NEEDED` with your server packages:

```lua
-- Script: ServerScriptService/CheckInstall
local ServerStorage = game:GetService("ServerStorage")

local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Your server packages (the names you write after GaxiaServer.). Replace this sample list.
local NEEDED = { "Data", "Player", "AntiCheat", "Admin" }

local missing = 0
for _, name in NEEDED do
	if GaxiaServer.IsInstalled(name) then
		print(`[CheckInstall] {name}: installed`)
	else
		missing += 1
		warn(`[CheckInstall] {name}: MISSING - install it (playbooks/start/01-install-packages.md)`)
	end
end

-- The pick saved on the package root. nil = a full install (All / --all / every package), "" = Core only.
local picked = ServerStorage.Gaxia_Packages_Server:GetAttribute("GaxiaPackages")
print(`[CheckInstall] picked: {tostring(picked)}`)

-- Wait until Gaxia_ServerBootstrap has booted the framework, then list what runs.
GaxiaServer.Lifecycle.OnBooted(function()
	print(`[CheckInstall] started services: {table.concat(GaxiaServer.Lifecycle.GetStarted(), ", ")}`)
	print(`[CheckInstall] done, {missing} missing`)
end)
```

`GaxiaServer.IsInstalled` knows only server packages. Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **CheckInstallClient**. Replace `NEEDED` with your client and shared packages:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/CheckInstallClient
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

-- Your client and shared packages (the name you write after Gaxia.). Replace this sample list.
-- Util is a folder: write "Util.Table" (or another Util.* module), never "Util".
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

## Check that it works

If you cannot press Play, ask the user to do it and paste the Output lines listed here.

1. The Explorer shows the four instances from "What gets installed".
2. Press **Play**. Output shows `[Gaxia_ServerBootstrap] complete` and `[Gaxia_ClientBootstrap] complete — client features loaded`, with no red errors.
3. Output shows `[CheckInstall] done, 0 missing` and `[CheckInstallClient] done, 0 missing`.
4. If `[CheckInstall] picked:` shows names (not `nil`) and there is no `ServerStorage/GaxiaFeatures`, `[CheckInstall] started services:` includes every picked **server** package. Client picks (`UI.Toast`, `Input`) and utilities never appear there. `picked: nil` means a full install: it is right only if the user asked for everything (see Common mistakes).
5. You may delete both scripts once the checks pass.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Editing modules inside `Gaxia_Packages_Server` (Config too) | Settings: [config and flags](../game/config-and-flags.md); boot list: `ServerStorage/GaxiaFeatures` | Install / Update replaces the whole package. |
| Game Scripts inside `Gaxia_Packages`, `Gaxia_Packages_Server` or `MyGame/gaxia` | Your own Scripts in `ServerScriptService` / `StarterPlayerScripts` | They are deleted by the next Install / Update or build. |
| Ticking **All**, or `build --all` | Tick (or `--select`) only what the game uses | A full install records no pick (`picked: nil`): every package is copied, but only the fixed list in `Config/Features` boots (no `Monetization`, so Robux receipts are not granted until a Script uses Monetization). Unused packages make the place bigger. |
| `--out` inside the Gaxia repo, or a folder with other files | An empty folder next to the repo, such as `../MyGame/gaxia` | `build` refuses, or would delete files. |
| Serving `gaxia/default.project.json` when the game has its own project | Copy the four nodes into the game's project (2B step 3) | Rojo connects to one server: the game's own scripts stop syncing. |
| `GaxiaServer.IsInstalled("UI.Toast")` on the server | `Gaxia.IsInstalled("UI.Toast")` in a LocalScript | Server `IsInstalled` only knows server services. |
| `GaxiaFeatures` without `Admin` / `Monetization` | Start from the `started services:` line | Missing services never boot: no admin panel, and Robux receipts are not granted. |

## Change it

- **Add or remove a package later:** repeat Step 2. The Companion starts with this place's current pick ticked. With Rojo, edit `--select` and build again. With the game's own project, also copy the new `$attributes` value from `gaxia/default.project.json`.
- **Update Gaxia to a new version:** in `gaxia-packages` run `git pull`. Companion: rebuild the plugin (2A step 1), replace the file in the Plugins Folder, restart Studio, click **Install / Update** (the pick stays ticked). Rojo: run `node tools/packages.mjs build --from ../MyGame/gaxia/gaxia-packages.json --out ../MyGame/gaxia`. Game code is outside the four instances, so it is kept.
- **Only if the user asks to choose exactly which services start at boot:** create a ModuleScript `ServerStorage/GaxiaFeatures`. It **replaces** the boot list. 1) Run the game once with `CheckInstall`. 2) Copy every name from the `[CheckInstall] started services:` line into `Services`. 3) Add or remove only the services the user named:

```lua
-- ModuleScript: ServerStorage/GaxiaFeatures
local Types = require(game:GetService("ServerStorage").Gaxia_Packages_Server.Types)

-- ONLY these services start at server boot. Every other installed service starts on first use.
local Features: Types.Features = {
	Services = { "AntiCheat", "Data", "Player", "Ban", "Chat", "Admin", "Economy" },
}

return Features
```

- **Only if the user asks to load more client modules at spawn:** create a ModuleScript `ReplicatedStorage/GaxiaClientFeatures`. It replaces the client list, so this one keeps Gaxia's defaults and adds `Effects`:

```lua
-- ModuleScript: ReplicatedStorage/GaxiaClientFeatures
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local Features = require(game:GetService("ReplicatedStorage").Gaxia_Packages.Features)

-- This game's extra client modules, loaded when the player spawns.
local EXTRA: { Features.ClientEntry } = { { Key = "Effects" } }

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

- [Write your first server script](02-server-script.md) · [Write your first client script](03-client-script.md) · [Troubleshooting](../troubleshooting.md)
- [API reference: every package](../api/README.md) · [Lifecycle (started services)](../api/Core.ServiceLifecycle.md) · [Client Features](../api/Core.Features.md)
