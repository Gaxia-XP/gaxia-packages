# Show live values on the player's screen (coins, timer, status)

> Every player sees the round status, a countdown and their own Coins on screen, and the labels update by themselves.

**Use this when** the user asks for: "show coins on screen", "a timer on the screen", "round countdown", "HUD", "status text", "update the UI when a value changes", "replicate a value to the client" (ไทย: "แสดงเงินบนจอ", "โชว์เวลานับถอยหลัง", "ตัวจับเวลา", "HUD", "ข้อความสถานะบนจอ", "อัปเดต UI อัตโนมัติ", "ส่งค่าไปให้ client").
**Packages:** `Economy` (it also installs `Data`) and `UI.StateBinding`. `State` (`Gaxia.State`) is Core: it is always installed. The scripts below stop with a clear message if one is missing.
**You will create:** a Script `ServerScriptService/HudState` and a LocalScript `StarterPlayer/StarterPlayerScripts/HudScreen`.

How it works:

- The **server** owns the values. It puts them in a state container: `Gaxia.State.Create("Round", defaults)`. A container replicates to **every** client by itself.
- The **client** gets the same container with `Gaxia.State.Get("Round")` and reads it. `Gaxia.UI.StateBinding.BindText(label, state, key, format)` sets the label now and on every change.
- **Global values** (round timer, status): one key each, the same for everyone (`TimeLeft`, `Status`).
- **Per-player values** (Coins): one key per player in a shared container, named after the player: `Coins_<PlayerName>`. Each client binds only its own key, but every client can read every container: never put secrets in a state.
- Timing: a client can start before the server has a value. `State.Get` waits (up to about 20 seconds) for the server to create the container, then returns `nil` (so the client `assert`s it). A key the server has not set yet reads `nil`. Coins are set only after the player's data loads (1–3 seconds after join), so the label shows `Coins: ...` until then.
- Values must be numbers, strings, booleans (or Vector3, Color3, UDim2…). For tables use `state:SetTable` / `state:GetTable` / `state:OnTableChanged`.

## Step 1 — Keep the values on the server

Create a **Script** in **ServerScriptService** named **HudState**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/HudState
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Economy"), "HudState needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local State = Gaxia.State
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy

local INTERMISSION_SECONDS = 10
local ROUND_SECONDS = 30
local ROUND_REWARD = 10 -- Coins for every player when a round ends

-- Global state: one value per key, the same for every player.
local roundState = State.Create("Round", { Status = "Waiting", TimeLeft = 0 })
-- Per-player state: one key per player ("Coins_<PlayerName>") in one container.
local coinState = State.Create("PlayerCoins")

local function coinKey(player: Player): string
	return "Coins_" .. player.Name
end

-- Every Economy change fires OnTransaction: copy the new Coins balance into the state.
Economy.OnTransaction:Connect(function(player: Player, currency: string, _delta: number, newBalance: number)
	if currency == "Coins" then
		coinState:Set(coinKey(player), newBalance)
	end
end)

local function onPlayerAdded(player: Player)
	-- The balance is in the saved data: wait until it is loaded.
	if Data.WaitFor(player, 120) == nil then
		return -- the player left, or the data did not load in 120 seconds
	end
	if player.Parent == nil then
		return -- left right after loading: PlayerRemoving already cleared the key
	end
	coinState:Set(coinKey(player), Economy.Get(player, "Coins"))
	print(`[HudState] {player.Name} Coins in state: {coinState:Get(coinKey(player))}`)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player: Player)
	coinState:Set(coinKey(player), nil) -- setting nil deletes the player's key
end)

-- Set Status once, then TimeLeft every second down to 1.
local function countdown(status: string, seconds: number)
	roundState:Set("Status", status)
	for timeLeft = seconds, 1, -1 do
		roundState:Set("TimeLeft", timeLeft)
		task.wait(1)
	end
end

print("[HudState] ready")

-- This loop never ends, so it is the last thing in the script.
while true do
	countdown("Intermission", INTERMISSION_SECONDS)
	print("[HudState] round started")
	countdown("Round", ROUND_SECONDS)
	for _, player in Players:GetPlayers() do
		if Data.IsLoaded(player) then -- before the data loads, Add does nothing and returns false
			Economy.Add(player, "Coins", ROUND_REWARD) -- OnTransaction above updates the state
		end
	end
	print("[HudState] round ended")
