# Send messages between client and server safely

> A button on the screen asks the server to do something. The server checks the request, decides, and replies.

**Use this when** the user asks for: "a button that does something on the server", "RemoteEvent", "RemoteFunction", "send data from client to server", "the server tells all players", "fire a remote" (ไทย: "ส่งข้อมูลจาก client ไป server", "กดปุ่มแล้วให้ server ทำงาน", "remote", "ยิง event", "server แจ้งทุกคน").
**Packages:** `Economy` (it also installs `Data`). `Net` is Core: it is always installed.
**You will create:** a Script `ServerScriptService/PotionStand` and a LocalScript `StarterPlayer/StarterPlayerScripts/PotionStandButton`.

How it works:

- The client never changes the game. It only **asks**: `Gaxia.Net.InvokeServer` (ask and wait for an answer) or `Gaxia.Net.FireServer` (ask, no answer).
- The server registers the handler once: `Gaxia.Net.OnInvoke` (answers) or `Gaxia.Net.OnServer` (no answer).
- The server talks to clients with `Gaxia.Net.FireClient` (one player) or `Gaxia.Net.FireAllClients` (everyone). The client listens with `Gaxia.Net.OnClient`.
- `Gaxia.Net` works on both sides. A server Script requires `Gaxia_Packages` too (Step 1 has both require lines).
- Net creates the remotes for you in `ReplicatedStorage.Events.Net`. Never create a RemoteEvent yourself.
- The client waits up to 10 seconds for a remote the server has not created yet, then errors. So the server registers every handler at the top level of a Script, when the server starts.
- Net limits each player to 10 requests per second per remote (burst 20) by default. Extra requests are dropped.

## Step 1 — Create the server handler

Create a **Script** in **ServerScriptService** named **PotionStand**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/PotionStand
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Economy"), "PotionStand needs the Economy package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy

-- The SERVER owns the prices. The client only sends a potion name and an amount.
local PRICES: { [string]: number } = {
	SpeedPotion = 25,
	JumpPotion = 40,
}
local MAX_AMOUNT = 10 -- most potions in one request
local COOLDOWN_SECONDS = 1 -- one request per second per player

local lastRequestTime: { [Player]: number } = {}

