# Notifications, menus, buttons and screens

> A **Menu** button opens a menu. Its **Claim gift** button asks the server for Coins and shows the answer as a notification (toast).

**Use this when** the user asks for: "a notification", "a popup message", "a menu", "a button", "a settings screen", "a toggle", "a slider", "open and close a screen", "UI that fits phones" (ไทย: "แจ้งเตือน", "ข้อความเด้ง", "เมนู", "ปุ่ม", "หน้าตั้งค่า", "ปุ่มเปิดปิด", "สไลเดอร์", "เปิดปิดหน้าจอ", "UI ให้พอดีมือถือ").
**Packages:** client: `UI.Toast`, `UI.Components`, `UI.Router`, `UI.Responsive` (`Theme` comes with them). Server: `Economy` (it also installs `Data`). Optional, only for *Change it*: `Input` (open with a key), `Settings` (save settings), `UI.Motion` (slide in). The scripts below stop with a clear message if one is missing.
**You will create:** a Script `ServerScriptService/GiftServer` and a LocalScript `StarterPlayer/StarterPlayerScripts/GameMenu`.

Which package does what (use these, in a LocalScript):

| You want | Use | Do not use |
|---|---|---|
| A notification (toast) | `Gaxia.UI.Toast.Show` | `UI.NotificationService` |
| Buttons, toggles, sliders, text boxes, dropdowns, tabs, lists, yes/no popups | `Gaxia.UI.Components` | Hand-made buttons, `UI.Templates`, `UI.UIController` |
| Screens that open on top of each other (menu → settings → back) | `Gaxia.UI.Router` | `UI.MenuController` |
| UI that fits phones and TVs | `Gaxia.UI.Responsive` | Fixed pixel sizes only |
| One place for colours, fonts, spacing | `Gaxia.Theme` | `Color3.fromRGB` in every script |

`NotificationService`, `MenuController` and `UIController` draw into `PlayerGui.Gaxia_UI`, which Gaxia makes by itself the first time one of them needs it; they use the old template look, so this page uses the kit above. `Templates` start hidden. UI code is client code: it asks the server through `Gaxia.Net` ([start/04](../start/04-client-server-communication.md)).

## Step 1 — Create the server side of the gift button

Create a **Script** in **ServerScriptService** named **GiftServer**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/GiftServer
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Economy"), "GiftServer needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local GIFT_COINS = 25 -- the SERVER decides the reward, never the client
local GIFT_COOLDOWN = 60 -- seconds between two gifts for one player
local lastClaim: { [Player]: number } = {}

-- Runs when a client calls Net.InvokeServer("GiftClaim"). Returns (ok, message) to that client.
local function onGiftClaim(player: Player): (boolean, string)
	if not Data.IsLoaded(player) then return false, "Your data is still loading" end
	local now = os.clock()
	local last = lastClaim[player]
	if last ~= nil and now - last < GIFT_COOLDOWN then
		return false, `Come back in {math.ceil(GIFT_COOLDOWN - (now - last))} s`
	end
	if not Economy.Add(player, "Coins", GIFT_COINS) then
		return false, "Could not add Coins, try again" -- Add returns false when it fails
	end
	lastClaim[player] = now -- start the cooldown only after the Coins were given
	print(`[GiftServer] {player.Name} got {GIFT_COINS} Coins`)
	return true, `+{GIFT_COINS} Coins! You have {Economy.Get(player, "Coins")}`
end

-- At the TOP LEVEL, so the remote exists before any client asks. At most 2 calls per second
-- per player (4 in a quick burst); extra calls return nil to the client.
Net.OnInvoke("GiftClaim", onGiftClaim, { rate = 2, burst = 4 })
Players.PlayerRemoving:Connect(function(player: Player) lastClaim[player] = nil end) -- forget players who left
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
for _, package in { "UI.Toast", "UI.Components", "UI.Router", "UI.Responsive" } do
	assert(Gaxia.IsInstalled(package), `GameMenu needs the {package} package: install it (playbooks/start/01-install-packages.md)`)
end
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
	if notificationsOn then Toast.Show({ Title = title, Text = text, Variant = variant, Duration = 4 }) end
end

-- 3. The gift button asks the server and shows the answer.
local claiming = false
local function claimGift()
	if claiming then return end -- wait for the answer before asking again
	claiming = true
	local okCall, ok, message = pcall(Net.InvokeServer, "GiftClaim") -- pcall: a server error must not stop this function
	print(`[GameMenu] gift answer: {tostring(ok)} {tostring(message)}`)
	if not okCall or ok == nil then
		ok, message = false, "No answer, try again" -- the call failed, or the server dropped it (too many requests)
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
-- A centred panel (320 pixels wide) with a title. Every screen below starts with it.
local function makePanel(name: string, titleText: string, height: number): Frame
	local panel = Instance.new("Frame")
	panel.Name = name
	panel.AnchorPoint = Vector2.new(0.5, 0.5) -- Position is the panel's centre
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(320, height)
	panel.BackgroundColor3 = Theme.Color("Background")
	local uiScale = Instance.new("UIScale") -- fit phones and TVs, computed when the screen opens
	uiScale.Scale = Responsive.GetScale() -- never below 0.75 on touch screens, so buttons stay tappable
	uiScale.Parent = panel
	addLabel(panel, titleText, UDim2.fromOffset(0, 6), UDim2.new(1, 0, 0, 40))
	return panel