end
```

What it does: it runs a 10-second intermission and a 30-second round forever (change `INTERMISSION_SECONDS` / `ROUND_SECONDS`). It keeps each player's Coins in the state and pays 10 Coins after each round. It requires both `GaxiaServer` and `Gaxia_Packages`: a server Script needs `Gaxia_Packages` for `Gaxia.State` and `Gaxia.Net` (they work on server and client); every other service comes from `GaxiaServer`.

## Step 2 — Show the values on the client

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **HudScreen**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/HudScreen
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("UI.StateBinding"), "HudScreen needs the UI.StateBinding package: install it (playbooks/start/01-install-packages.md)")

local State = Gaxia.State
local StateBinding = Gaxia.UI.StateBinding
local player = Players.LocalPlayer

-- 1. Build the screen in code.
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "HudScreen"
screenGui.ResetOnSpawn = false -- keep the labels after the character respawns
screenGui.Parent = player:WaitForChild("PlayerGui")

local function makeLabel(name: string, position: UDim2): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = UDim2.fromOffset(220, 36)
	label.Position = position
	label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	label.BackgroundTransparency = 0.4
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = "..."
	label.Parent = screenGui
	return label
end

local statusLabel = makeLabel("StatusLabel", UDim2.new(0.5, -110, 0, 10))
local timerLabel = makeLabel("TimerLabel", UDim2.new(0.5, -110, 0, 50))
local coinsLabel = makeLabel("CoinsLabel", UDim2.new(0, 10, 0.5, 0))

-- 2. Get the containers. State.Get waits (up to ~20 s) for the server to create them.
local roundState = State.Get("Round")
assert(roundState, "HudScreen: state 'Round' not found. Is the Script ServerScriptService/HudState running?")
local coinState = State.Get("PlayerCoins")
assert(coinState, "HudScreen: state 'PlayerCoins' not found. Is the Script ServerScriptService/HudState running?")

-- Must be the same key as coinKey() in HudState.
local myCoinKey = "Coins_" .. player.Name

-- 3. Bind each label to one key. The label updates by itself on every change.
StateBinding.BindText(statusLabel, roundState, "Status")
StateBinding.BindText(timerLabel, roundState, "TimeLeft", function(value: any): string
	return `{value or 0} s`
end)
StateBinding.BindText(coinsLabel, coinState, myCoinKey, function(value: any): string
	if value == nil then
		return "Coins: ..." -- not set yet: the server is still loading this player's data
	end
	return `Coins: {value}`
end)

-- 4. Print each change of my Coins so you can see it in Output.
coinState:OnChanged(myCoinKey, function(newCoins: any)
	print(`[HudScreen] my Coins: {newCoins}`)
end)

print(`[HudScreen] ready, status {roundState:Get("Status")}, Coins {coinState:Get(myCoinKey)}`)
```

What it does: it makes three labels and binds each one to a state key. No loop is needed: the binding updates the label.

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[HudState] ready` and `[HudScreen] ready, status Intermission, Coins nil`, and no red errors. (`Coins <your Coins>` instead of `Coins nil` is also right: the data loaded first.)
3. Within a few seconds Output shows `[HudState] <YourName> Coins in state: <your Coins>` and `[HudScreen] my Coins: <your Coins>` (in any order; `0` on a new save). The left label shows `Coins: <your Coins>`.
4. The top labels show `Intermission` and a number counting down from 10. Then Output shows `[HudState] round started`, the status label shows `Round`, and the timer starts from 30.
5. When the round ends (40 seconds after you press Play, 30 seconds after the `[HudState] round started` line), Output shows `[HudScreen] my Coins: <your Coins + 10>` and the label shows the same number.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `local coins = coinState:Get(key)` once, then `label.Text = coins` | `StateBinding.BindText(label, coinState, key, format)` | A value read once never changes. The binding updates on every change. |
| `coinState:Set(...)` in a LocalScript | Change values on the server only | A client `Set` changes only that client's copy. The server never sees it. |
| `State.Create("Coins_" .. player.UserId)`, then `:Destroy()` when they leave | One container, one key per player, `Set(key, nil)` on leave | After `Destroy`, a player who rejoins the same server gets the old destroyed container: the client never sees updates. |
| Key `"Coins " .. player.Name` or `"Coins_" .. player.UserId` | `"Coins_" .. player.Name` | A key is a Roblox attribute name (`Set` calls `Folder:SetAttribute`): only letters, digits and `_`, else `Set` errors. Studio test players have negative UserIds (`-1`): the `-` breaks the key. |
| `coinState:Set(key, { Gold = 1 })` | `coinState:SetTable(key, { Gold = 1 })` and `GetTable` / `OnTableChanged` | `Set` accepts only simple values. A table errors. |

## Change it

- To show Gems too: in `HudState` add `if currency == "Gems" then` with a key `"Gems_" .. player.Name`. In `onPlayerAdded`, after `Data.WaitFor`, add `coinState:Set("Gems_" .. player.Name, Economy.Get(player, "Gems"))`; in `PlayerRemoving` set it to `nil`. Add one more label and `BindText` in `HudScreen`.
- To show a value with your own format: change the `format` function, for example ``return `Time left: {value}` ``. It must return a string. To bind another property than Text: `StateBinding.Bind(frame, "Visible", roundState, "Status", function(value) return value == "Round" end)`.
- To show Level from [progression](progression.md): set `"Level_" .. player.Name` to `GaxiaServer.Level.GetLevel(player)` in `onPlayerAdded` after `Data.WaitFor`, and again in `Level.OnLevelUp`; set it to `nil` in `PlayerRemoving`. Bind that key on the client.
- For a quick text label without your own ScreenGui: `Gaxia.UI.HUDController.AddText` (package `UI.HUDController`; it also installs `UI.UIController`). First, in Studio, add a **ScreenGui** named `Gaxia_UI` to **StarterGui** (ResetOnSpawn off) with a **Folder** named `HUD` in it. Make them in Studio only, not in code: Roblox copies StarterGui into PlayerGui, and code that also creates one can make two. (`PetPanel` from [pets](pets.md) reuses this copy and adds its `Overlays` folder.) Without `Gaxia_UI`, `AddText` waits about 10 seconds, warns `[HUDController] no HUD parent`, and returns `nil`.
- For buttons, menus and notifications: [ui](ui.md). Coins in the player list instead: [currency-and-leaderstats](currency-and-leaderstats.md).

## See also

- [API: State](../api/Core.ReplicatedState.md) · [API: UI.StateBinding](../api/UI.StateBinding.md) · [API: UI.HUDController](../api/UI.HUDController.md) · [API: Economy](../api/Economy.md)
- [Client script](../start/03-client-script.md) · [Client ↔ server](../start/04-client-server-communication.md) · [Troubleshooting](../troubleshooting.md)
