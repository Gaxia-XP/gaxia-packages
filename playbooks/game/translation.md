# Translate the game into Thai (and other languages)

> Every label, button and toast shows in English or Thai. The game starts in the player's Roblox language. A **Language** menu switches it, and the choice is saved.

**Use this when** the user asks for: "translate the game", "Thai language", "multi-language", "localization", "language setting", "switch language", "i18n" (ไทย: "แปลเกม", "ภาษาไทย", "หลายภาษา", "เปลี่ยนภาษา", "ตั้งค่าภาษา", "เมนูเลือกภาษา").
**Packages:** `Localization`, `UI.Toast`, `UI.Components` (it brings `Theme`) on the client, and `Settings` (it brings `Data`) on the server. The scripts below stop with a clear message if one is missing.
**You will create:** a ModuleScript `ReplicatedStorage/GameShared/Strings`, a Script `ServerScriptService/LanguageServer` and a LocalScript `StarterPlayer/StarterPlayerScripts/LanguageUI`.

How it works:

- `Gaxia.Localization.Load(locale, table)` stores the texts of one language. `Localization.T(key, vars)` returns the text for `key` in the current language.
- A key missing in Thai shows the **English** text. A key missing everywhere shows the key itself (never an error).
- `{name}` in a text is replaced by `vars.name`: `T("hud.greeting", { name = "Gax" })`.
- `Localization.SetLocale("th")` switches the language and runs every `OnLocaleChanged` function, so the UI can redraw.
- The current language is **one value per script world**. The server cannot translate for each player. So the server sends a **key** (and vars) and the client translates it.
- `GaxiaServer.Settings` saves the chosen language in the player's data.

## Step 1 — Write the texts for each language

In **ReplicatedStorage**, create a **Folder** named **GameShared**. In it, create a **ModuleScript** named **Strings**. Paste this whole block into it:

```lua
-- ModuleScript: ReplicatedStorage/GameShared/Strings
-- Every text the players see. One table per language. The keys are the same in every language.
-- {name} and {count} are filled in by Localization.T(key, vars).
local Strings: { [string]: { [string]: string } } = {
	en = {
		["hud.title"] = "My Game",
		["hud.greeting"] = "Hello, {name}!",
		["hud.tip"] = "Tip: open Language to switch.", -- no Thai text on purpose: Thai players see this English one
		["button.hello"] = "Say hello",
		["button.language"] = "Language",
		["button.close"] = "Close",
		["settings.title"] = "Choose a language",
		["toast.welcome"] = "Welcome, {name}!",
		["toast.hello"] = "{name} said hello {count} times",
		["toast.language"] = "Language: English",
	},
	th = {
		["hud.title"] = "เกมของฉัน",
		["hud.greeting"] = "สวัสดี {name}!",
		["button.hello"] = "ทักทาย",
		["button.language"] = "ภาษา",
		["button.close"] = "ปิด",
		["settings.title"] = "เลือกภาษา",
		["toast.welcome"] = "ยินดีต้อนรับ {name}!",
		["toast.hello"] = "{name} ทักทายแล้ว {count} ครั้ง",
		["toast.language"] = "ภาษา: ไทย",
	},
}

return Strings
```

Why ReplicatedStorage: the client needs the texts. The server only uses the keys.

## Step 2 — Save the language and send translated toasts from the server

Create a **Script** in **ServerScriptService** named **LanguageServer**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/LanguageServer
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Settings"), "LanguageServer needs the Settings package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Settings = GaxiaServer.Settings
local LANGUAGES: { [string]: boolean } = { en = true, th = true } -- the languages in Strings
local helloCount: { [Player]: number } = {}

-- Only "en" or "th" can be saved. Anything else from a client is refused.
Settings.RegisterSetting("Language", function(value: any): boolean
	return typeof(value) == "string" and LANGUAGES[value] == true
end)

-- The client asks for the saved language. nil = the player never chose one.
Net.OnInvoke("LanguageGet", function(player: Player): string?
	if Data.WaitFor(player, 15) == nil then
		return nil -- data did not load in time: the client keeps its Roblox language
	end
	local saved = Settings.Get(player, "Language")
	return if typeof(saved) == "string" then saved else nil
end)

-- The client saves a new choice. Settings.Set checks it with the function above.
Net.OnServer("LanguageSet", function(player: Player, language: any)
	if Settings.Set(player, "Language", language) then
		print(`[LanguageServer] {player.Name} chose {language}`)
	end
end, { rate = 2, burst = 4 })

-- The server never sends finished text: it sends a KEY and the values. The client translates.
Net.DeclareEvent("LanguageToast")
Net.OnServer("LanguageHello", function(player: Player)
	local count = (helloCount[player] or 0) + 1
	helloCount[player] = count
	print(`[LanguageServer] {player.Name} said hello {count} times`)
	Net.FireClient(player, "LanguageToast", "toast.hello", { name = player.DisplayName, count = count })
end, { rate = 2, burst = 4 })