end

-- 4. Screens. Router calls the function each time the screen opens, so build it fresh.
-- Router makes its own ScreenGui for each screen under PlayerGui: you do not create one.
-- Button: 160 x 44 pixels unless you pass Size. Variant: "primary" (default, blue), "surface" (grey), "danger" (red).
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
	Components.Toggle({ Value = notificationsOn, Size = UDim2.fromOffset(56, 28), Position = UDim2.fromOffset(244, 56), Parent = panel, OnChanged = function(on: boolean)
		notificationsOn = on
		print(`[GameMenu] notifications {if on then "on" else "off"}`)
	end })
	addLabel(panel, "Field of view", UDim2.fromOffset(20, 92), UDim2.fromOffset(180, 24))
	Components.Slider({ Min = 50, Max = 100, Step = 1, Value = Workspace.CurrentCamera.FieldOfView, Position = UDim2.fromOffset(20, 122), Size = UDim2.fromOffset(280, 24), Parent = panel, OnChanged = function(value: number) Workspace.CurrentCamera.FieldOfView = value end })
	Components.Button({ Text = "Back", Variant = "surface", Position = UDim2.fromOffset(80, 162), Parent = panel, OnClick = function() Router.Pop() end }) -- closes only the top screen: the menu shows again
	return panel
end)

-- 5. A HUD button that opens and closes the menu.
local hud = Instance.new("ScreenGui")
hud.Name = "GameMenuHud"
hud.ResetOnSpawn = false -- keep it after a respawn
hud.DisplayOrder = 200 -- above Router screens (100 and up), so popups parented here show on top
hud.Parent = player:WaitForChild("PlayerGui")
local function toggleMenu()
	if Router.IsOpen("MainMenu") then
		Router.Clear()
	else
		Router.Push("MainMenu")
	end
	print(`[GameMenu] open screens: {Router.Depth()}`)
