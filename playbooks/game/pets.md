# Pets: hatch from an egg, equip, and boost Coins

> Players buy an egg for 100 Coins (in the pet panel or at an egg in the world), get a random pet, equip up to 3 pets, and every equipped pet makes them earn more Coins. New players get a free Cat.

**Use this when** the user asks for: "pets", "eggs", "hatch an egg", "pet simulator", "equip pets", "pet boost", "pet multiplier", "pet inventory" (ไทย: "สัตว์เลี้ยง", "เพ็ท", "ไข่", "เปิดไข่", "ฟักไข่", "สุ่มเพ็ท", "ใส่เพ็ท", "เพ็ทเพิ่มเงิน", "ตัวคูณเงิน").
**Packages:** `Pet` (it also installs `Economy`, `Data`, `Loot`, `ItemDef`, `Codex` and the pet panel) and `Interaction` for the egg in Step 4. The scripts below stop with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/PetSetup`, `ServerScriptService/PetCoins`, `ServerScriptService/EggStand` and the LocalScript `StarterPlayer/StarterPlayerScripts/PetPanel`.

How it works:

- The Pet package has **one egg**, `BasicEgg`, and **8 pets**. You cannot add your own pets or eggs from game code. Do not edit `PetService` (Update replaces it).
- Pets are **stats only**: no 3D pet follows the player.
- The pet panel is built in. Press **P** to open it (after Step 2). It shows the pets, the Coin multiplier and a **Buy Egg** button. Clicking a pet equips or unequips it. The server checks every click.
- Multiplier = 1 + the bonus of every equipped pet. One Cat equipped → x1.05.
- The Pet package never gives Coins. **Quest** rewards in Coins and **Idle** payouts in Coins use the multiplier by themselves. Your own Coin rewards must multiply by `Pet.GetCoinMultiplier(player)` (Step 3).
- Owned and equipped pets are saved in the player's data.

| Pet id | Name | Rarity | Coin bonus | Chance per egg |
|---|---|---|---|---|
| `pet_Cat` | Cat | common | +0.05 | 39.6% |
| `pet_Dog` | Dog | common | +0.05 | 29.7% |
| `pet_Bunny` | Bunny | uncommon | +0.10 | 11.9% |
| `pet_Fox` | Fox | uncommon | +0.12 | 9.9% |
| `pet_Panda` | Panda | rare | +0.20 | 4.0% |
| `pet_Penguin` | Penguin | rare | +0.25 | 3.0% |
| `pet_Tiger` | Tiger | epic | +0.40 | 1.5% |
| `pet_Dragon` | Dragon | legendary | +1.00 | 0.5% (sure within 50 eggs) |

## Step 1 — Set the egg price and give new players a Cat

Create a **Script** in **ServerScriptService** named **PetSetup**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/PetSetup
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Pet"), "PetSetup needs the Pet package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data
local Pet = GaxiaServer.Pet
local EConfig = GaxiaServer.EConfig

-- Coins per egg, and how many pets can be equipped at once. Runs when every server starts.
EConfig.Set("Pets.EggCost", 100)
EConfig.Set("Pets.MaxEquipSlots", 3)

-- One Output line for every new pet and every equip change.
Pet.OnPetGranted:Connect(function(player: Player, petId: string, uid: string)
	print(`[PetSetup] {player.Name} got {petId} ({uid})`)
end)
Pet.OnEquipChanged:Connect(function(player: Player, equipped: { string })
	print(`[PetSetup] {player.Name} has {#equipped} pet(s) equipped, Coins x{Pet.GetCoinMultiplier(player)}`)
end)

local function onPlayerAdded(player: Player)
	-- Pets are in the saved data: wait until it is loaded (nil = the player left).
	if Data.WaitFor(player) == nil then
		return
	end
	-- A brand-new player owns no pets: give a Cat and equip it.
	if #Pet.GetOwned(player) == 0 then
		local uid = Pet.GrantPet(player, "pet_Cat")
		if uid then
			Pet.Equip(player, uid)
		end
	end
	print(`[PetSetup] {player.Name} owns {#Pet.GetOwned(player)} pet(s), Coins x{Pet.GetCoinMultiplier(player)}`)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[PetSetup] ready")