Players.PlayerRemoving:Connect(function(player: Player)
	helloCount[player] = nil -- forget players who left
end)

print("[LanguageServer] ready")
```

What it does: it saves the language in the player's data and answers **Say hello** with a toast key.

## Step 3 — Translate the UI and add the Language menu

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **LanguageUI**. Paste this whole block into it:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/LanguageUI
local Players = game:GetService("Players")
local LocalizationService = game:GetService("LocalizationService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Gaxia = require(ReplicatedStorage.Gaxia_Packages)
local Strings = require(ReplicatedStorage:WaitForChild("GameShared"):WaitForChild("Strings"))
for _, package in { "Localization", "UI.Toast", "UI.Components" } do
	assert(Gaxia.IsInstalled(package), `LanguageUI needs the {package} package: install it (playbooks/start/01-install-packages.md)`)
end

local Net = Gaxia.Net
local Localization = Gaxia.Localization
local Toast = Gaxia.UI.Toast
local Components = Gaxia.UI.Components
local player = Players.LocalPlayer
local T = Localization.T

-- 1. Load every language. English is the fallback for missing keys.
for language, texts in Strings do
	Localization.Load(language, texts)
end

-- 2. Start in the player's Roblox language ("th-th" -> "th"). Unknown languages -> English.
local robloxLanguage = string.lower(string.sub(LocalizationService.RobloxLocaleId, 1, 2))
Localization.SetLocale(if Strings[robloxLanguage] then robloxLanguage else "en")
print(`[LanguageUI] Roblox language {LocalizationService.RobloxLocaleId}, using {Localization.GetLocale()}`)

-- 3. bind() shows a key now and again after every language change.
local redraws: { () -> () } = {}
local function bind(key: string, vars: { [string]: any }?, apply: (text: string) -> ())
	local function redraw()
		apply(T(key, vars))
	end
	redraw()
	table.insert(redraws, redraw)
end
Localization.OnLocaleChanged(function(language: string)
	for _, redraw in redraws do
		redraw()
	end
	print(`[LanguageUI] language is now {language}`)
end)

-- 4. The screen. AutoLocalize = false: Roblox must not translate our texts a second time.
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LanguageGui"
screenGui.ResetOnSpawn = false
screenGui.AutoLocalize = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local function addLabel(parent: Instance, position: UDim2, size: UDim2): TextLabel
	local label = Instance.new("TextLabel")
	label.Position = position
	label.Size = size
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = parent
	return label
end

local title = addLabel(screenGui, UDim2.fromOffset(16, 16), UDim2.fromOffset(300, 40))
bind("hud.title", nil, function(text: string) title.Text = text end)
local greeting = addLabel(screenGui, UDim2.fromOffset(16, 60), UDim2.fromOffset(300, 30))
bind("hud.greeting", { name = player.DisplayName }, function(text: string) greeting.Text = text end)
local tip = addLabel(screenGui, UDim2.fromOffset(16, 94), UDim2.fromOffset(300, 24))
bind("hud.tip", nil, function(text: string) tip.Text = text end)

local helloButton = Components.Button({ Position = UDim2.fromOffset(16, 130), Parent = screenGui, OnClick = function()
	Net.FireServer("LanguageHello") -- the answer comes back as a LanguageToast key
end })
bind("button.hello", nil, function(text: string) helloButton.Text = text end)

-- 5. The Language menu (hidden until the Language button is clicked).
local panel = Instance.new("Frame")
panel.Name = "LanguagePanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(320, 230)
panel.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
panel.Visible = false
panel.Parent = screenGui
local panelTitle = addLabel(panel, UDim2.fromOffset(0, 8), UDim2.new(1, 0, 0, 36))
bind("settings.title", nil, function(text: string) panelTitle.Text = text end)

local function chooseLanguage(language: string)
	Localization.SetLocale(language) -- every bound label redraws
	Net.FireServer("LanguageSet", language) -- the server saves it
	Toast.Show({ Text = T("toast.language"), Variant = "success", Duration = 3 })
end
-- Language names stay in their own language, so every player can find theirs.
Components.Button({ Text = "English", Position = UDim2.fromOffset(80, 54), Parent = panel, OnClick = function() chooseLanguage("en") end })
Components.Button({ Text = "ภาษาไทย", Position = UDim2.fromOffset(80, 108), Parent = panel, OnClick = function() chooseLanguage("th") end })
local closeButton = Components.Button({ Variant = "danger", Position = UDim2.fromOffset(80, 162), Parent = panel, OnClick = function() panel.Visible = false end })
bind("button.close", nil, function(text: string) closeButton.Text = text end)

local languageButton = Components.Button({ Variant = "surface", Position = UDim2.fromOffset(16, 184), Parent = screenGui, OnClick = function()
	panel.Visible = not panel.Visible
end })
bind("button.language", nil, function(text: string) languageButton.Text = text end)

-- 6. Toasts from the server arrive as a key + values. Translate them here.
Net.OnClient("LanguageToast", function(key: any, vars: any)
	if typeof(key) ~= "string" then return end
	Toast.Show({ Text = T(key, if typeof(vars) == "table" then vars else nil), Variant = "info", Duration = 4 })
end)

-- 7. Use the saved choice (it waits for the player's data), then say welcome in that language.
task.spawn(function()
	local called, saved = pcall(Net.InvokeServer, "LanguageGet")
	if called and typeof(saved) == "string" and Strings[saved] then
		Localization.SetLocale(saved)
		print(`[LanguageUI] saved language {saved}`)
	end
	Toast.Show({ Text = T("toast.welcome", { name = player.DisplayName }), Variant = "info", Duration = 4 })
end)

print("[LanguageUI] ready")
```

