# Write your first client script

> Each player sees a welcome toast when they join, and pressing **H** shows a help toast.

**Use this when** the user asks for: "a client script", "a LocalScript", "show a message on the player's screen", "bind a key", "where do I put UI code" (ไทย: "สคริปต์ฝั่ง client", "LocalScript", "แสดงข้อความบนจอผู้เล่น", "กดปุ่มแล้วให้ทำอะไร", "โค้ด UI ใส่ตรงไหน").
**Packages:** `UI.Toast`, `Input` (the script below stops with a clear message if one is missing).
If the script stops with "needs the … package": add it (repeat Step 2 of [Install packages](01-install-packages.md), see its *Change it*), then press Play again.
**You will create:** a LocalScript `StarterPlayer/StarterPlayerScripts/GameClient`.

## Where client code goes

| Code | Put it in | Type | File name with Rojo |
|---|---|---|---|
| Code for the local player: UI, keys, camera, effects | `StarterPlayer/StarterPlayerScripts` | **LocalScript** | `StarterPlayer/StarterPlayerScripts/GameClient.client.lua` |
| Client helpers that several LocalScripts share | `ReplicatedStorage/GameShared` (a Folder) | **ModuleScript** | `ReplicatedStorage/GameShared/<Name>.lua` |

Without Rojo, create the same names in Studio. With Rojo, `.client.lua` makes a LocalScript and plain `.lua` makes a ModuleScript.

A LocalScript in `StarterPlayerScripts` runs **once** per player, when they join. It does not run again when the character respawns.

## Step 1 — Create the GameClient LocalScript

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **GameClient**. Paste this whole block into it:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/GameClient
local Players = game:GetService("Players")

local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(Gaxia.IsInstalled("UI.Toast"), "GameClient needs the UI.Toast package: add it (playbooks/start/01-install-packages.md, Change it)")
assert(Gaxia.IsInstalled("Input"), "GameClient needs the Input package: add it (playbooks/start/01-install-packages.md, Change it)")

local Toast = Gaxia.UI.Toast
local Input = Gaxia.Input

-- LocalPlayer is always set in a LocalScript: no need to wait for it.
local player = Players.LocalPlayer

-- 1. A welcome message in the top-right corner.
Toast.Show({
	Title = "Welcome!",
	Text = `Hi {player.DisplayName}. Press H for help.`,
	Variant = "info",
	Duration = 5,
})

-- 2. A key: H shows a help message.
Input.Bind("ShowHelp", { Enum.KeyCode.H }, function(_actionName, state)
	if state ~= "Begin" then
		return -- "End" = the key was released
	end
	print("[GameClient] H pressed")
	Toast.Show({ Title = "Help", Text = "Collect coins and spend them in the shop.", Variant = "success" })
end)