end
Components.Button({ Text = "Menu", Size = UDim2.fromOffset(120, 44), Position = UDim2.new(0, 16, 0.5, -22), Parent = hud, OnClick = toggleMenu })
notify("Welcome", "Press Menu to claim a gift", "info")
print("[GameMenu] ready")
```

What it does: **Menu** opens the `MainMenu` screen. **Settings** opens a second screen on top; **Back** returns.

## Check that it works

1. Press **Play** in Studio. Output shows `[GiftServer] ready` and `[GameMenu] ready`, and no red errors. A **Welcome** toast slides in at the top right.
2. Click **Menu**. Output shows `[GameMenu] open screens: 1` and the menu appears in the middle.
3. Click **Claim gift**. Output shows `[GiftServer] <YourName> got 25 Coins` and `[GameMenu] gift answer: true +25 Coins! You have 25`. A toast with a green bar on its left shows the same text. (If you had Coins before, the total is higher. `Your data is still loading`: wait 3 seconds and click again.)
4. Click **Claim gift** again. A toast with a red bar says `Come back in 60 s` (or a smaller number).
5. Click **Settings**, then the switch. Output shows `[GameMenu] notifications off`. Click **Back**: the menu shows again. Click **Close**: everything closes.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `Toast.Show("Saved!")` | `Toast.Show({ Text = "Saved!" })` | Show takes one table. `Text` is required; `Title`, `Variant`, `Duration` are optional. |
| `Router.Push("MainMenu")` on every click | `toggleMenu` (as above) | Each Push adds one more copy on top. |
| The builder returns a panel made once at the top of the script | Build a new panel inside the builder | `Router.Pop` destroys the screen and the panel in it. The next Push would show nothing. |
| A ScreenGui without `ResetOnSpawn = false` | `hud.ResetOnSpawn = false` | The default `true` deletes the UI when the character respawns. This script runs once, so it never comes back. |
| `local ok, message = Net.InvokeServer(...)` | `pcall(Net.InvokeServer, ...)` (as in `claimGift`) | InvokeServer throws when the server errors. `claiming` stays `true` and the button stops working. |

## Change it

- Toast accent colours (the bar on the left): `Variant = "info"` (blue), `"success"` (green), `"warn"` (yellow), `"error"` (red). Show at most 2 at once: `Toast.SetMaxVisible(2)`. Remove all: `Toast.Clear()`.
- A yes/no popup (it closes itself when a button is clicked). Parent it to `hud`: its dark background covers that ScreenGui, which shows above the menu: `Components.Modal({ Title = "Reset?", Body = "Start again from zero?", Parent = hud, Buttons = { { Text = "Yes", Variant = "danger", OnClick = function() print("[GameMenu] reset chosen") end }, { Text = "No", Variant = "surface", OnClick = function() print("[GameMenu] reset cancelled") end } } })`.
- More widgets: `Components.TextInput({ Placeholder = "Name", OnSubmit = function(text, enter) end })`, `Components.Dropdown({ Options = { "Easy", "Hard" }, OnChanged = function(v) end })`, `Components.Tabs({ Tabs = { "Items", "Pets" }, OnChanged = function(i, name) end })`. Each also takes `Position`, `Size` and `Parent`.
- A long list, inside a Router builder after `local panel = makePanel(...)`. `Render` runs for each visible row and reuses rows, so it makes the label only once per row: `Components.ScrollList({ Items = { "Sword", "Shield", "Bow" }, ItemHeight = 36, Size = UDim2.fromOffset(280, 120), Position = UDim2.fromOffset(20, 56), Parent = panel, Render = function(item: any, _index: number, row: Frame) local label = row:FindFirstChildOfClass("TextLabel") or Instance.new("TextLabel"); label.Size = UDim2.fromScale(1, 1); label.Text = tostring(item); label.Parent = row end })`.
- Open the menu with the **M** key (package `Input`). Add this line at the end of GameMenu: `Gaxia.Input.Bind("ToggleMenu", { Enum.KeyCode.M }, function(_name, state) if state == "Begin" then toggleMenu() end end)`.
- Save the Notifications switch between visits (package `Settings`: install it first, or `GaxiaServer.Settings` is nil and GiftServer stops with an error). In GiftServer, after the `local lastClaim` line, add:
  ```lua
  -- fragment
  GaxiaServer.Settings.RegisterSetting("Notifications", function(value: any): boolean return typeof(value) == "boolean" end)
  Net.OnInvoke("LoadSettings", function(player: Player) Data.WaitFor(player, 15); return GaxiaServer.Settings.GetAll(player) end)
  Net.OnServer("SaveNotifications", function(player: Player, on: any) GaxiaServer.Settings.Set(player, "Notifications", on) end, { rate = 2, burst = 4 })
  ```
  In GameMenu, add `Net.FireServer("SaveNotifications", on)` after `notificationsOn = on`. After the `local notificationsOn = true` line, add (the answer comes once the data has loaded): `task.spawn(function() local saved = Net.InvokeServer("LoadSettings"); if typeof(saved) == "table" and typeof(saved.Notifications) == "boolean" then notificationsOn = saved.Notifications end end)`.
- Phones: `makePanel` shrinks the panel on small screens (down to half size; on touch screens only down to 0.75). For full-size buttons on phones, write `uiScale.Scale = math.max(1, Responsive.GetScale())`. To keep the size right when the window is resized while the screen is open, replace all three `uiScale` lines in `makePanel` (`local uiScale = ...`, `uiScale.Scale = ...` and `uiScale.Parent = panel`) with the one line `Responsive.Apply(panel)` (its listener is removed when the screen closes). Phone-only layout: `if Responsive.GetDeviceClass() == "Phone" then ... end` (also `"Tablet"`, `"Desktop"`, `"Console"`).
- Different colours everywhere: change the `Theme.SetTheme` line at the top. It must run before any widget is made: existing widgets keep their colours. `Theme.SetTheme({ Color = { Primary = ..., Background = ..., Danger = ... } })`. Names: `Background`, `BackgroundDeep`, `Surface`, `Primary`, `Success`, `Danger`, `Warning`, `Text`, `TextMuted`.
- Slide a screen in (package `UI.Motion`): in `toggleMenu`, write `local panel = Router.Push("MainMenu")`, then `if panel and panel:IsA("GuiObject") then Gaxia.UI.Motion.SlideIn(panel, "Up") end`. Not `Motion.Pop`: it overwrites the panel's UIScale.

## See also

- [API: UI.Toast](../api/UI.Toast.md) · [API: UI.Components](../api/UI.Components.md) · [API: UI.Router](../api/UI.Router.md) · [API: UI.Responsive](../api/UI.Responsive.md) · [API: Theme](../api/Theme.md) · [API: UI.Motion](../api/UI.Motion.md) · [API: Settings](../api/Settings.md)
- [Client script](../start/03-client-script.md) · [Client ↔ server](../start/04-client-server-communication.md) · [Show values on screen](show-values-on-screen.md) · [Effects and feel](effects-and-feel.md) · [Troubleshooting](../troubleshooting.md)
