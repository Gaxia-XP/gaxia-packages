# Add XP and levels, quests and achievements

> Players collect apples for a quest, the quest pays Coins and XP, they level up, unlock achievements, and the player list shows their Level.

**Use this when** the user asks for: "XP", "levels", "level up", "quests", "missions", "achievements", "badges in game", "collect 5 items quest", "show level on leaderboard" (ไทย: "เลเวล", "ระบบเลเวล", "เก็บ XP", "เควส", "ภารกิจ", "ความสำเร็จ", "อาชีฟเมนต์", "เก็บของครบได้รางวัล", "โชว์เลเวลบน leaderboard").
**Packages:** `Level`, `Quest`, `Achievement`, `Player` (Quest also installs `Data`, `Economy`, `Item`). The scripts below stop with a clear message if one is missing.
**You will create:** the Scripts `ServerScriptService/Progression` and `ServerScriptService/AppleSpawner`.

How it works:

- `GaxiaServer.Level` saves `Level` and `Experience` in the player's data. `Level.AddXP` adds XP and levels up as many times as the XP allows. `Level.OnLevelUp` fires once per level gained. XP needed to leave level L = `floor(CurveBase * L ^ CurveExponent)` from `GaxiaServer.Config.Level` (default `100 * L^1.5`: level 1 → 100 XP, level 2 → 282 XP, level 3 → 519 XP). Leftover XP carries over.
- `GaxiaServer.Quest` keeps quest definitions (`Quest.Register`) and each player's active quests (saved). `Quest.Track(player, "collect", "Apple", 1)` adds progress to every active quest with that goal. When all goals are done, Quest pays the reward (Coins/items), removes the quest and fires `Quest.OnQuestComplete`. With the `Pet` package, an equipped pet's coin bonus multiplies quest Coins ([pets](pets.md)).
- Quest does **not** remember finished quests and has no XP reward. The game saves finished quests itself (`QuestsDone` below) and gives XP in `OnQuestComplete`.
- `GaxiaServer.Achievement` saves unlocked achievements. `Achievement.Award` unlocks one directly (returns `false` for an id that was never registered). `Achievement.Track` checks every achievement's `condition` function. An unlock pays its `reward` once. Read unlocks with `Achievement.IsUnlocked(player, id)` or `Achievement.GetUnlocked(player)` (a list of ids).

## Step 1 — Create the quest, achievements and level display

Create a **Script** in **ServerScriptService** named **Progression**. It shows Level in the player list and starts the quest on load. Paste this whole block into it:

```lua
-- Script: ServerScriptService/Progression
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

-- Stop early, with a clear message, if a package this script needs is missing.
assert(GaxiaServer.IsInstalled("Level"), "Progression needs the Level package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Quest"), "Progression needs the Quest package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Achievement"), "Progression needs the Achievement package: install it (playbooks/start/01-install-packages.md)")
assert(GaxiaServer.IsInstalled("Player"), "Progression needs the Player package: install it (playbooks/start/01-install-packages.md)")

local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy
local Level = GaxiaServer.Level
local Quest = GaxiaServer.Quest
local Achievement = GaxiaServer.Achievement
local PlayerService = GaxiaServer.Player

local QUEST_ID = "CollectApples"
-- XP per quest id. Quest rewards have no XP field: this script gives it.
local QUEST_XP: { [string]: number } = { [QUEST_ID] = 150 }

-- 1. The quest. Quest pays reward.currency/amount (and reward.items) by itself.
Quest.Register({
	id = QUEST_ID, name = "Apple Picker", description = "Collect 5 apples",
	goals = { { type = "collect", target = "Apple", count = 5 } },
	reward = { currency = "Coins", amount = 50 },
})

-- 2. Achievements. "FirstQuest" is unlocked with Award; "ReachLevel2" by its condition.
Achievement.Register({
	id = "FirstQuest", name = "Quest Starter", description = "Finish your first quest",
	reward = { currency = "Gems", amount = 5 },
})
Achievement.Register({
	id = "ReachLevel2", name = "Growing Up", description = "Reach level 2",
	reward = { currency = "Coins", amount = 100 },
	condition = function(_player: Player, eventType: string, newLevel: any): boolean
		return eventType == "level" and typeof(newLevel) == "number" and newLevel >= 2
	end,
})

-- Finished quests, saved in the player's data as { [questId] = true }.
local function getQuestsDone(player: Player): { [string]: boolean }
	local done = Data.Get(player, "QuestsDone")
	if typeof(done) ~= "table" then
		done = {}
		Data.Set(player, "QuestsDone", done)
	end
	return done
end

-- 3. React to progress, completion, XP and level-ups. goalKey is the goal's target ("Apple").
Quest.OnGoalProgress:Connect(function(player: Player, questId: string, goalKey: string, current: number, target: number)
	print(`[Progression] {player.Name} {questId}: {goalKey} {current}/{target}`)
end)

Quest.OnQuestComplete:Connect(function(player: Player, questId: string, reward)
	print(`[Progression] {player.Name} finished {questId}, reward {reward.amount} {reward.currency} (before pet bonus)`)
	local done = getQuestsDone(player)
	done[questId] = true
	Data.Set(player, "QuestsDone", done)
	Level.AddXP(player, QUEST_XP[questId] or 0)
	Achievement.Award(player, "FirstQuest")
end)

Level.OnXPGained:Connect(function(player: Player, amount: number)
	print(`[Progression] {player.Name} +{amount} XP`)
end)

Level.OnLevelUp:Connect(function(player: Player, newLevel: number, oldLevel: number)
	print(`[Progression] {player.Name} level {oldLevel} -> {newLevel}, {Level.GetXPToNext(player)} XP to next`)
	PlayerService.SetLeaderstat(player, "Level", newLevel)
	Achievement.Track(player, "level", newLevel)
end)

Achievement.OnUnlocked:Connect(function(player: Player, id: string, def)
	print(`[Progression] {player.Name} unlocked achievement {id} ({def.name}), now {Economy.Get(player, "Coins")} Coins`)
end)

-- 4. When the player's data is loaded: show Level, start the quest if not finished before.
local function onPlayerAdded(player: Player)
	if Data.WaitFor(player, 120) == nil then
		return -- the player left, or the data did not load in 120 seconds
	end
	-- Adds or updates only the Level column; other columns (Coins) stay.
	PlayerService.SetupLeaderstats(player, { Level = Level.GetLevel(player) })
	if not getQuestsDone(player)[QUEST_ID] then
		-- false when the quest is already active (progress from last time is kept)
		Quest.Start(player, QUEST_ID)
	end
	local active = Quest.GetActive(player)[QUEST_ID] ~= nil
	print(`[Progression] {player.Name} is level {Level.GetLevel(player)}, apple quest active: {active}`)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

print("[Progression] ready")
```