What it does: it shows every text through `T`, redraws all of them when the language changes, and saves the choice.

## Check that it works

1. Press **Play** in Studio. Output shows `[LanguageServer] ready`, `[LanguageUI] Roblox language en-us, using en` and `[LanguageUI] ready`, and no red errors.
2. The top left shows **My Game**, **Hello, <YourName>!** and the tip. A **Welcome, <YourName>!** toast appears.
3. Click **Say hello**. Output shows `[LanguageServer] <YourName> said hello 1 times`. A toast says the same.
4. Click **Language**, then **ภาษาไทย**. Output shows `[LanguageUI] language is now th` and `[LanguageServer] <YourName> chose th`. The labels and buttons turn Thai. The tip stays **English** (it has no Thai text: the fallback). A toast says **ภาษา: ไทย**.
5. Click **ทักทาย**. The toast is now Thai: `<YourName> ทักทายแล้ว 2 ครั้ง`.
6. Stop and press **Play** again (needs **Enable Studio Access to API Services**, see [player-data](player-data.md)). Output shows `[LanguageUI] saved language th` and the UI starts in Thai.
7. To test the automatic pick: open the **Test** tab → **Player** (Player Emulator), turn it on, set **Locale** to `th-th`, and press **Play**. If no language was saved yet, Output shows `using th`.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `label.Text = "Hello"` | `bind("hud.greeting", vars, function(text) label.Text = text end)` | Fixed text never changes language. `bind` also redraws it after `SetLocale`. |
| `label.Text = T("hud.title")` once | `bind("hud.title", nil, ...)` | `T` reads the language **now**. After a switch the label keeps the old text. |
| Server: `Net.FireClient(player, "LanguageToast", Localization.T("toast.hello"))` | Send the key: `"toast.hello", { name = ..., count = ... }` | The server has one language for everyone. Only the client knows the player's language. |
| `Settings.Set(player, "Language", lang)` with no `RegisterSetting` | `Settings.RegisterSetting("Language", validator)` first | Unknown setting keys are refused (a warning in Output, nothing saved). |
| A key in `th` that is not in `en` | Add every key to `en` first | English is the fallback. A key missing in both shows as the raw key (`hud.title`). |
| Leaving `AutoLocalize` on | `screenGui.AutoLocalize = false` | With Roblox automatic translation on, Roblox may translate your English texts again, against the player's choice. |

## Change it

- To add a language (for example Japanese): add `ja = { ["hud.title"] = "マイゲーム", ... }` to `Strings`, add `ja = true` to `LANGUAGES` in LanguageServer, and add one more button in LanguageUI: `Components.Button({ Text = "日本語", Position = UDim2.fromOffset(80, 216), Parent = panel, OnClick = function() chooseLanguage("ja") end })` (make `panel` taller: `UDim2.fromOffset(320, 280)`).
- To add a new text: add the key to `en` (and `th`), then `bind("my.key", nil, function(text: string) myLabel.Text = text end)`.
- To show a number that changes (Coins): call `T` each time the number changes, for example `coinsLabel.Text = T("hud.coins", { n = coins })`, and also redraw it in `OnLocaleChanged`.
- To use a dropdown instead of buttons: `Components.Dropdown({ Options = { "English", "ภาษาไทย" }, Parent = panel, OnChanged = function(name: string) chooseLanguage(if name == "English" then "en" else "th") end })`.
- To translate toasts the client makes itself: `Toast.Show({ Text = T("my.key") })`, as `chooseLanguage` does.

## See also

- [API: Localization](../api/Localization.md) · [API: Settings](../api/Settings.md) · [API: UI.Toast](../api/UI.Toast.md) · [API: UI.Components](../api/UI.Components.md)
- [UI: menus and toasts](ui.md) · [Player data](player-data.md) · [Client ↔ server](../start/04-client-server-communication.md) · [Troubleshooting](../troubleshooting.md)
