# AGENTS.md — working with Gaxia Packages

Gaxia Packages is a Roblox (Luau) game framework: save data, currencies, shops,
Robux purchases, quests, UI, admin commands, anti-cheat and ~100 other packages.
This file is for AI coding agents. Read it all before you write code. (Humans: see MANUAL.md.)

## 1. Which job do you have?

- **A. Build a game feature that uses Gaxia** (almost every task) → follow the rules below, then the playbook for the task (section 3).
- **B. Change the Gaxia framework itself** (files under `src/` of the Gaxia repo) → read [playbooks/framework/change-the-framework.md](playbooks/framework/change-the-framework.md) first.

If you are not sure, it is **A**. Game code never goes inside `Gaxia_Packages` or `Gaxia_Packages_Server`.

## 2. Rules (follow every one, every time)

1. **Server code** gets services from `GaxiaServer`. Put it in a **Script** in `ServerScriptService` (or a ModuleScript in `ServerStorage`):
   ```lua
   -- fragment
   local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
   ```
2. **Client code** gets modules from `Gaxia`. Put it in a **LocalScript** in `StarterPlayer/StarterPlayerScripts`:
   ```lua
   -- fragment
   local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
   ```
   The client can never require `Gaxia_Packages_Server` (it errors). Client modules (`Gaxia.UI`, `Gaxia.Camera`, …) are nil on the server.
   **Server Scripts require `Gaxia` too** when they need a shared module: `Gaxia.Net` (remotes), `Gaxia.Signal`, `Gaxia.Trove`, `Gaxia.State`, `Gaxia.Flags`. Both lines in one server Script is normal.
3. **Copy the require lines exactly.** Never add `:: any` (it turns off type checking and autocomplete). Never write `.init` after the package name.
4. **Only use names that exist.** Every function and signal is listed in [playbooks/api/INDEX.md](playbooks/api/INDEX.md); types (such as `Features.ClientEntry`) and default values are on the package's page, `playbooks/api/<Package>.md`. If a name is in neither, it does not exist — never guess one.
5. **Check the package is installed** before you use it: `GaxiaServer.IsInstalled("Economy")`. A package that is not installed is `nil`. If one is missing, tell the user which package to install ([playbooks/start/01-install-packages.md](playbooks/start/01-install-packages.md)). Do not rebuild it yourself.
6. **Never edit the framework inside a game place.** Do not change modules in `Gaxia_Packages` / `Gaxia_Packages_Server` (Install / Update replaces them). Settings: [playbooks/game/config-and-flags.md](playbooks/game/config-and-flags.md).
7. **The server decides.** The client only asks (through `Net` remotes). The server checks every request and never trusts a price, amount or item sent by the client ([playbooks/start/04-client-server-communication.md](playbooks/start/04-client-server-communication.md)).
8. **Player data goes through `GaxiaServer.Data`**, never `DataStoreService` directly. Data loads a moment after the player joins: wait for it ([playbooks/game/player-data.md](playbooks/game/player-data.md)).
9. **Robux:** selling developer products needs the `Monetization` package. Never assign `MarketplaceService.ProcessReceipt` yourself ([playbooks/game/robux-purchases.md](playbooks/game/robux-purchases.md)).
10. **Moving players:** teleport them with `GaxiaServer.Player.Teleport(player, cframe)` so the anti-cheat does not flag it.
11. **Clean up:** connections and instances you create per player go in a `Trove` and are cleaned when the player leaves ([playbooks/game/signals-cleanup-and-timing.md](playbooks/game/signals-cleanup-and-timing.md)).
12. **Write complete scripts.** Follow the playbook's steps in order, paste whole blocks, then do its "Check that it works" list. Do not say "done" until the checks pass. If you cannot run Roblox Studio yourself, say exactly which checks you ran (for example a type check) and list the playbook's Studio checks for the user to do.

### Where code goes (Studio name ↔ file name)

| In Studio (Explorer) | As a Rojo file |
|---|---|
| **Script** `ServerScriptService` → `CoinShop` | `ServerScriptService/CoinShop.server.lua` |
| **LocalScript** `StarterPlayer` → `StarterPlayerScripts` → `ShopUI` | `StarterPlayer/StarterPlayerScripts/ShopUI.client.lua` |
| **ModuleScript** `ServerStorage` → `GameModules` (Folder) → `Catalog` | `ServerStorage/GameModules/Catalog.lua` |
| **ModuleScript** `ReplicatedStorage` → `GameShared` (Folder) → `ItemNames` | `ReplicatedStorage/GameShared/ItemNames.lua` |