## Step 2 — Spawn apples that count for the quest

Create a **Script** in **ServerScriptService** named **AppleSpawner**. It places 8 red apples in a circle (12 studs radius) whose middle is 48 studs from the middle of the Baseplate, toward +Z. Touching one counts 1 apple.

```lua
-- Script: ServerScriptService/AppleSpawner
local Players = game:GetService("Players")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)

assert(GaxiaServer.IsInstalled("Quest"), "AppleSpawner needs the Quest package: install it (playbooks/start/01-install-packages.md)")

local Quest = GaxiaServer.Quest

local APPLE_COUNT = 8
local RESPAWN_SECONDS = 5
local MAX_DISTANCE = 12 -- studs: a touch from farther away is a cheat
local CIRCLE_CENTER = Vector3.new(0, 3, 48) -- away from the parts of the other playbooks

local folder = Instance.new("Folder")
folder.Name = "Apples"
folder.Parent = workspace

local function makeApple(index: number)
	local apple = Instance.new("Part")
	apple.Name = "Apple"
	apple.Shape = Enum.PartType.Ball
	apple.Size = Vector3.new(2, 2, 2)
	apple.Color = Color3.fromRGB(220, 30, 30)
	apple.Anchored = true
	apple.CanCollide = false
	-- A circle of apples, 12 studs from CIRCLE_CENTER.
	local angle = index / APPLE_COUNT * math.pi * 2
	apple.Position = CIRCLE_CENTER + Vector3.new(math.cos(angle) * 12, 0, math.sin(angle) * 12)
	apple.Parent = folder

	apple.Touched:Connect(function(hit: BasePart)
		local character = hit:FindFirstAncestorOfClass("Model")
		local player = if character then Players:GetPlayerFromCharacter(character) else nil
		if player == nil or character == nil or not apple.CanTouch then
			return -- not a player, or this apple was just picked
		end
		if (character:GetPivot().Position - apple.Position).Magnitude > MAX_DISTANCE then
			return -- too far away: an exploit fired Touched, ignore it
		end
		-- Hide the apple so it counts once, then bring it back.
		apple.CanTouch = false
		apple.Transparency = 1
		Quest.Track(player, "collect", "Apple", 1) -- the SERVER tracks; players without the quest are ignored
		task.delay(RESPAWN_SECONDS, function()
			apple.Transparency = 0
			apple.CanTouch = true
		end)
	end)
end

for index = 1, APPLE_COUNT do
	makeApple(index)
end

print(`[AppleSpawner] ready, {APPLE_COUNT} apples`)
```