```

What it does: a new player gets a Cat, equipped, so their multiplier is 1.05. Returning players keep their pets.

## Step 2 — Make the pet panel show, and add a Pets button

The panel draws into a ScreenGui named `Gaxia_UI` with a folder `Overlays`. Gaxia does not create it: this script does.
Phones have no **P** key, so it also adds a **Pets** button.

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **PetPanel**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/PetPanel
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(Gaxia.IsInstalled("UI.PetController"), "PetPanel needs the Pet package: install it (playbooks/start/01-install-packages.md)")

local PetController = Gaxia.UI.PetController
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

-- 1. The ScreenGui the pet panel draws into: PlayerGui.Gaxia_UI with a folder Overlays.
local function makeUiRoot(): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = "Gaxia_UI"
	screen.ResetOnSpawn = false -- keep it after the player dies
	screen.Parent = playerGui
	return screen
end
local function makeOverlays(parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = "Overlays"
	folder.Parent = parent
	return folder
end
local uiRoot = playerGui:FindFirstChild("Gaxia_UI") or makeUiRoot()
local overlays = uiRoot:FindFirstChild("Overlays") or makeOverlays(uiRoot)

-- Put every panel opened in Overlays in the middle of the screen.
overlays.ChildAdded:Connect(function(child: Instance)
	if child:IsA("GuiObject") then
		child.AnchorPoint = Vector2.new(0.5, 0.5)
		child.Position = UDim2.fromScale(0.5, 0.5)
	end
end)

-- 2. A Pets button on the left of the screen.
local buttonGui = Instance.new("ScreenGui")
buttonGui.Name = "PetButton"
buttonGui.ResetOnSpawn = false
buttonGui.Parent = playerGui

local button = Instance.new("TextButton")
button.Name = "Pets"
button.Size = UDim2.fromOffset(110, 44)
button.AnchorPoint = Vector2.new(0, 0.5)
button.Position = UDim2.new(0, 12, 0.5, 0)
button.Text = "Pets"
button.TextSize = 20
button.Font = Enum.Font.GothamBold
button.TextColor3 = Color3.fromRGB(255, 255, 255)
button.BackgroundColor3 = Color3.fromRGB(70, 140, 245)
button.Parent = buttonGui

button.Activated:Connect(function()
	PetController.Toggle()
end)

print("[PetPanel] ready")
```

What it does: **P** and the blue **Pets** button now open the pet panel in the middle of the screen.

## Step 3 — Give Coins boosted by the pets

Create a **Script** in **ServerScriptService** named **PetCoins**:

```lua
-- Script: ServerScriptService/PetCoins
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Pet"), "PetCoins needs the Pet package: install it (playbooks/start/01-install-packages.md)")

local Economy = GaxiaServer.Economy
local Pet = GaxiaServer.Pet

local BASE_COINS = 20
local PAYOUT_SECONDS = 10

print("[PetCoins] ready")

-- This loop never ends, so it is the last thing in the script.
while true do
	task.wait(PAYOUT_SECONDS)
	for _, player in Players:GetPlayers() do
		-- Multiply first, then round down: Economy only adds whole numbers.
		local amount = math.floor(BASE_COINS * Pet.GetCoinMultiplier(player))
		-- Add returns false (and gives nothing) while the player's data is still loading.
		if Economy.Add(player, "Coins", amount) then
			print(`[PetCoins] {player.Name} +{amount} Coins, now {Economy.Get(player, "Coins")}`)
		end
	end
end
```

What it does: every 10 seconds each player gets 20 Coins times their multiplier. With the Cat: 21 Coins.

## Step 4 — Put an egg in the world

Create a **Script** in **ServerScriptService** named **EggStand**:

```lua
-- Script: ServerScriptService/EggStand
local Workspace = game:GetService("Workspace")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

assert(GaxiaServer.IsInstalled("Pet"), "EggStand needs the Pet package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Interaction"), "EggStand needs the Interaction package: install it (playbooks/start/01-install-packages.md)")

local Net = Gaxia.Net
local Data = GaxiaServer.Data
local Pet = GaxiaServer.Pet
local Interaction = GaxiaServer.Interaction

local egg = Instance.new("Part")
egg.Name = "BasicEgg"
egg.Shape = Enum.PartType.Ball
egg.Size = Vector3.new(4, 5, 4)
egg.Position = Vector3.new(0, 2.5, -20)
egg.Anchored = true
egg.Color = Color3.fromRGB(245, 235, 200)
egg.Parent = Workspace

local function onEggUsed(player: Player)
	if not Data.IsLoaded(player) then
		return
	end
	-- BuyEgg takes the Coins, rolls a pet and saves it. It takes nothing when it fails.
	local ok, result = Pet.BuyEgg(player, "BasicEgg")
	print(`[EggStand] {player.Name}: {if ok then "hatched " .. result else "failed: " .. result}`)
	-- The pet panel's own messages: a "You got ..." or "Hatch Failed" toast, and a refresh.
	Net.FireClient(player, "PetHatch", { ok = ok, petId = if ok then result else nil, reason = if ok then nil else result })
	Net.FireClient(player, "PetSync", Pet.Snapshot(player))
end

local handle = Interaction.Register(egg, {
	ActionText = "Hatch (100 Coins)",
	ObjectText = "Egg",
	HoldDuration = 0.5,
	MaxDistance = 10,
	OnTrigger = onEggUsed,
})
assert(handle, "EggStand: could not put a prompt on the egg")

print("[EggStand] ready")
```

What it does: holding **E** at the white egg buys one egg. The player sees the same toast as the panel's **Buy Egg** button.

