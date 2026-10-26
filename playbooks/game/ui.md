# Notifications, menus, buttons and screens

> A **Menu** button opens a menu. Its **Claim gift** button asks the server for Coins and shows the answer as a notification (toast).

**Use this when** the user asks for: "a notification", "a popup message", "a menu", "a button", "a settings screen", "a toggle", "a slider", "open and close a screen", "UI that fits phones" (ไทย: "แจ้งเตือน", "ข้อความเด้ง", "เมนู", "ปุ่ม", "หน้าตั้งค่า", "ปุ่มเปิดปิด", "สไลเดอร์", "เปิดปิดหน้าจอ", "UI ให้พอดีมือถือ").
**Packages:** client: `UI.Toast`, `UI.Components`, `UI.Router`, `UI.Responsive` (`Theme` comes with them). Server: `Economy` (it also installs `Data`). The scripts below stop with a clear message if one is missing.
**You will create:** a Script `ServerScriptService/GiftServer` and a LocalScript `StarterPlayer/StarterPlayerScripts/GameMenu`.

Which package does what (use these, in a LocalScript):

| You want | Use | Not this |
|---|---|---|
| A notification (toast) | `Gaxia.UI.Toast.Show` | `UI.NotificationService` (see Common mistakes) |
| Buttons, toggles, sliders, text boxes, dropdowns, tabs, lists, yes/no popups | `Gaxia.UI.Components` | Hand-made buttons with copied colours |
| Screens that open on top of each other (menu → settings → back) | `Gaxia.UI.Router` | `UI.MenuController` (see Common mistakes) |
| UI that fits phones and TVs | `Gaxia.UI.Responsive` | Fixed pixel sizes only |
| One place for colours, fonts, spacing | `Gaxia.Theme` | `Color3.fromRGB` in every script |

UI code is client code. The client asks the server through `Gaxia.Net` ([start/04](../start/04-client-server-communication.md)). `Router.Push(name)` opens a screen on top, `Router.Pop()` closes the top one, `Router.Clear()` closes all.

## Step 1 — Create the server side of the gift button

Create a **Script** in **ServerScriptService** named **GiftServer**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/GiftServer
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Economy"), "GiftServer needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy

local GIFT_COINS = 25 -- the SERVER decides the reward, never the client
local GIFT_COOLDOWN = 60 -- seconds between two gifts for one player

local lastClaim: { [Player]: number } = {}

-- Runs when a client calls Net.InvokeServer("GiftClaim"). Returns (ok, message) to that client.
local function onGiftClaim(player: Player): (boolean, string)
	if not Data.IsLoaded(player) then
		return false, "Your data is still loading"
	end
	local now = os.clock()
	local last = lastClaim[player]
	if last ~= nil and now - last < GIFT_COOLDOWN then
		return false, `Come back in {math.ceil(GIFT_COOLDOWN - (now - last))} s`
	end
	lastClaim[player] = now
	Economy.Add(player, "Coins", GIFT_COINS)
	print(`[GiftServer] {player.Name} got {GIFT_COINS} Coins`)
	return true, `+{GIFT_COINS} Coins! You have {Economy.Get(player, "Coins")}`
end

-- At the TOP LEVEL of the script, so the remote exists before any client asks.
Net.OnInvoke("GiftClaim", onGiftClaim, { rate = 2, burst = 4 })

Players.PlayerRemoving:Connect(function(player: Player)
	lastClaim[player] = nil
end)