-- Runs on the server when a client calls Net.InvokeServer("PotionBuy", potionName, amount).
-- The two return values (ok, message) go back to that client.
local function onPotionBuy(player: Player, potionName: any, amount: any): (boolean, string)
	-- 1. Types: a cheater can send anything, so check every value.
	if typeof(potionName) ~= "string" or typeof(amount) ~= "number" then
		return false, "Bad request"
	end
	-- 2. Range: a whole number from 1 to MAX_AMOUNT (this also rejects NaN and infinity).
	if amount ~= math.floor(amount) or amount < 1 or amount > MAX_AMOUNT then
		return false, `Amount must be 1 to {MAX_AMOUNT}`
	end
	-- 3. It must exist: look the price up in the server's own list.
	local price = PRICES[potionName]
	if price == nil then
		return false, "Unknown potion"
	end
	-- 4. Cooldown: ignore requests that come too fast.
	local now = os.clock()
	local last = lastRequestTime[player]
	if last ~= nil and now - last < COOLDOWN_SECONDS then
		return false, "Too fast, wait a moment"
	end
	lastRequestTime[player] = now
	-- 5. Player data must be loaded before we read or change it.
	if not Data.IsLoaded(player) then
		return false, "Your data is still loading"
	end
	-- 6. Ownership: can the player pay? Spend returns false and takes nothing if not.
	local cost = price * amount
	if not Economy.Spend(player, "Coins", cost) then
		return false, `Not enough Coins (costs {cost})`
	end
	-- 7. Give the potions (saved in the player's data under "Potions").
	local potions = Data.Get(player, "Potions")
	if typeof(potions) ~= "table" then
		potions = {}
	end
	potions[potionName] = (potions[potionName] or 0) + amount
	Data.Set(player, "Potions", potions)

	print(`[PotionStand] {player.Name} bought {amount} {potionName} for {cost} Coins`)
	-- Server -> every client: tell all players about the purchase.
	Net.FireAllClients("PotionAnnounce", player.Name, amount, potionName)
	return true, `Bought {amount} {potionName}`
end

-- Register handlers at the TOP LEVEL of the script, never inside a function or after a wait.
-- { rate = 4, burst = 8 }: at most 4 requests per second per player; extra ones get nil back.
Net.OnInvoke("PotionBuy", onPotionBuy, { rate = 4, burst = 8 })

-- Create the server -> client remote now, so the client's Net.OnClient("PotionAnnounce")
-- finds it at once. Clients are not allowed to use it: this handler ignores them.
Net.OnServer("PotionAnnounce", function() end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastRequestTime[player] = nil
end)

print("[PotionStand] ready")
```

What it does: it checks type, range, existence, cooldown, loaded data and money, in that order. Only then does it change anything.

## Step 2 — Create the client button

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **PotionStandButton**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/PotionStandButton
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

local Net = Gaxia.Net
local player = Players.LocalPlayer

-- A simple button made in code.
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PotionStandGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

local BUTTON_TEXT = "Buy 2 Speed Potions"
local button = Instance.new("TextButton")
button.Name = "BuyButton"
button.Size = UDim2.fromOffset(240, 50)
button.Position = UDim2.new(0.5, -120, 1, -90)
button.TextScaled = true
button.Text = BUTTON_TEXT
button.Parent = screenGui

local busy = false
button.Activated:Connect(function()
	if busy then
		return -- wait for the answer before asking again
	end
	busy = true
	button.Text = "Buying..."
	-- Ask the server. Send only WHAT to buy, never the price.
	local ok, message = Net.InvokeServer("PotionBuy", "SpeedPotion", 2)
	if ok == nil then
		-- nil means the server dropped the request (too many requests).
		message = "No answer, try again"
	end
	print(`[PotionStandButton] answer: {tostring(ok)} {tostring(message)}`)
	button.Text = tostring(message)
	task.wait(1.5)
	button.Text = BUTTON_TEXT
	busy = false
end)

-- Listen to messages the server sends to every player.
Net.OnClient("PotionAnnounce", function(buyerName: any, amount: any, potionName: any)
	print(`[PotionStandButton] {tostring(buyerName)} bought {tostring(amount)} {tostring(potionName)}`)
end)

print("[PotionStandButton] ready")
```

What it does: it shows one button. A press asks the server and shows the answer on the button for 1.5 seconds.

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[PotionStand] ready` and `[PotionStandButton] ready`, and no red errors.
3. Wait 3 seconds, then click the button. A new player has 0 Coins, so Output shows `[PotionStandButton] answer: false Not enough Coins (costs 50)`. The server checked and said no: this is correct. (`Your data is still loading` means you clicked too early: click again.)
4. Give yourself Coins (for example with [game/currency-and-leaderstats](../game/currency-and-leaderstats.md)). Click again. Output shows these three lines (their order may differ): `[PotionStand] <YourName> bought 2 SpeedPotion for 50 Coins`, `[PotionStandButton] <YourName> bought 2 SpeedPotion` and `[PotionStandButton] answer: true Bought 2 SpeedPotion`.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `Net.FireServer("AddCoins", 100)` from the client | Client sends `"PotionBuy", "SpeedPotion", 2`; the server reads the price from `PRICES` | A cheater can send any number. The server must decide prices, amounts and rewards. |
| Server uses `amount` without checks | Check `typeof`, whole number, `1..MAX_AMOUNT` first | Cheaters send `-5`, `0.5`, `NaN` or `1e300`. |
| `Net.OnInvoke(...)` inside `Players.PlayerAdded` or after `task.wait` | Call `Net.OnInvoke` / `Net.OnServer` at the top level of a Script | The client waits 10 seconds for the remote, then errors `Remote 'PotionBuy' not registered by server`. |
| The server only calls `Net.FireClient(player, "X", ...)` later; the client calls `Net.OnClient("X", ...)` at start | Also call `Net.OnServer("X", function() end)` at the top of the server Script | Net creates a remote on first use. Without it the client's `Net.OnClient` errors after 10 seconds. |
| `local ok = Net.FireServer("PotionBuy", ...)` | `local ok, message = Net.InvokeServer("PotionBuy", ...)` | `FireServer` never returns an answer. Use `InvokeServer` with `OnInvoke`. |
| Same name in `Net.OnServer` in two scripts | One handler per name, named `<Feature><Action>` (`PotionBuy`) | Both handlers run. With `Net.OnInvoke` only the last one works. A name used as both kinds errors: `'X' is a RemoteEvent, expected RemoteFunction`. |
| `Net.OnServer` / `Net.FireClient` in a LocalScript | Server functions in a Script, client functions in a LocalScript | Net errors: `Net.OnServer is server-only`, `Net.FireServer is client-only`. |
| Client ignores a `nil` answer | `if ok == nil then ... end` | Requests over the rate limit, or that fail `validators`, return `nil`. |
| `Instance.new("RemoteEvent")` in ReplicatedStorage | `Net.OnServer` / `Net.OnInvoke` | Net adds rate limits and AntiCheat reports. Your own remotes have neither. |

## Change it

- To change the rate limit: change `{ rate = 4, burst = 8 }`. `rate` = requests per second, `burst` = how many may come at once. Dropped requests are reported to AntiCheat as soft flags.
- To reject malformed requests before your handler runs, add `validators`: one check per argument. A failed check drops the request and reports a **hard** AntiCheat flag (with `Config.AntiCheat.Enforce = true` that kicks). So check only what an honest client never sends (types), never ranges or money. With the `Guard` package (`Gaxia.IsInstalled("Guard")`, not `GaxiaServer.IsInstalled`):
  ```lua
  -- fragment
  local Guard = Gaxia.Guard
  Net.OnInvoke("PotionBuy", onPotionBuy, { rate = 4, burst = 8, validators = { Guard.string, Guard.integer } })
  ```
  `Guard.integer` rejects NaN and infinity. `Guard.numberRange` does NOT reject NaN: keep range checks in the handler.
- To send a message to one player only: `Net.FireClient(player, "PotionAnnounce", ...)`. To everyone except one: `Net.FireOtherClients(player, "PotionAnnounce", ...)`.
- For a request that needs no answer (for example "I pressed Sprint"): server `Net.OnServer("SprintPress", function(player) ... end)`, client `Net.FireServer("SprintPress")`. The same checks apply.
- Many small one-way actions that each send one table: the `Command` package (`Gaxia.Command.Register` on the server with a `Guard` schema, `Gaxia.Command.Send` on the client) uses one shared remote. It never replies, so keep `Net.OnInvoke` when the client needs an answer.

## See also

- [API: Net](../api/Core.NetService.md) · [API: Guard](../api/Guard.md) · [API: Command](../api/Command.md)
- [Coins and leaderstats](../game/currency-and-leaderstats.md) · [Player data](../game/player-data.md) · [Shop](../game/shop.md)
- [Anti-cheat and bans](../game/anticheat-and-bans.md) · [Troubleshooting](../troubleshooting.md)
