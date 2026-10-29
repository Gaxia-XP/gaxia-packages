# Add coins (or any currency) and show it on the leaderboard

> Players earn saved Coins, and the player list (top right) always shows their current Coins.

**Use this when** the user asks for: "coins", "money", "gems", "currency", "leaderstats", "show coins on the leaderboard", "give coins every few seconds" (ไทย: "เงิน", "เหรียญ", "เพชร", "ระบบเงิน", "โชว์เงินบน leaderboard", "leaderstats", "ให้เงินทุกกี่วินาที").
**Packages:** `Economy` (it also installs `Data`) and `Player`. The scripts below stop with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/CoinLeaderstats` and `ServerScriptService/CoinPayout`.

How it works:

- `GaxiaServer.Economy` keeps balances in the player's saved data. A currency is any name: `Coins` and `Gems` exist from the start, and a new name (for example `Tokens`) starts at 0 and is saved too.
- Change balances only with `Economy.Add`, `Economy.Spend`, `Economy.Set` or `Economy.Transfer`. Each one returns `true` if it worked and fires `Economy.OnTransaction`.
- The leaderboard is a `leaderstats` folder. Create it with `GaxiaServer.Player.SetupLeaderstats` and update it with `GaxiaServer.Player.SetLeaderstat`, never by writing `.Value` yourself.

## Step 1 — Show Coins in the player list

Create a **Script** in **ServerScriptService** named **CoinLeaderstats**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/CoinLeaderstats
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Economy"), "CoinLeaderstats needs the Economy package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Player"), "CoinLeaderstats needs the Player package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local PlayerService = GaxiaServer.Player -- the Gaxia "Player" package (Players above is Roblox's service)

-- The currencies shown in the player list, left to right.
local SHOWN_CURRENCIES = { "Coins" }

-- Every Add / Spend / Set / Transfer fires OnTransaction: copy the new balance to the leaderboard.
Economy.OnTransaction:Connect(function(player: Player, currency: string, _delta: number, newBalance: number)
	if table.find(SHOWN_CURRENCIES, currency) then
		PlayerService.SetLeaderstat(player, currency, newBalance)
	end
end)

local function onPlayerAdded(player: Player)
	-- Balances are in the saved data: wait until it is loaded (nil = the player left).
	-- 120 seconds: a slow load still gets its leaderboard columns.
	if Data.WaitFor(player, 120) == nil then
		return
	end
	-- One column per currency, with the saved balance as the starting value.
	for _, currency in SHOWN_CURRENCIES do
		PlayerService.SetupLeaderstats(player, { [currency] = Economy.Get(player, currency) })
	end
	print(`[CoinLeaderstats] {player.Name} has {Economy.Get(player, "Coins")} Coins`)
end

-- Players who join later, and players who are already in the game.
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[CoinLeaderstats] ready")
```

What it does: it builds the leaderboard from the saved balance, then updates it after every transaction.
This also covers Coins given by other packages (Shop, Quest, Idle, Trade…): they all go through Economy.

## Step 2 — Give 10 Coins every 10 seconds

Create a **Script** in **ServerScriptService** named **CoinPayout**:

```lua
-- Script: ServerScriptService/CoinPayout
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Economy"), "CoinPayout needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Economy = GaxiaServer.Economy

local COINS_PER_PAYOUT = 10
local PAYOUT_SECONDS = 10

print("[CoinPayout] ready")

-- This loop never ends, so it is the last thing in the script.
while true do
	task.wait(PAYOUT_SECONDS)
	for _, player in Players:GetPlayers() do
		-- Add returns false (and gives nothing) while the player's data is still loading.
		if Economy.Add(player, "Coins", COINS_PER_PAYOUT) then
			print(`[CoinPayout] {player.Name} +{COINS_PER_PAYOUT} Coins, now {Economy.Get(player, "Coins")}`)
		end
	end
end
```

What it does: every 10 seconds each loaded player gets 10 Coins. Step 1 updates the leaderboard by itself.

## Step 3 — Spend Coins safely

Whenever the server takes Coins, use the answer of `Economy.Spend`:

```lua
-- fragment
if not Economy.Spend(player, "Coins", 50) then
	return -- not enough Coins (or data not loaded): Spend took nothing, so give nothing
end
-- paid: give the item here
```

