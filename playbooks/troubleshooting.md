# Fix an error, or a feature that does nothing

> You find the exact error text or symptom in a table below, apply the fix in its last column, and press Play again until Output has no red lines.

**Use this when** the user says: "error", "it does not work", "nothing happens", "X is nil", "infinite yield", "player got kicked", "data not saving", "bought but got nothing", "Script Analysis shows red", "GAME LAYOUT", "HARNESS ERROR", "data not loaded" (ไทย: "error", "ไม่ทำงาน", "กดแล้วไม่เกิดอะไร", "ขึ้นตัวแดง", "เป็น nil", "โดนเตะออก", "ข้อมูลไม่เซฟ", "ซื้อแล้วไม่ได้ของ", "ติดตั้งไม่ได้").
**Packages:** any. This page works with every install.
**You will create:** nothing, except (only in Step 3) a temporary Script `ServerScriptService/HealthCheck` that you delete afterwards.

## Step 1 — Find the first problem line

1. In Studio open **View → Output** and **View → Script Analysis**. Press **Play**.
2. Scroll Output to the **first** red line (error) or yellow line (warning). Fix that one first: later errors often come from it.
3. Copy the error text and the script name and line, for example `ServerScriptService.SimShop:12: attempt to index nil with 'Purchase'`.
4. No error at all, but nothing happens? Check that your script printed its `[ScriptName] ready` line. No ready line = the script did not run (table A).

## Step 2 — Look the text up and apply the fix

Search this page for a few words of the error, without your own names and numbers (for example `not registered by server`). Do the **Fix** column exactly, then press **Play** again. The tables are grouped:
A. requires and loading · B. packages missing, nil services · C. player data · D. remotes (Net) · E. coins, shop, Robux · F. anti-cheat · G. UI and client · H. Script Analysis · I. installing (Companion, Rojo) · J. other packages · K. headless runs (`run-game`).

### A. Requires and loading

| Symptom | Cause | Fix |
|---|---|---|
| `init is not a valid member of ModuleScript "ServerStorage.Gaxia_Packages_Server"` (or `...Gaxia_Packages`) | `.init` after the package name | `local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)`; client: `local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)` |
| `Gaxia_Packages_Server is not a valid member of ServerStorage` in a **LocalScript** | The client cannot see ServerStorage: server code was put in client code | Client code requires only `Gaxia_Packages`. Do the server work in a Script and ask it with Net ([04-client-server](start/04-client-server-communication.md)). |
| The same error in a **Script**, or `Gaxia_Packages is not a valid member of ReplicatedStorage` | Gaxia is not installed in this place (Rojo: not connected) | Install it ([01-install-packages](start/01-install-packages.md)). Rojo: run `rojo serve`, then **Plugins → Rojo → Connect**. |
| `[Gaxia_Packages_Server] Cannot require server package from the client.` | A LocalScript or a ModuleScript in ReplicatedStorage requires the server package | Move that code to a Script in ServerScriptService. Never move `Gaxia_Packages_Server` out of ServerStorage. |
| `Requested module experienced an error while loading` | Your ModuleScript errored while it was required | Fix the first red line above it (it names your ModuleScript). |
| `GameModules is not a valid member of ServerStorage` | The Folder is missing or misnamed | Create a **Folder** named exactly `GameModules` in ServerStorage, with the ModuleScripts inside it. |
| `attempt to yield across metamethod/C-call boundary` | Code that waits (`task.wait`, `WaitForChild`, `:Wait()`, `Data.WaitFor`, `Net.InvokeServer`) runs inside your own metatable `__index`/`__newindex`, or inside a `table.sort` comparator or `string.gsub` function | Wait first and keep the results in locals, then sort or index. Never wait inside those functions. |
| A LocalScript prints nothing at all | It is a **Script**, or it is in Workspace / ServerScriptService | A **LocalScript** in `StarterPlayer/StarterPlayerScripts` ([03-client-script](start/03-client-script.md)). |
| A Script prints nothing at all | It is in ServerStorage or ReplicatedStorage | Scripts run only in ServerScriptService (or Workspace). |
| A LocalScript stops at `player.CharacterAdded:Wait()` | The character already existed when the script ran | `player.CharacterAdded:Connect(f)` plus `if player.Character then task.spawn(f, player.Character) end` |