Playbook code blocks start with this location, for example `-- Script: ServerScriptService/CoinShop`.

## 3. Find the playbook for your task

Start with the playbook, not the API pages. Each one is a numbered recipe with complete code.

| The user wants… (EN / ไทย) | Read |
|---|---|
| set up Gaxia, pick packages / ติดตั้ง, เลือก package | [start/01-install-packages](playbooks/start/01-install-packages.md) |
| a first server script, run code when a player joins / สคริปต์ฝั่ง server | [start/02-server-script](playbooks/start/02-server-script.md) |
| a first client script, UI code / สคริปต์ฝั่ง client | [start/03-client-script](playbooks/start/03-client-script.md) |
| client ↔ server messages, buttons that do things on the server / remote | [start/04-client-server-communication](playbooks/start/04-client-server-communication.md) |
| save progress, custom saved fields / เซฟข้อมูลผู้เล่น | [game/player-data](playbooks/game/player-data.md) |
| coins, gems, money on the leaderboard / เงิน, เหรียญ, leaderstats | [game/currency-and-leaderstats](playbooks/game/currency-and-leaderstats.md) |
| items, inventory, giving a Tool (sword, gear), trading / ไอเทม, กระเป๋า, ให้ดาบ / tool, เทรด | [game/items-and-inventory](playbooks/game/items-and-inventory.md) |
| a shop that sells for coins / ร้านค้า | [game/shop](playbooks/game/shop.md) |
| game passes, developer products, Robux / ขายของด้วย Robux | [game/robux-purchases](playbooks/game/robux-purchases.md) |
| XP, levels, quests, achievements / เลเวล, เควส, ความสำเร็จ | [game/progression](playbooks/game/progression.md) |
| daily rewards, timed events, mail, global leaderboards / รางวัลรายวัน, อีเวนต์ | [game/live-ops](playbooks/game/live-ops.md) |
| show live values on the screen (coins, timer) / แสดงค่าบนจอ | [game/show-values-on-screen](playbooks/game/show-values-on-screen.md) |
| notifications, menus, buttons, UI kit, a settings menu for players / แจ้งเตือน, เมนู, UI, หน้าตั้งค่า | [game/ui](playbooks/game/ui.md) |
| areas that react when players enter, "press E" prompts / โซน, ปุ่มกด E | [game/zones-and-interactions](playbooks/game/zones-and-interactions.md) |
| NPC dialog with choices, talk to an NPC, cutscene, camera tour / คุยกับ NPC, บทสนทนา, คัตซีน | [game/npc-dialog-and-cutscenes](playbooks/game/npc-dialog-and-cutscenes.md) |
| admin commands, chat commands, roles / คำสั่งแอดมิน | [game/admin-and-chat-commands](playbooks/game/admin-and-chat-commands.md) |
| anti-cheat, bans / กันโกง, แบน | [game/anticheat-and-bans](playbooks/game/anticheat-and-bans.md) |
| game tuning values, limits, feature flags (developer settings) / ปรับค่าเกม, flag | [game/config-and-flags](playbooks/game/config-and-flags.md) |
| pets / สัตว์เลี้ยง | [game/pets](playbooks/game/pets.md) |
| friends, guilds, parties / เพื่อน, กิลด์, ปาร์ตี้ | [game/social](playbooks/game/social.md) |
| effects, sounds, music, camera shake, tweens, animations, ragdoll, moving/spinning parts / เอฟเฟกต์, เสียง, ท่า, แพลตฟอร์มเลื่อน | [game/effects-and-feel](playbooks/game/effects-and-feel.md) |
| events between scripts, cleanup, timers, promises / signal, cleanup | [game/signals-cleanup-and-timing](playbooks/game/signals-cleanup-and-timing.md) |
| teleport between places, messages between servers / ข้ามเซิร์ฟเวอร์ | [game/multi-server](playbooks/game/multi-server.md) |
| Discord webhooks, analytics / webhook, analytics | [game/webhooks-and-analytics](playbooks/game/webhooks-and-analytics.md) |
| an obby, checkpoints, kill bricks/lava, skip stage / ออบบี้, เช็คพอยต์, ลาวา, ข้ามด่าน | [game/obby-checkpoints](playbooks/game/obby-checkpoints.md) |
| sword combat, enemy NPCs/mobs that chase and attack, kill rewards / ระบบต่อสู้, ดาบ, มอนสเตอร์, ซอมบี้ | [game/combat-and-npcs](playbooks/game/combat-and-npcs.md) |
| round-based games, intermission, teams, lobby → map → winner / รอบเกม, ทีม | [game/rounds-and-teams](playbooks/game/rounds-and-teams.md) |
| a tycoon: plots, droppers, buy buttons / ไทคูน, ดรอปเปอร์, ปุ่มซื้อ | [game/tycoon](playbooks/game/tycoon.md) |
| rebirth, multipliers, upgrades, auto-click, boosts for simulators / รีเบิร์ธ, ตัวคูณ, อัปเกรด | [game/simulator-extras](playbooks/game/simulator-extras.md) |
| translate the game, Thai language, language setting / แปลเกม, ภาษาไทย, เปลี่ยนภาษา | [game/translation](playbooks/game/translation.md) |
| a whole small game from scratch / ทำเกมทั้งเกม | [game/example-simulator](playbooks/game/example-simulator.md) |
| add a service to the framework | [framework/add-a-service](playbooks/framework/add-a-service.md) |
| change the framework, run its checks | [framework/change-the-framework](playbooks/framework/change-the-framework.md) |
| add a built-in anti-cheat detector | [framework/add-an-anticheat-detector](playbooks/framework/add-an-anticheat-detector.md) |
| something errors or does nothing / error, ไม่ทำงาน | [troubleshooting](playbooks/troubleshooting.md) |