## Check that it works

1. Press **Play** in Studio.
2. Output shows `[PetSetup] ready`, `[PetPanel] ready`, `[PetCoins] ready`, `[EggStand] ready`, and no red errors.
3. Output shows `[PetSetup] <YourName> got pet_Cat (u_1)`, then `[PetSetup] <YourName> owns 1 pet(s), Coins x1.05` (only the first time; later it shows the saved pets).
4. After 10 seconds Output shows `[PetCoins] <YourName> +21 Coins, now 21`.
5. Press **P** (or click **Pets**). The panel shows `Coin Multiplier: x1.05`, `Equipped 1/3` and the Cat with `✓ Equipped`.
6. Wait until a `[PetCoins]` line says `now 100` or more (about 50 seconds the first time): enough for one egg.
7. Open the panel and click **Buy Egg (100 Coins)**. A toast says `Egg Hatched! You got <Pet>!` and Output shows `[PetSetup] <YourName> got pet_<Name> (u_2)`. Click the new pet: Output shows `[PetSetup] <YourName> has 2 pet(s) equipped, Coins x...`.
8. Walk to the white egg and hold **E**. Output shows `[EggStand] <YourName>: failed: not enough Coins` (you spent them in 7), or `hatched pet_<Name>` once you have 100 Coins again.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| Skipping Step 2 | Keep the `PetPanel` LocalScript | Without `PlayerGui.Gaxia_UI` and its `Overlays` folder, **P** shows nothing (the panel waits 5 seconds, then is never shown). |
| A new pet in your own table, or `Pet.GrantPet(player, "pet_Unicorn")` | Only the 8 ids in the table above | An unknown id warns `GrantPet: unknown petId` and returns `nil`. |
| `Pet.BuyEgg(player, "GoldenEgg")` | `Pet.BuyEgg(player, "BasicEgg")` | There is one egg. Another name returns `false, "unknown egg"`. |
| `Economy.Add(player, "Coins", 20)` and expecting pets to help | `math.floor(20 * Pet.GetCoinMultiplier(player))` | Pets only boost Quest and Idle Coins by themselves. Your rewards must multiply. |
| Expecting the multiplier to boost Gems | Only `Coins` | Quest and Idle boost only the currency named `Coins`. |
| Granting or equipping before `Data.WaitFor(player)` | Wait for the data first (Step 1) | Before the data loads, nothing is saved and the multiplier is 1. |
| Calling `Pet.BuyEgg` from server code without the two `Net.FireClient` lines | Send `PetHatch` and `PetSync` like Step 4 | Only the panel's own button refreshes the panel. Otherwise an open panel shows old pets. |
| Firing `PetBuyEgg` / `PetEquip` from your own LocalScript | Use the panel, or call `Pet.BuyEgg` / `Pet.Equip` on the server | The panel already does this, and the server checks Coins and ownership. |
| A `GaxiaClientFeatures` module without `UI.PetController` | Keep `{ Key = "UI.PetController", RequiresServer = "Pet" }` in it | Without it the **P** key does nothing until a script uses `Gaxia.UI.PetController`. |
| Equipping a 4th pet | Unequip one first, or raise `Pets.MaxEquipSlots` | `Pet.Equip` returns `false, "all slots full"`. |

## Change it

- Egg price: change `EConfig.Set("Pets.EggCost", 100)`. Minimum 1. Also change `"Hatch (100 Coins)"` in `EggStand`.
- More equip slots: change `EConfig.Set("Pets.MaxEquipSlots", 3)`. The panel shows the new number.
- Give a pet as a reward (quest, code, Robux): `Pet.GrantPet(player, "pet_Dragon")` on the server. It returns the new pet's uid, or `nil`.
- Equip from server code: `Pet.Equip(player, uid)` returns `true, "equipped"` or `false` and the reason (`"not owned"`, `"already equipped"`, `"all slots full"`). Undo: `Pet.Unequip(player, uid)`.
- List a player's pets: `Pet.GetOwned(player)` gives `{ petId, uid }` rows. `Pet.GetEquipped(player)` gives equipped uids.
- Open the panel from your own code (LocalScript): `Gaxia.UI.PetController.Open()` / `Close()` / `Toggle()`.
- Boost Idle offline earnings: configure Idle with `Currency = "Coins"` ([progression](progression.md)). `GaxiaServer.Idle.Collect` multiplies by itself.
- Boost quest rewards: a quest with `reward = { currency = "Coins", amount = 100 }` pays `100 × multiplier` by itself ([progression](progression.md)).

## See also

- [API: Pet](../api/Pet.md) · [API: Economy](../api/Economy.md) · [API: Interaction](../api/Interaction.md) · [API: Loot](../api/Loot.md)
- [Coins and leaderstats](currency-and-leaderstats.md) · [Progression](progression.md) · [Areas and press-E prompts](zones-and-interactions.md) · [Config and flags](config-and-flags.md)