### B. Packages missing, nil services

| Symptom | Cause | Fix |
|---|---|---|
| `attempt to index nil with 'Spend'` where the nil is `GaxiaServer.Economy` (any service) | The package is not installed, or it failed to load or start | Run **HealthCheck** (Step 3). `NOT INSTALLED` → install it. `FAILED TO LOAD` / `FAILED TO START` → copy the line it names to the user; never edit the framework. |
| Your own assert: `X needs the Y package: install it` | Package Y is not installed | Add Y: repeat Step 2 of [01-install-packages](start/01-install-packages.md) with Y also ticked. |
| `[CheckInstall] UI.Toast: MISSING`, or `GaxiaServer.IsInstalled("UI.Toast")` is false | Server `IsInstalled` knows only server services | Check client and shared packages in a LocalScript: `Gaxia.IsInstalled("UI.Toast")`. |
| `GaxiaServer.IsInstalled("Guard")` is false although Guard is installed | Guard is a shared package | `Gaxia.IsInstalled("Guard")` (works in a Script too). |
| `Gaxia.IsInstalled("Economy")` is false in a LocalScript | Server packages are not visible to the client | Check them with `GaxiaServer.IsInstalled("Economy")` in a Script. |
| `Gaxia.IsInstalled("Util")` is false | `Util` is a folder | `Gaxia.IsInstalled("Util.Table")` |
| `attempt to index nil with 'Shake'` (or `'Show'`, `'PlayMusic'`) in a **Script** | `Gaxia.Camera`, `Gaxia.UI`, `Gaxia.Sound`, `Gaxia.Effects` are client modules: nil on the server | Call them in a LocalScript. The server tells clients with `Net.FireAllClients` ([effects-and-feel](game/effects-and-feel.md)). |
| Robux receipts or another boot package do nothing after ticking **All** or `packages.mjs build --all` (`[CheckInstall] picked: nil`) | A full install records no pick: it boots only the fixed list in `Config/Features`, without `Monetization` | Install with a pick instead (Companion: **None**, then tick; Rojo: `--select`). Or call `GaxiaServer.Monetization.RegisterProduct` at the top of a Script (first use starts it). |
| `Data` / `Monetization` stopped starting after you added `ServerStorage/GaxiaFeatures` | That module **replaces** the whole boot list | List every service that must boot (Data, Player, Monetization if you sell Robux items). |
| `[Gaxia_Packages_Server] Features: "X" is not installed` | `GaxiaFeatures` lists a package this place does not have | Remove `X` from the list, or install it. |
| `[Gaxia_Packages_Server] Chat is running without Admin: ...` | Admin is installed but not started (missing from `GaxiaFeatures`) | Add `"Admin"` to `GaxiaFeatures`, or delete `GaxiaFeatures`. |
| Your Scripts or a changed Config module vanished after **Install / Update** | Install replaces `Gaxia_Packages`, `Gaxia_Packages_Server` and both bootstraps | Keep game code in your own Scripts and ModuleScripts. Settings: [config-and-flags](game/config-and-flags.md). |

### C. Player data