## Check that it works

Before you press Play: turn on **Enable Studio Access to API Services** (see [player-data](player-data.md)). Without it, item 6 fails.

1. Press **Play** in Studio.
2. Output shows `[Progression] ready` and `[AppleSpawner] ready, 8 apples`, and no red errors.
3. Within a few seconds Output shows `[Progression] <YourName> is level 1, apple quest active: true`. The player list shows a **Level** column with `1`.
4. Walk toward +Z (48 studs from the middle of the Baseplate) and into an apple. Output shows `[Progression] <YourName> CollectApples: Apple 1/5`.
5. Touch 5 apples. Output shows, in this order: `finished CollectApples, reward 50 Coins (before pet bonus)`, `+150 XP`, `level 1 -> 2, 232 XP to next`, `unlocked achievement ReachLevel2 (Growing Up), now <N> Coins`, `unlocked achievement FirstQuest (Quest Starter), now <N> Coins`. The **Level** column shows `2`. On a new save `<N>` is `150` (50 quest + 100 `ReachLevel2`); FirstQuest also gave 5 Gems. With an equipped coin pet, `<N>` is higher.
6. Stop and press **Play** again: Output shows `is level 2, apple quest active: false`. The quest does not start again.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `Quest.IsComplete(player, id)` to know if a quest was finished | Save finished quests yourself (`QuestsDone` in Step 1) | `IsComplete` is `true` for every quest that is not active, also one never started. |
| `reward = { xp = 150 }` in the quest | Give XP in `Quest.OnQuestComplete` with `Level.AddXP` | Quest only pays `currency`/`amount` and `items`. Other fields are ignored. |
| `Quest.Start` in `PlayerAdded` right away | `Data.WaitFor(player, 120)` first | Before data loads, `Start` returns `false` and `Track` does nothing. |
| `Quest.Track` from a LocalScript or after a client remote with no checks | Track on the server, from a server event (Touched, a kill, a purchase) | A cheater would finish quests by sending the remote. |
| Counting every `Touched` | Check the character is near the apple (Step 2) | Exploiters can fire `Touched` from far away. |
| `Quest.Start` directly inside `Quest.OnQuestComplete` | `task.defer(Quest.Start, player, id)` | Track is still looping the active quests: the new quest can get progress from the same event. |
| `Quest.Track(player, "Collect", "apple")` | `Quest.Track(player, "collect", "Apple", 1)` | Type and target must match the goal exactly (case too). Types: `"kill"`, `"collect"`, `"reach"`, `"time_played"`. |
| Two goals with the same `target` in one quest | One `target` name per goal | Progress is saved per target, so both goals share one counter. |
| `player.leaderstats.Level.Value = 2` or `Data.Set(player, "Level", 2)` | `Level.AddXP` / `Level.SetLevel`, then `GaxiaServer.Player.SetLeaderstat` | Writing the value yourself fires no `OnLevelUp`, and AntiCheat flags a changed leaderstat. |
| A field of your own named `Quests` or `Achievements` | `QuestsDone` or another new name | Quest and Achievement save under those names. |

## Change it

- To make leveling faster or slower: never edit `GaxiaServer.Config`. Override `Level.CurveBase` / `Level.CurveExponent` with `GaxiaServer.EConfig.Set("Level.CurveBase", 50)` in `ConfigOverrides` ([config-and-flags](config-and-flags.md)). Your own formula: `Level.SetCurve(function(level) return level * 100 end)` at the top of `Progression`.
- To give XP for anything else (a kill, a sale): call `Level.AddXP(player, amount)` on the server. `OnLevelUp` keeps the leaderboard right. To show level or XP in your own screen UI: [show-values-on-screen](show-values-on-screen.md).
- To give items as a quest reward: `reward = { currency = "Coins", amount = 50, items = { Sword = 1 } }`. It works on its own: `GaxiaServer.Item` saves any item id, no registration needed ([items-and-inventory](items-and-inventory.md)).
- To add a quest: one more `Quest.Register({...})` with a new `id`, its XP in `QUEST_XP`, and `Quest.Start(player, "<id>")` when it should begin (on load or from an NPC). After another quest: inside `OnQuestComplete` write `task.defer(Quest.Start, player, "<id>")`, never a direct call. For a repeatable quest, replace `done[questId] = true` with `if questId ~= "<id>" then done[questId] = true end`.

## See also

- [API: Level](../api/Level.md) · [API: Quest](../api/Quest.md) · [API: Achievement](../api/Achievement.md) · [API: Player](../api/Player.md) · [Coins and leaderstats](currency-and-leaderstats.md) · [Player data](player-data.md) · [Live ops](live-ops.md) · [Pets](pets.md)