No row fits? Read [playbooks/api/README.md](playbooks/api/README.md) to find the package, then its API page.

## 4. Look up an exact name

- [playbooks/api/INDEX.md](playbooks/api/INDEX.md): every function and signal, one per line (`GaxiaServer.Economy.Spend(player: Player, currency: string, amount: number): boolean`). Search it.
- `playbooks/api/<Package>.md`: how to get the module, every function with its parameter types, signals with their payload types, types and default values.
- Core (always installed) pages are `playbooks/api/Core.<Name>.md`: `Core.Loaders` (`GaxiaServer.IsInstalled`, `Boot`, …), `Core.NetService` (`Gaxia.Net`), `Core.Signal`, `Core.Trove`, `Core.ReplicatedState` (`Gaxia.State`), `Core.Flags`, `Core.EffectiveConfig` (`GaxiaServer.EConfig`), `Core.Config`.
- These pages are generated from the source, so they are always right. When a playbook and an API page disagree, the API page wins.

## 5. Check your work

- **In Roblox Studio:** open *View → Script Analysis* (no red errors in your scripts), press **Play**, read *Output* for red errors, then do the playbook's "Check that it works" list.
- **Features with more than one player** (chat commands, trades, parties, anything that gives to another player) also need **Test → Clients and Servers → 2 players**. Some bugs only show then.
- **In a Rojo project with luau-lsp:** `luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json --definitions=@roblox=globalTypes.d.luau <your files>` must print no `TypeError`.
- **Run it headlessly** (no Studio; needs a checkout of the Gaxia repo — https://github.com/Gaxia-XP/gaxia-packages — plus Node and `lune`): put your scripts in a folder that mirrors the Explorer (`mygame/ServerScriptService/CoinShop.server.lua`, `mygame/StarterPlayer/StarterPlayerScripts/ShopUI.client.lua`). From the Gaxia repo, run `node tools/run-game.mjs --packages <your pick, from INSTALLED.md> --game /full/path/to/mygame` (or `--build /full/path/to/your/installed/project` if your scripts are mapped in its `default.project.json`). It plays the server and one player for 10 s and lists red errors (script, line and file), warnings and hangs. **Pass = exit code `0`** (the last RESULT line ends `→ exit 0`); `GAME LAYOUT` means some of your scripts never ran (wrong folder or file name). It has no physics, so still do the Studio checks. More: [tools/harness/README.md](https://github.com/Gaxia-XP/gaxia-packages/blob/master/tools/harness/README.md).
- **In the Gaxia repo** (job B): see [playbooks/framework/change-the-framework.md](playbooks/framework/change-the-framework.md).

## 6. When you are stuck

1. Look the symptom up in [playbooks/troubleshooting.md](playbooks/troubleshooting.md).
2. Read the API page of the package, then its source file (the page links it).
3. Still stuck: tell the user exactly what is missing or failing (the error text, the package, the step). Do not invent an API or a workaround that edits the framework.