`Spend` takes nothing and returns `false` when the balance is too low. A full button-to-server purchase is in [04-client-server-communication](../start/04-client-server-communication.md); a full shop is in [shop](shop.md).

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[CoinLeaderstats] ready` and `[CoinPayout] ready`, and no red errors.
3. Within a few seconds Output shows `[CoinLeaderstats] <YourName> has 0 Coins`. The player list (top right) has a **Coins** column showing 0.
4. After 10 seconds Output shows `[CoinPayout] <YourName> +10 Coins, now 10`, and the **Coins** column shows 10.
5. With **Enable Studio Access to API Services** on (see [player-data](player-data.md)), stop and press **Play** again: the Coins are still there.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `player.leaderstats.Coins.Value += 10` | `Economy.Add(player, "Coins", 10)` | The saved balance does not change. With the AntiCheat package, Output shows `[AntiCheat] observe mode — would take HARD action against <Name> (...): StatTamper`. Once the game turns on enforcing (`GaxiaServer.EConfig.Set("AntiCheat.Enforce", true)`), non-admin players are kicked (the place owner never is, so you see no kick when you test). |
| Making your own `leaderstats` folder and IntValues | `GaxiaServer.Player.SetupLeaderstats` and `GaxiaServer.Player.SetLeaderstat` | Only these mark the change as allowed for AntiCheat. |
| `Data.Set(player, "Coins", 100)` | `Economy.Add` / `Economy.Set` | `Data.Set` does not fire `OnTransaction`, so the leaderboard stays old. |
| Client sends `Net.FireServer("AddCoins", 10)` | The server decides every amount | A cheater can send any number. See [04-client-server-communication](../start/04-client-server-communication.md). |
| `Economy.Spend(player, "Coins", price)` and give the item anyway | `if Economy.Spend(...) then` give the item `end` | Without the check, players with no Coins get items for free. |
| `Economy.Add(player, "Coins", 10)` in `PlayerAdded` right away | Wait with `Data.WaitFor(player, 120)` first | Before data loads, `Add` returns `false` and gives nothing. |
| `Economy.Add` / `Economy.Spend` with `0.5` or `price * 0.9` | Whole numbers above 0 only: `math.ceil(price * 0.9)` | Any other amount (a fraction, NaN, `math.huge`) is refused: the call returns `false`, changes nothing, and Output shows a yellow `[Economy] Add refused: …` warning naming your script and line. |
| `Economy.Add(player, "Coins", -10)` to take Coins | `Economy.Spend(player, "Coins", 10)` | `Add` with 0 or a negative amount returns `false`, changes nothing and warns. |
| `Economy.Add(player, 100, "Coins")` | `Economy.Add(player, "Coins", 100)`: player, currency, then amount | Swapped arguments return `false` and warn `currency must be a non-empty string, got number 100 (are currency and amount swapped?)`. |
| A price or reward above 1,000,000 | Keep each amount at or below `Economy.MaxTransaction`, or raise it: `GaxiaServer.EConfig.Set("Economy.MaxTransaction", 5000000)` ([config-and-flags](config-and-flags.md)) | Bigger amounts are refused, not cut: `Spend(player, "Coins", 2000000)` returns `false`, takes nothing and warns `amount 2000000 is above Economy.MaxTransaction (1000000)`. `Economy.GetMaxTransaction()` returns the current limit. |
| A currency named like any saved field (`Level`, `Inventory`, `Pets`, `Quests`, your own `Wins` …) | `Coins`, `Gems` or a new name like `Tokens` | A field that holds a number (`Level`, `Wins`) is changed as if it were money. A field that holds something else (`Inventory`, `Pets`, `Quests`) is refused with a warning (`the saved value "Inventory" is a table, not a number`). Full list of taken names: [player-data](player-data.md). |
| `GaxiaServer.Player.SetLeaderstat` before `GaxiaServer.Player.SetupLeaderstats` | Set up first (Step 1 does it on load) | `SetLeaderstat` creates a missing column, but the column order follows the order they were made, and before data loads it shows a wrong value. |

## Change it

- To show Gems too: change `{ "Coins" }` to `{ "Coins", "Gems" }`. Any new name works the same way.
- To reward on touch, a timer or a quest instead: call `Economy.Add(player, "Coins", amount)` from that server code. Step 1 keeps the leaderboard right.
- To set an exact balance (admin, reset): `Economy.Set(player, "Coins", 0)`. It skips the per-call limit; the amount must be a whole number from 0 to `MaxBalance` (anything else is refused with a warning).
- To send Coins from one player to another: `Economy.Transfer(fromPlayer, toPlayer, "Coins", 100)`. It returns `false` and changes nothing if the sender cannot pay.
- To log every change: `Economy.OnTransaction:Connect(function(player, currency, delta, newBalance, kind) ... end)`. `kind` is `"add"`, `"spend"`, `"set"` or `"transfer"`. A transfer fires `"spend"`/`"add"` first, then `"transfer"` for each player.
- Limits: `Economy.MaxTransaction` (1,000,000 per call: a bigger `Add` / `Spend` / `Transfer` is refused, read it with `Economy.GetMaxTransaction()`) and `Economy.MaxBalance` (1,000,000,000; `Add` stops there, `Economy.GetMaxBalance()`). Change them at server start with `GaxiaServer.EConfig.Set("Economy.MaxTransaction", 5000000)`: see [config-and-flags](config-and-flags.md).
- To show Coins in your own screen UI: [show-values-on-screen](show-values-on-screen.md).

## See also

- [API: Economy](../api/Economy.md) · [API: Player](../api/Player.md) · [API: Data](../api/Data.md)
- [Player data](player-data.md) · [Shop](shop.md) · [Robux purchases](robux-purchases.md) · [Anti-cheat and bans](anticheat-and-bans.md)