| Symptom | Cause | Fix |
|---|---|---|
| `Data.Get` returns nil, `Data.Set` returns false, or `attempt to perform arithmetic on nil` right after join | The data loads a moment after the player joins | `if Data.WaitFor(player, 120) == nil then return end` first, inside `onPlayerAdded` ([02-server-script](start/02-server-script.md)). In loops: `if Data.IsLoaded(player) then`. |
| Code never runs for players who were already in the game | `GaxiaServer.Player.OnPlayerJoined` / `GaxiaServer.Data.OnLoaded` do not fire again for earlier players | `Players.PlayerAdded:Connect(f)` plus `for _, p in Players:GetPlayers() do task.spawn(f, p) end`, and `Data.WaitFor` inside `f`. |
| `Data.Get(player, "Wins") + 1` errors although your script adds `Wins` | The field is created with `Data.Set` after the load, or `Data.SetDefaults` runs late (after a `task.wait` or inside `PlayerAdded`) | Call `Data.SetDefaults({ Wins = 0 })` at the top of a Script ([player-data](game/player-data.md) Step 1). |
| Data resets every Play; Output: `[ProfileService]: Roblox API services unavailable - data will not be saved` | Studio API access is off | Publish the place, then **Game Settings → Security → Enable Studio Access to API Services**. Play still works without it. |
| Kicked with `Could not load your data. Please rejoin.` | The data could not be loaded: the same account is still loaded on another server (a fast rejoin), or the DataStore failed. Output has a `[DataManager] Could not load profile …` warning with the reason | Wait a minute and join again. |
| Kicked with `Your data was opened on another server. Please rejoin.` | The same account joined another server, which took over the data | Play on one server at a time. |
| A call returns `false, "data not loaded"` (or `nil, "data not loaded"`): `Inventory.Add` / `Equip`, `Mail.Send`, `DailyReward.Claim`, `Pet.RemovePet`, `Guild.*`, `Friend.*` | The player's data is still loading (right after join). The call did nothing: no item, mail, reward or change | Call it after `Data.WaitFor(player, 120)`. From a button: answer "Your data is still loading" and let the player click again. `Shop.Purchase` says the same with `not_loaded` (table E). |
| `[DataManager] SetDefaults was called after player data loaded` | `Data.SetDefaults` runs late (inside `PlayerAdded`, after a `task.wait`, or in a function called later) | Move `Data.SetDefaults({ ... })` to the top of a Script ([player-data](game/player-data.md) Step 1). |
| TypeError `Cannot add property 'X' to table 'PlayerData'` | Game code added a field to `GaxiaServer.Data.DEFAULT_PROFILE` | Leave it alone. List your fields with `Data.SetDefaults` ([player-data](game/player-data.md) Step 1). |
| Saved data lost, or the save fails | An Instance, Vector3, CFrame or Color3 was saved, or a table with mixed number keys | Save only numbers, strings, booleans and tables with string keys (`tostring(userId)`). |
| Unlocking something for one player unlocks it for all | One defaults table is shared by every player | List the field in `Data.SetDefaults` ([player-data](game/player-data.md) Step 1): each player gets their own copy. |
| Your field overwrites framework data | Its name is taken (`Coins`, `Level`, `Inventory`, `Pets`, `Quests`, …) | Use your own names. Full list: [player-data](game/player-data.md). |

### D. Remotes (Net)