print("[GiftServer] ready")
```

What it does: it gives 25 Coins at most once per minute per player, and answers with a message.

## Step 2 — Create the menu, the buttons and the toasts

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **GameMenu**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/GameMenu
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("UI.Toast"), "GameMenu needs the UI.Toast package: install it (playbooks/start/01-install-packages.md)")
assert(Gaxia.IsInstalled("UI.Components"), "GameMenu needs the UI.Components package: install it (playbooks/start/01-install-packages.md)")
assert(Gaxia.IsInstalled("UI.Router"), "GameMenu needs the UI.Router package: install it (playbooks/start/01-install-packages.md)")
assert(Gaxia.IsInstalled("UI.Responsive"), "GameMenu needs the UI.Responsive package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Theme = Gaxia.Theme
local Toast = Gaxia.UI.Toast
local Components = Gaxia.UI.Components
local Router = Gaxia.UI.Router
local Responsive = Gaxia.UI.Responsive

local player = Players.LocalPlayer

-- 1. Colours first: widgets read the theme when they are CREATED.
Theme.SetTheme({ Color = { Primary = Color3.fromRGB(90, 140, 255) } })

-- 2. Settings the screens change (they live as long as this script).
local notificationsOn = true

local function notify(title: string, text: string, variant: string)
	if notificationsOn then
		Toast.Show({ Title = title, Text = text, Variant = variant, Duration = 4 })
	end
end

-- 3. The gift button asks the server and shows the answer.
local claiming = false
local function claimGift()
	if claiming then
		return -- wait for the answer before asking again
	end
	claiming = true
	local ok, message = Net.InvokeServer("GiftClaim")
	print(`[GameMenu] gift answer: {tostring(ok)} {tostring(message)}`)
	if ok == nil then
		message = "No answer, try again" -- nil = the server dropped the request (too many requests)
	end
	notify("Gift", tostring(message), if ok then "success" else "error")
	claiming = false
end

-- A text label (titles and the toggle's name).
local function addLabel(parent: Instance, text: string, position: UDim2, size: UDim2)
	local label = Instance.new("TextLabel")
	label.Position = position
	label.Size = size
	label.BackgroundTransparency = 1
	label.Font = Theme.Get().Font.Bold
	label.TextSize = 20
	label.TextColor3 = Theme.Color("Text")
	label.Text = text
	label.Parent = parent
end

-- A centred panel with a title. Every screen below starts with it.
local function makePanel(name: string, titleText: string, height: number): Frame
	local panel = Instance.new("Frame")
	panel.Name = name
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(320, height)
	panel.BackgroundColor3 = Theme.Color("Background")
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius("L"))
	corner.Parent = panel
	-- Fit phones and TVs: the scale is computed when the screen opens.
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = Responsive.ComputeScale(Responsive.GetViewport())
	uiScale.Parent = panel
	addLabel(panel, titleText, UDim2.fromOffset(0, 6), UDim2.new(1, 0, 0, 40))
	return panel
end

-- 4. Screens. Router calls the function each time the screen opens, so build it fresh.
Router.Register("MainMenu", function(_props: any): Instance
	local panel = makePanel("MainMenuPanel", "Menu", 230)
	Components.Button({ Text = "Claim gift", Position = UDim2.fromOffset(80, 54), Parent = panel, OnClick = claimGift })
	Components.Button({ Text = "Settings", Variant = "surface", Position = UDim2.fromOffset(80, 108), Parent = panel, OnClick = function() Router.Push("Settings") end }) -- opens on top of the menu
	Components.Button({ Text = "Close", Variant = "danger", Position = UDim2.fromOffset(80, 162), Parent = panel, OnClick = function() Router.Clear() end }) -- closes every open screen
	return panel
end)

Router.Register("Settings", function(_props: any): Instance
	local panel = makePanel("SettingsPanel", "Settings", 230)
	addLabel(panel, "Notifications", UDim2.fromOffset(20, 56), UDim2.fromOffset(180, 28))
	Components.Toggle({ Value = notificationsOn, Position = UDim2.fromOffset(244, 56), Parent = panel, OnChanged = function(on: boolean)
		notificationsOn = on
		print(`[GameMenu] notifications {if on then "on" else "off"}`)
	end })
	-- Slider: field of view from 50 to 100.
	addLabel(panel, "Field of view", UDim2.fromOffset(20, 92), UDim2.fromOffset(180, 24))
	Components.Slider({ Min = 50, Max = 100, Step = 1, Value = Workspace.CurrentCamera.FieldOfView, Position = UDim2.fromOffset(20, 122), Size = UDim2.fromOffset(280, 24), Parent = panel, OnChanged = function(value: number) Workspace.CurrentCamera.FieldOfView = value end })
	Components.Button({ Text = "Back", Variant = "surface", Position = UDim2.fromOffset(80, 162), Parent = panel, OnClick = function() Router.Pop() end }) -- closes only the top screen: the menu shows again
	return panel
end)

-- 5. A HUD button that opens and closes the menu. ResetOnSpawn = false keeps it after a respawn.
local hud = Instance.new("ScreenGui")
hud.Name = "GameMenuHud"
hud.ResetOnSpawn = false
hud.Parent = player:WaitForChild("PlayerGui")

local menuButton = Components.Button({ Text = "Menu", Size = UDim2.fromOffset(120, 44), Position = UDim2.new(0, 16, 0.5, -22), Parent = hud, OnClick = function()
	if Router.IsOpen("MainMenu") then
		Router.Clear()
	else
		Router.Push("MainMenu")
	end
	print(`[GameMenu] open screens: {Router.Depth()}`)
end })
Responsive.Apply(menuButton) -- this button lives forever, so the auto-updating Apply is fine here

notify("Welcome", "Press Menu to claim a gift", "info")
print("[GameMenu] ready")
```