-- 3. Code that runs every time the character spawns (first spawn and every respawn).
local function onCharacterAdded(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	print(`[GameClient] character spawned (health {humanoid.Health})`)
end

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	task.spawn(onCharacterAdded, player.Character) -- the character spawned before this script ran
end

print("[GameClient] ready")
```

What it does: shows a toast, binds **H**, and runs code on each spawn.
Why `CharacterAdded` plus the `if player.Character` check: the first character may already exist when the script starts.

## What the client can use

| Available on the client (`Gaxia.…`) | Not available on the client |
|---|---|
| UI: `Gaxia.UI.Toast`, `Gaxia.UI.NotificationService`, `Gaxia.UI.HUDController`, `Gaxia.UI.Components`, … | The server package `Gaxia_Packages_Server` (requiring it errors) |
| Client systems: `Gaxia.Input`, `Gaxia.Camera`, `Gaxia.Sound`, `Gaxia.Effects`, `Gaxia.Dialog`, `Gaxia.Tooltip` | Server services: Data, Economy, Item, Shop, Quest, … |
| Shared: `Gaxia.Signal`, `Gaxia.Trove`, `Gaxia.Util`, `Gaxia.TweenUtil`, `Gaxia.Net`, `Gaxia.State`, `Gaxia.Theme` | Anything in `ServerStorage` or `ServerScriptService` (the client cannot see them) |

- The client never changes coins, items or data. It **asks** the server through `Gaxia.Net` remotes: [Client ↔ server communication](04-client-server-communication.md).
- To show a server value (coins, timer) on screen: [Show values on screen](../game/show-values-on-screen.md).
- On the server, `Gaxia.UI`, `Gaxia.Input` and the other client modules are nil.

## How client modules load (read once)

- Every `Gaxia.<Name>` module loads the first time your code touches it. You never call an init function.
- The `Gaxia_ClientBootstrap` LocalScript (installed with Gaxia) loads a few modules early: `AntiCheat`, `Input`, `Camera`, `Sound`, and the Admin panel, chat replies and pet panel when their server service runs.
- `Gaxia.IsInstalled("X")` checks a client or shared module. Use the name you write after `Gaxia.`: `"Input"`, `"Camera"`, `"UI.Toast"`, `"Signal"`. For Util use `"Util.Table"` (or another Util module).
- `Gaxia.IsInstalled` never loads anything.

## Check that it works

If you cannot press Play: run the `luau-lsp analyze` command from AGENTS.md section 5 (no `TypeError`), then ask the user to do these steps and paste the Output lines.

1. Press **Play** in Studio.
2. Output shows `[GameClient] ready` and no red errors. Client output is in the same Output window.
3. A **Welcome!** toast slides in at the top right.
4. Output shows `[GameClient] character spawned (health 100)`.
5. Click the game view and press **H**. Output shows `[GameClient] H pressed` and a **Help** toast appears.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| A **Script** in StarterPlayerScripts | A **LocalScript** | Scripts are server code and do not run there. |
| A LocalScript in `Workspace` or `ServerScriptService` | `StarterPlayer/StarterPlayerScripts` | LocalScripts only run in player places (StarterPlayerScripts, StarterGui, StarterCharacterScripts). |
| `require(game:GetService("ServerStorage").Gaxia_Packages_Server)` in a LocalScript | `require(game:GetService("ReplicatedStorage").Gaxia_Packages)` | The client cannot see ServerStorage. |
| `require(...Gaxia_Packages) :: any` | The require line exactly as above | `:: any` turns off type checking and autocomplete. |
| `local character = player.CharacterAdded:Wait()` at the top | `player.CharacterAdded:Connect(...)` + `if player.Character` | `Wait()` hangs forever if the character already spawned, and misses respawns. |
| Binding **F2**, **F3** or **P** | Another key, such as **H** | Gaxia uses F2 (admin panel), F3 (debug console) and P (pet panel). |
| `UserInputService.InputBegan` for game keys | `Gaxia.Input.Bind` | `Bind` ignores keys typed in chat and supports rebinding. |
| Giving coins from the LocalScript | Ask the server with a remote | Changes made on the client are not real and are not saved. |
| `Gaxia.IsInstalled("Util")` | `Gaxia.IsInstalled("Util.Table")` | `Util` is a folder; `Gaxia.IsInstalled("Util")` returns false. |

## Change it

- To change the key: change `Enum.KeyCode.H` to another key, such as `Enum.KeyCode.G`.
- To bind a gamepad button too: use `{ Enum.KeyCode.H, Enum.KeyCode.ButtonY }`.
- To show a red error toast: use `Variant = "error"` (also `"info"`, `"success"`, `"warn"`).
- To keep a toast longer: change `Duration = 5` (seconds).
- To stop listening for the key: call `Input.Unbind("ShowHelp")`.

## See also

- [Write your first server script](02-server-script.md)
- [Client ↔ server communication](04-client-server-communication.md)
- [UI: notifications, menus, buttons](../game/ui.md)
- [Show values on screen](../game/show-values-on-screen.md)
- [Effects and feel](../game/effects-and-feel.md)
- [API: UI.Toast](../api/UI.Toast.md) · [API: Input](../api/Input.md) · [Features](../api/Core.Features.md)