| Symptom | Cause | Fix |
|---|---|---|
| `[NetService] Remote 'X' not registered by server` about 10 s after start | The client calls `Net.FireServer("X", …)` or `Net.InvokeServer("X", …)`, but the server registers `X` late (inside `PlayerAdded`, after a wait), never, or with another spelling | Call `Net.OnServer` / `Net.OnInvoke` (or `Net.DeclareEvent`) for `X` once at the **top level** of a Script, with the same spelling. |
| `[NetService] Net.OnClient('X') is still waiting: the server has not created remote 'X'` (then `Infinite yield possible on 'ReplicatedStorage.Events.Net:WaitForChild("X")'`) | The client listens to a server → client remote the server has not created yet (it only calls `Net.FireClient("X", …)` later, or never) | Add `Net.DeclareEvent("X")` at the **top level** of the server Script that fires `X`. |
| `Infinite yield possible on 'ReplicatedStorage.Events.Net:WaitForChild("X")'` (or on `ReplicatedStorage:WaitForChild("X")`) without the `is still waiting` line | Your code waits for a remote by hand | Never `WaitForChild` or `Instance.new` remotes. Use `Gaxia.Net.OnClient`, `Gaxia.Net.FireServer`, `Gaxia.Net.InvokeServer`. |
| `Net.OnServer is server-only` / `Net.FireServer is client-only` | A Net function is called on the wrong side | `OnServer`, `OnInvoke`, `FireClient`, `FireAllClients` in a Script; `OnClient`, `FireServer`, `InvokeServer` in a LocalScript. |
| `[NetService] 'X' is a RemoteEvent, expected RemoteFunction` | One name is used for both kinds | A different name for each: `ShopBuy` (invoke), `ShopAnnounce` (event). |
| Script Analysis: `Key 'Net' not found in table 'GaxiaServerPackage'` | Net comes from the shared package, not from GaxiaServer | Also require `Gaxia_Packages` in the Script and use `Gaxia.Net` ([04-client-server](start/04-client-server-communication.md)). |
| `Net.InvokeServer` returns nil | Over the rate limit (default 10/s, burst 20), a failed validator, or the server handler errored (red in the server's Output, ending `(error in the Net.OnInvoke('X') handler; the client got nil)`) | Handle `if ok == nil then`. Fix the red server error at the line it names. Raise `rate`/`burst` in the `Net.OnInvoke` options if honest clicks hit it. |
| `[NetService] validator 1 of remote 'X' errored (request rejected)` | A function in `validators` errors on what the client sent (for example it indexes a number) | Use `Gaxia.Guard` checks, or check `typeof` first in your own validator. |
| A server handler runs twice per request, or `[NetService] Net.OnServer('X') registered twice` / `Net.OnInvoke('X') registered twice` | The same name is registered twice (two scripts, or once per player) | Register each name once, at the top level. |

### E. Coins, shop and Robux

| Symptom | Cause | Fix |
|---|---|---|
| Coins change but the player list does not | Coins were changed with `Data.Set` | Use `Economy.Add` / `Spend` / `Set`, and sync `Economy.OnTransaction` to `GaxiaServer.Player.SetLeaderstat` ([currency-and-leaderstats](game/currency-and-leaderstats.md)). |
| `GaxiaServer.Player.SetLeaderstat` does nothing, with a yellow `[PlayerService] SetLeaderstat` warning | The value is `nil`, or of another type than the column (a string into a number column) | Pass a value of the column's type: `GaxiaServer.Player.SetLeaderstat(player, "Coins", Economy.Get(player, "Coins"))`. |
| `Economy.Add` returns false | Data not loaded yet, or the call was refused (Output shows a yellow `[Economy] Add refused: …` warning with the reason and your script line) | Wait for the data. Pass `(player, currency, amount)` in that order, with a whole amount from 1 to `Economy.MaxTransaction`; use `Economy.Spend` to take Coins. |
| `Economy.Spend(player, "Coins", 2000000)` returns false with enough Coins | Amounts above `Economy.MaxTransaction` (1,000,000) are refused (warning `amount 2000000 is above Economy.MaxTransaction`) | Keep every price and reward at or below 1,000,000, or raise the limit ([config-and-flags](game/config-and-flags.md)). |
| `Economy.Add(player, "Coins", 0.5)` returns false (warning `amount must be a whole number`) | Fractions are refused, not rounded | Whole numbers only: `math.ceil(price * 0.9)`. |
| `[Economy] Add refused: currency must be a non-empty string, got number 100 (are currency and amount swapped?)` | The arguments are in the wrong order | `Economy.Add(player, "Coins", 100)`: player, currency, then amount. |
| `[Economy] Add refused: player must be a Player, got …` | The first argument is not a Player (a name, a UserId, a character Model, or `nil`) | Pass the Player: `Players:GetPlayerFromCharacter(hit.Parent)` for touches, the `player` argument in Net handlers. Check it is not `nil` first. |
| `[Economy] Add refused: amount must be greater than 0` (also `Spend` / `Transfer`) | 0 or a negative amount | Use `Economy.Spend` to take Coins; skip the call when the amount is 0. |
| `[Economy] … refused: the saved value "Inventory" is a table, not a number: it is not a currency` | A currency name that is another saved field (`Inventory`, `Pets`, `Quests`, …) | Use `Coins`, `Gems` or a new name such as `Tokens` ([currency-and-leaderstats](game/currency-and-leaderstats.md)). |
| `[Economy] … refused: the saved balance "Coins" is nan (corrupt)` (or `inf`) | Game code saved a bad number with `Data.Set` (for example `0/0`) | Repair it once with `Economy.Set(player, "Coins", 0)` (Output then shows `[Economy] Set repaired a corrupt saved balance`). Then change balances only with `Economy`. |
| `[EConfig] ignoring override Economy.MaxTransaction = …` in Output | The override has the wrong type (a string, or `true` from `/flag set` with no value) | Set a number: `/flag set Economy.MaxTransaction 5000000`, or `/flag clear Economy.MaxTransaction`. Until then the default is used. |
| `Shop.Purchase` says `not_loaded` right after join | The buyer's data has not loaded yet (nothing was checked or taken) | Show "Your data is still loading" and let the player try again ([shop](game/shop.md)). |
| The player pays but gets nothing | The `grant` function ignores a failed `Item.Give` | `if not Item.Give(player, id, 1) then error("Give failed") end`: an error refunds the Coins ([shop](game/shop.md)). |
| Developer product bought, no reward, and Roblox keeps retrying | `RegisterProduct` was never called for that id, Monetization is not running, the data was not loaded, or the grant errored (warn `[Monetization] grant for product X failed: ...`) | Call `GaxiaServer.Monetization.RegisterProduct(id, fn)` at the top level of a Script. Fix the warned error. Never assign `MarketplaceService.ProcessReceipt` yourself. The reward arrives on the next retry ([robux-purchases](game/robux-purchases.md)). |
| A game pass bought in this server does not apply | The perk is applied only on join | Also connect `GaxiaServer.Monetization.OnGamePassPurchased` and apply the perk there ([robux-purchases](game/robux-purchases.md)). |
| A Shop item with `devProductId` returns `false, "prompted_robux"` and never runs `grant` | Robux items are granted by Monetization | Also register the product with `GaxiaServer.Monetization.RegisterProduct`. |

### F. Anti-cheat and bans

Flags look like `[AntiCheat] observe mode — would take HARD action against <Name> (<id>): <Reason>`. The **Reason** at the end tells you the cause.

| Symptom | Cause | Fix |
|---|---|---|
| Reason `StatTamper` | A script wrote a leaderstats `.Value` directly | `GaxiaServer.Player.SetLeaderstat`, and `Economy` for balances. |
| Reason `Speed` | WalkSpeed was set in a LocalScript | `GaxiaServer.Player.SetWalkSpeed(player, n)` on the server. |
| Reason `Teleport` | `HumanoidRootPart.CFrame =` or `PivotTo` moved a player | `GaxiaServer.Player.Teleport(player, cframe)` |
| Reason `Teleport`, `Speed` or `Fly` after a launch pad or knockback | Game code set the velocity | Right before you set it: `GaxiaServer.AntiCheat.Whitelist(player, "Teleport", 3)` and `GaxiaServer.AntiCheat.Whitelist(player, "Speed", 3)` (also `"Fly"` if the flag says `Fly`), as in [anticheat-and-bans](game/anticheat-and-bans.md). |
| Reason `Backpack` | A Tool was put in the Backpack with `Instance.new` or `:Clone()` | `GaxiaServer.Tool.Create` ([items-and-inventory](game/items-and-inventory.md)). |
| Reason `Combat` | Health dropped without a registered hit (lava, traps, Command Bar `Health =`) | Call `RegisterDamage` right before `humanoid:TakeDamage` ([zones-and-interactions](game/zones-and-interactions.md), Change it). |
| Reason `Heartbeat` for every player | `ReplicatedStorage/GaxiaClientFeatures` dropped the anti-cheat entry | Keep `{ Key = "AntiCheat", RequiresServer = "AntiCheat" }` in it. |
| Reason `ClientReport:GlobalPollution` | A LocalScript writes to `_G` or `shared` | Share data through a ModuleScript. |
| Reason `RemoteRate:X` / `RemoteValidation:X` | Remote `X` was called too fast / failed a validator | Keep a `busy` guard on the button; use validators only for type checks (table D). |
| Kicked: `Kicked by Gaxia_AntiCheat (reason: X)` or `[AntiCheat] X` | Enforce is on and reason X reached a hard action | Fix reason X with the rows above. |
| Warnings appear but nobody is kicked | Observe mode is the default; the place owner and admins are never kicked | Normal. To kick: [anticheat-and-bans](game/anticheat-and-bans.md) Step 4. Test with **Test → Clients and Servers**. |
| Kicked with `[Banned] <reason>` on join | That account is banned | An admin types `/acunban <userId>` in chat, or a Script calls `GaxiaServer.Ban.Unban(userId)`. |

### G. UI and client

| Symptom | Cause | Fix |
|---|---|---|
| `Toast.Show("text")` type error, or no toast | `Show` takes one table | `Toast.Show({ Title = "Shop", Text = "Bought!", Variant = "success", Duration = 4 })` |
| `[UIController] PlayerGui.Gaxia_UI is a …, not a ScreenGui`, `[HUDController] no HUD parent for 'X'`, or `NotificationService` / `MenuController` / the pet panel shows nothing | Your own object is named `Gaxia_UI` (in StarterGui or PlayerGui), or a `HUD` / `Overlays` in it is not a Folder | Rename yours. Gaxia makes `PlayerGui.Gaxia_UI` (a ScreenGui with the Folders `HUD` and `Overlays`) by itself; a ScreenGui `Gaxia_UI` you made in StarterGui is reused. |
| Your assert `state 'X' not found` | `Gaxia.State.Get` waited and gave up: the server Script that calls `State.Create("X")` is missing or crashed | Add or fix that Script; call `State.Create` at its top level. |
| A label stays `...` / `Coins: ...` | The client binds another key than the server sets, or the data is not loaded | Build the key the same way on both sides: `"Coins_" .. player.Name`. |
| Error about an invalid attribute name from `state:Set` | The key has a space, `-` or starts with `RBX` (negative Studio UserIds) | Letters, digits and `_` only: `"Coins_" .. player.Name`. |
| `state:Set(key, { ... })` errors | States hold simple values | `state:SetTable` / `state:GetTable`. |
| UI disappears after respawn | `ScreenGui.ResetOnSpawn` is true by default | `screenGui.ResetOnSpawn = false` |
| A key bound with `Gaxia.Input.Bind` does nothing or opens a Gaxia panel | F2 (admin panel), F3 (debug console) and P (pet panel) are taken | Bind another key, such as H. |

### H. Script Analysis (type errors)

| Symptom | Cause | Fix |
|---|---|---|
| Autocomplete shows nothing after `GaxiaServer.` / `Gaxia.`, or every value is `any` | `:: any` after the require, or a changed require line | Copy the require line exactly from AGENTS.md rules 1 and 2. Never add `:: any`. |
| `Key 'Economy' not found in table 'GaxiaServerPackage'` (client: `'GaxiaPackage'`) | Not installed (the loader types list only installed packages), or a misspelled name | Install the package, or copy the name from [api/INDEX.md](api/INDEX.md). Never silence it with `:: any`. |
| `Unknown global 'GaxiaServer'` (or `'Gaxia'`) | The require line is missing | Add the require line at the top of the script. |
| `Shop item needs a grant function` | A coin item without `grant` (only a `devProductId` item may leave it out) | Add `grant = function(player) ... end` ([shop](game/shop.md)). |
| An Admin handler: `Expected string?, boolean? but got string?` | Handlers return two values | `return "Done", false` on success, `return "Reason", true` on failure ([admin-and-chat-commands](game/admin-and-chat-commands.md)). |
| TypeErrors on `Promise.delay` / `:andThen`, or on `trove:Add(cancel)` | The Promise module is untyped; Trove types are strict | Use the helper patterns in [signals-cleanup-and-timing](game/signals-cleanup-and-timing.md): a typed Promise helper, `trove:Add(function() cancel() end)`. |
| Yellow warnings such as `LocalUnused` | Unused variables | Fine. Only red errors must be fixed. |

### I. Installing (Companion, Rojo)

| Symptom | Cause | Fix |
|---|---|---|
| No **Gaxia** toolbar in Studio | The Companion plugin is not installed | Build it and copy it to the Plugins Folder ([01-install-packages](start/01-install-packages.md), 2A step 1). |
| Companion status `could not trim ... types` | Studio blocked the plugin's script edits | **Plugins → Manage Plugins** → turn on **Script Injection** for Gaxia Companion → click **Install / Update** again. |
| Companion status `! Click Install again to remove ...` | The new pick would delete packages this place has | Check the list. Click **Install / Update** again only if the game does not use them. |
| `--out must be outside the Gaxia repo` / `--out must not contain the Gaxia repo` | `--out` points inside (or above) `gaxia-packages` | Use a folder next to the repo: `--out ../MyGame/gaxia`. |
| `<dir> is not empty and is not a previous build` | `build` replaces `src/` in that folder | Use an empty folder such as `../MyGame/gaxia`. Never put game files in it. |
| `unknown package(s): X` | A misspelled package name | Copy names from `node tools/packages.mjs list`: commas, no spaces. |
| Rojo game boots the wrong services after a rebuild | The game's own project still has the old `GaxiaPackages` value in `$attributes` | Copy the new value from `gaxia/default.project.json` into the game's project. |

### K. Headless runs (`tools/run-game.mjs`, `check-playbooks.mjs --run`)

These lines come from the Gaxia repo's test tools, not from Studio. Pass = the `RESULT:` line ends `→ exit 0`.

| Symptom | Cause | Fix |
|---|---|---|
| `GAME LAYOUT … none of your --game code ran` (or `none of your --game scripts ran`) | The scripts are not in service folders, or have the wrong file names | `mygame/ServerScriptService/X.server.lua` (Script), `mygame/StarterPlayer/StarterPlayerScripts/X.client.lua` (LocalScript), `mygame/ServerStorage/GameModules/X.lua` (ModuleScript). Pass `--game mygame`. |
| `GAME LAYOUT … --game points at the service folder "ServerScriptService" itself` | `--game` is one folder too deep | Pass the parent folder, which holds one folder per service. |
| `GAME LAYOUT … folder X was ignored: it is not a service name` (`did you mean …?`) | A misspelled service folder at the top of `--game` | Rename it to the exact service name it suggests. |
| `GAME LAYOUT … X.lua is a ModuleScript … and nothing required it, so it never ran` | A Script saved without `.server` / `.client` in its name | Rename it `X.server.lua` (server) or `X.client.lua` (client). |
| `HARNESS ERROR` (and `RESULT: HARNESS ERROR → exit 2`) | The test tool itself failed. Nothing was checked | Not a bug in the game. Report the first `HARNESS ERROR` line to the user. Do not change the game to hide it. |
| `SCENARIO ERROR` | Your `--scenario` file failed | Fix the scenario file, not the game. |
| `Infinite yield possible on '…:WaitForChild("X")'`, then a `HANGS` entry | A script waits for an instance that never appears (no timeout). This is a hang in Studio too | Create `X` where the script waits, fix the name, or pass a timeout: `WaitForChild("X", 10)`. For a remote: `Net.DeclareEvent("X")` on the server (table D). |
| A `HANGS` entry on `InvokeServer` or `require` | A call never returned: a server handler that waits forever, or a ModuleScript that waits at its top level | Make the handler return. Never wait at the top level of a ModuleScript. |
| `RESULT: 0 errors, 0 hangs, N warnings → exit 0` | Pass. Warnings do not fail a run | Still read each warning: most rows of this page start from a yellow line. |

### J. Other packages

Each package playbook has a **Common mistakes** table with its own symptoms: [items-and-inventory](game/items-and-inventory.md) · [progression](game/progression.md) · [live-ops](game/live-ops.md) · [zones-and-interactions](game/zones-and-interactions.md) · [effects-and-feel](game/effects-and-feel.md) · [admin-and-chat-commands](game/admin-and-chat-commands.md) · [config-and-flags](game/config-and-flags.md) · [pets](game/pets.md) · [social](game/social.md) · [multi-server](game/multi-server.md) · [webhooks-and-analytics](game/webhooks-and-analytics.md) · [signals-cleanup-and-timing](game/signals-cleanup-and-timing.md).

## Step 3 — (Only when a GaxiaServer service is nil) Run HealthCheck

Create a **Script** in **ServerScriptService** named **HealthCheck**. Replace `CHECK` with the services your scripts use:

```lua
-- Script: ServerScriptService/HealthCheck
-- TEMPORARY: prints why a service is missing. Delete this Script when the problem is fixed.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Types = require(game:GetService("ServerStorage").Gaxia_Packages_Server.Types)

-- The services your scripts use (the names you write after GaxiaServer.). Replace this sample list.
local CHECK: { Types.ServiceName } = { "Data", "Player", "Economy" }

local Lifecycle = GaxiaServer.Lifecycle

local function checkServices()
	print(`[HealthCheck] picked packages: {tostring(ServerStorage.Gaxia_Packages_Server:GetAttribute("GaxiaPackages"))}`)
	if ServerStorage:FindFirstChild("GaxiaFeatures") then
		print("[HealthCheck] ServerStorage.GaxiaFeatures exists: only the services it lists start at boot")
	end
	for _, name in CHECK do
		if not GaxiaServer.IsInstalled(name) then
			warn(`[HealthCheck] {name}: NOT INSTALLED - install the {name} package (playbooks/start/01-install-packages.md)`)
		-- Find loads the module (never starts it). The cast only tells the type checker that name is a service name.
		elseif Lifecycle.Find(name :: Types.ServiceName) == nil then
			warn(`[HealthCheck] {name}: FAILED TO LOAD - see the line "[Gaxia_Packages_Server] Failed to require '{name}'" above`)
		elseif Lifecycle.GetStateByName(name) == "failed" then
			warn(`[HealthCheck] {name}: FAILED TO START - see the line "[Lifecycle] {name}.Init failed" above`)
		elseif GaxiaServer.IsEnabled(name) then
			print(`[HealthCheck] {name}: running`)
		else
			print(`[HealthCheck] {name}: installed, starts the first time a script uses it`)
		end
	end
	print(`[HealthCheck] started services: {table.concat(Lifecycle.GetStarted(), ", ")}`)
end

-- Every Net remote the server has created so far (a missing name = "not registered by server").
local function checkRemotes()
	local events = ReplicatedStorage:FindFirstChild("Events")
	local netFolder = if events then events:FindFirstChild("Net") else nil
	local names: { string } = {}
	if netFolder then
		for _, remote in netFolder:GetChildren() do
			table.insert(names, `{remote.Name} ({remote.ClassName})`)
		end
	end
	table.sort(names)
	print(`[HealthCheck] Net remotes: {table.concat(names, ", ")}`)
	if GaxiaServer.IsInstalled("AntiCheat") then
		print(`[HealthCheck] AntiCheat kicks players: {GaxiaServer.AntiCheat.IsEnforcing()}`)
	end
end

local function checkPlayer(player: Player)
	if GaxiaServer.IsInstalled("Data") then
		local loaded = GaxiaServer.Data.WaitFor(player, 30) ~= nil
		print(`[HealthCheck] {player.Name}: data loaded = {loaded}`)
	end
end

Players.PlayerAdded:Connect(checkPlayer)
for _, player in Players:GetPlayers() do
	task.spawn(checkPlayer, player)
end

Lifecycle.OnBooted(function()
	task.wait(3) -- give your other Scripts time to register their remotes
	checkServices()
	checkRemotes()
end)

print("[HealthCheck] ready, report in 3 seconds")
```

Read its lines: `NOT INSTALLED` → install the package. `FAILED TO LOAD` / `FAILED TO START` → the line it names is a framework error: copy it to the user (Step 4). `data loaded = false` → table C.

## Step 4 — Still stuck: report, do not guess

Tell the user exactly: the first red line (full text), the script and step you were doing, and what HealthCheck printed.
Do not invent a function name, do not add `:: any`, and do not edit `Gaxia_Packages` or `Gaxia_Packages_Server`.

## Check that it works

1. Press **Play**. Output has no red lines from your scripts.
2. Every script you wrote prints its `[ScriptName] ready` line.
3. The **Check that it works** list of the playbook you followed passes.
4. Delete `HealthCheck` if you created it.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Fixing the last red line first | Fix the first one, then Play again | Later errors are often caused by the first. |
| `pcall` around the failing line to hide the error | Fix the cause from the tables | The feature still does not work, and the error is gone from Output. |
| Adding `:: any` to silence Script Analysis | Install the missing package, or use the right name from [api/INDEX.md](api/INDEX.md) | `:: any` hides real mistakes and turns off autocomplete. |
| Editing a module inside `Gaxia_Packages_Server` to "fix" it | Report the error to the user | Install / Update replaces the framework, and your change is lost. |
| Guessing a function that "should" exist | Search [api/INDEX.md](api/INDEX.md) | A name that is not there does not exist. |

## Change it

- To check client and shared packages too: use the `CheckInstallClient` LocalScript from [01-install-packages](start/01-install-packages.md) Step 3.
- To watch every anti-cheat flag as it happens: the flag log Script in [anticheat-and-bans](game/anticheat-and-bans.md).

## See also

- [AGENTS.md](../AGENTS.md) rules · [API index](api/INDEX.md) · [API reference](api/README.md)
- [Install packages](start/01-install-packages.md) · [Server script](start/02-server-script.md) · [Client script](start/03-client-script.md) · [Client ↔ server](start/04-client-server-communication.md)
- [Player data](game/player-data.md) · [Coins and leaderstats](game/currency-and-leaderstats.md) · [Robux purchases](game/robux-purchases.md) · [Anti-cheat and bans](game/anticheat-and-bans.md) · [Example simulator](game/example-simulator.md)