What it does: a **Menu** button opens the `MainMenu` screen. **Settings** opens a second screen on top; **Back** returns.

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[GiftServer] ready` and `[GameMenu] ready`, and no red errors. A **Welcome** toast slides in at the top right.
3. Click **Menu**. Output shows `[GameMenu] open screens: 1` and the menu appears in the middle.
4. Click **Claim gift**. Output shows `[GiftServer] <YourName> got 25 Coins` and `[GameMenu] gift answer: true +25 Coins! You have 25`. A green toast shows the same text. (If you had Coins before, the total is higher. `Your data is still loading`: wait 3 seconds and click again.)
5. Click **Claim gift** again. A red toast says `Come back in 60 s` (or a smaller number).
6. Click **Settings**, then the switch. Output shows `[GameMenu] notifications off`. Click **Back**: the menu shows again. Click **Close**: everything closes.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `Gaxia.UI.NotificationService.Notify(...)` | `Gaxia.UI.Toast.Show({ Title = ..., Text = ... })` | NotificationService draws into `PlayerGui.Gaxia_UI`, which Gaxia does not create. It waits 10 seconds and shows nothing. Toast makes its own ScreenGui and queues messages. |
| `Gaxia.UI.MenuController.Open("Shop")` | `Router.Register` + `Router.Push` with `Components` | MenuController also needs `PlayerGui.Gaxia_UI` and its `Overlays` folder; without them the menu is never shown. |
| `Toast.Show("Saved!")` | `Toast.Show({ Text = "Saved!" })` | Show takes one table. `Text` is required; `Title`, `Variant`, `Duration` are optional. |
| `Theme.SetTheme(...)` after the buttons are made | Call it first, at the top | Existing widgets keep their colours. Only new ones use the new theme. |
| `Router.Push("MainMenu")` on every click | `if Router.IsOpen("MainMenu") then Router.Clear() else Router.Push("MainMenu") end` | Each Push adds one more copy on top. |
| The builder returns a panel made once at the top of the script | Build a new panel inside the builder | `Router.Pop` destroys the screen and the panel in it. The next Push would show nothing. |
| `Responsive.Apply(panel)` inside a Router builder | A `UIScale` with `Responsive.ComputeScale(Responsive.GetViewport())` (as in `makePanel`) | `Apply` connects to the camera and never disconnects. In a screen built on every open it adds one connection each time. Use `Apply` only on UI that lives forever. |
| A ScreenGui without `ResetOnSpawn = false` | `hud.ResetOnSpawn = false` | The default `true` deletes the UI when the character respawns. This script runs only once, so it never comes back. |

## Change it

- Toast colours: `Variant = "info"` (blue), `"success"` (green), `"warn"` (yellow), `"error"` (red). Show at most 2 at once: `Toast.SetMaxVisible(2)`. Remove all: `Toast.Clear()`.
- A yes/no popup before an action (it closes itself when a button is clicked; `Parent` must be a ScreenGui):
  ```lua
  -- fragment
  Components.Modal({ Title = "Reset?", Body = "Start again from zero?", Parent = hud, Buttons = {
  	{ Text = "Yes", Variant = "danger", OnClick = function() print("[GameMenu] reset chosen") end },
  	{ Text = "No", Variant = "surface" },
  } })
  ```
- More widgets: `Components.TextInput({ Placeholder = "Name", OnSubmit = function(text, enter) end })`, `Components.Dropdown({ Options = { "Easy", "Hard" }, OnChanged = function(v) end })`, `Components.Tabs({ Tabs = { "Items", "Pets" }, OnChanged = function(i, name) end })`. Each also takes `Position`, `Size` and `Parent`. A long list: `Components.ScrollList` (see its API page).
- Open the menu with a key: `Gaxia.Input.Bind` like the H key in [start/03](../start/03-client-script.md). Save settings between visits: the `Settings` package ([API: Settings](../api/Settings.md)).
- Different colours everywhere: change `Theme.SetTheme({ Color = { Primary = ..., Background = ..., Danger = ... } })`. Names: `Background`, `BackgroundDeep`, `Surface`, `Primary`, `Success`, `Danger`, `Warning`, `Text`, `TextMuted`.
- Phone-only layout: `if Responsive.GetDeviceClass() == "Phone" then ... end` (also `"Tablet"`, `"Desktop"`, `"Console"`).
- Slide a screen in (package `UI.Motion`): `local panel = Router.Push("MainMenu")`, then `if panel and panel:IsA("GuiObject") then Gaxia.UI.Motion.SlideIn(panel, "Up") end`. Not `Motion.Pop`: it overwrites the panel's UIScale.

## See also

- [API: UI.Toast](../api/UI.Toast.md) · [API: UI.Components](../api/UI.Components.md) · [API: UI.Router](../api/UI.Router.md) · [API: UI.Responsive](../api/UI.Responsive.md) · [API: Theme](../api/Theme.md) · [API: UI.Motion](../api/UI.Motion.md)
- [Client script](../start/03-client-script.md) · [Client ↔ server](../start/04-client-server-communication.md) · [Show values on screen](show-values-on-screen.md) · [Effects and feel](effects-and-feel.md) · [Troubleshooting](../troubleshooting.md)
