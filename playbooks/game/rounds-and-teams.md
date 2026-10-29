# Make rounds with teams (intermission, map, timer, winner)

> Players wait in the lobby, a countdown shows on every screen, then a random map loads. Players are split into Red and Blue, sent to the map, and the round runs on a timer. The team with the most players still alive wins Coins. Everyone goes back to the lobby, and it starts again.

**Use this when** the user asks for: "rounds", "round system", "game loop", "intermission", "countdown before the match", "teams", "split players into teams", "red vs blue", "random map", "round timer", "winner gets coins", "minimum players to start" (ไทย: "ระบบรอบ", "พักก่อนเริ่มรอบ", "นับถอยหลัง", "แบ่งทีม", "ทีมแดงทีมน้ำเงิน", "สุ่มแมพ", "เวลารอบ", "ทีมที่ชนะได้เหรียญ", "ต้องมีผู้เล่นครบก่อนเริ่ม").
**Packages:** `Player` and `Economy` (it also installs `Data`). `State` and `Trove` are Core: always installed. The Script stops with a clear message if one is missing.
**You will create:** a ModuleScript `ServerStorage/GameModules/RoundMaps`, a Script `ServerScriptService/RoundManager` and a LocalScript `StarterPlayer/StarterPlayerScripts/RoundHud`.

How it works (it runs in an empty Baseplate: the module builds two maps by itself):

- **RoundManager** (server) runs one loop: wait for players → intermission countdown → pick a map → make teams → teleport → round timer → winner and reward → back to the lobby.
- It writes `Phase`, `TimeLeft` and `Status` into a state container named `RoundInfo` (`Gaxia.State`). The container copies itself to **every** client. **RoundHud** only reads it.
- Players are moved with `GaxiaServer.Player.Teleport`, so the anti-cheat does not flag the jump to the map.
- A player who dies or leaves is "out". A player who joins during a round waits in the lobby for the next one.

## Step 1 — Create the maps module

In **ServerStorage**, insert a **Folder** named **GameModules** (skip if it exists). In it, insert a **ModuleScript** named **RoundMaps** and paste:

```lua
-- ModuleScript: ServerStorage/GameModules/RoundMaps
-- The lobby position and the maps. Each map is a Model in ServerStorage/Maps
-- with one part named RedSpawn and one part named BlueSpawn.
local ServerStorage = game:GetService("ServerStorage")

local RoundMaps = {}

-- Where players go when a round ends: above the middle of the Baseplate.
RoundMaps.LOBBY_CFRAME = CFrame.new(0, 5, 0)

local function makePart(name: string, size: Vector3, position: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Anchored = true
	part.Color = color
	part.Parent = parent
	return part
end

-- A flat island far from the Baseplate. A player who falls off dies and is out.
local function buildMap(name: string, center: Vector3, color: Color3): Model
	local map = Instance.new("Model")
	map.Name = name
	map.PrimaryPart = makePart("Floor", Vector3.new(80, 2, 80), center, color, map)
	makePart("RedSpawn", Vector3.new(6, 1, 6), center + Vector3.new(-30, 1.5, 0), Color3.fromRGB(220, 60, 60), map)
	makePart("BlueSpawn", Vector3.new(6, 1, 6), center + Vector3.new(30, 1.5, 0), Color3.fromRGB(60, 90, 220), map)
	return map
end

-- Returns ServerStorage/Maps. Builds two maps the first time if the folder is missing.
function RoundMaps.GetFolder(): Folder
	local existing = ServerStorage:FindFirstChild("Maps")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Maps"
	buildMap("Grassland", Vector3.new(1400, 50, 0), Color3.fromRGB(90, 170, 80)).Parent = folder
	buildMap("Desert", Vector3.new(-1400, 50, 0), Color3.fromRGB(220, 190, 120)).Parent = folder
	folder.Parent = ServerStorage
	return folder
end

return RoundMaps
```

What it does: maps wait in ServerStorage (players cannot see them there). The round copies one into Workspace.

## Step 2 — Create the round loop on the server

Create a **Script** in **ServerScriptService** named **RoundManager**. Paste this whole block into it:

```lua
-- Script: ServerScriptService/RoundManager
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Teams = game:GetService("Teams")
local Workspace = game:GetService("Workspace")
local GaxiaServer = require(game:GetService("ServerStorage").Gaxia_Packages_Server)
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)
local RoundMaps = require(ServerStorage.GameModules.RoundMaps)

for _, package in { "Player", "Economy" } do
	assert(GaxiaServer.IsInstalled(package), `RoundManager needs the {package} package: install it (playbooks/start/01-install-packages.md)`)
end
local PlayerService = GaxiaServer.Player
local Data = GaxiaServer.Data
local Economy = GaxiaServer.Economy

local INTERMISSION_SECONDS = 15
local ROUND_SECONDS = 60
local END_SECONDS = 5 -- how long the winner message shows
local MIN_PLAYERS = 2
local STUDIO_MIN_PLAYERS = 1 -- Studio Play has 1 player, so 1 is enough there. No effect in a live game.
local WIN_COINS = 25

-- Every client sees these three values (RoundHud shows them).
local roundState = Gaxia.State.Create("RoundInfo", { Phase = "Waiting", TimeLeft = 0, Status = "Waiting for players" })

local function makeTeam(name: string, color: BrickColor): Team
	local existing = Teams:FindFirstChild(name)
	if existing and existing:IsA("Team") then
		return existing -- a team you made in Studio is reused
	end
	local team = Instance.new("Team")
	team.Name = name
	team.TeamColor = color
	team.AutoAssignable = false -- RoundManager picks the team, not Roblox
	team.Parent = Teams
	return team
end
local TEAMS = { makeTeam("Red", BrickColor.new("Bright red")), makeTeam("Blue", BrickColor.new("Bright blue")) }

local alive: { [Player]: Team } = {} -- players in the round who are still alive
local roundTrove = Gaxia.Trove.new() -- the round's connections, cleaned when the round ends

local function minPlayers(): number
	return if RunService:IsStudio() then STUDIO_MIN_PLAYERS else MIN_PLAYERS
end

local function setState(phase: string, timeLeft: number, status: string)
	roundState:Set("Phase", phase)
	roundState:Set("TimeLeft", timeLeft)
	roundState:Set("Status", status)
end

local function countAlive(team: Team): number
	local count = 0
	for _, playerTeam in alive do
		if playerTeam == team then count += 1 end
	end
	return count
end

local function teamsWithPlayers(): number
	local count = 0
	for _, team in TEAMS do
		if countAlive(team) > 0 then count += 1 end
	end
	return count
end

-- Takes a player out of the round. The round loop checks the counts every second.
local function knockOut(player: Player, why: string)
	if alive[player] then
		alive[player] = nil
		print(`[RoundManager] {player.Name} is out ({why})`)
	end
end

local function pickMap(): Model?
	local maps: { Model } = {}
	for _, child in RoundMaps.GetFolder():GetChildren() do
		if child:IsA("Model") then table.insert(maps, child) end
	end
	if #maps == 0 then
		warn("[RoundManager] ServerStorage/Maps has no Model: add a map")
		return nil
	end
	local map = maps[math.random(1, #maps)]:Clone()
	map.Parent = Workspace
	print(`[RoundManager] map: {map.Name}`)
	return map
end

-- The spawn point of a team on a map. `index` spreads players apart.
local function spawnCFrame(map: Model, team: Team, index: number): CFrame
	local spawnPart = map:FindFirstChild(team.Name .. "Spawn", true)
	if spawnPart and spawnPart:IsA("BasePart") then
		return spawnPart.CFrame + Vector3.new(0, 4, (index % 5) * 3 - 6)
	end
	warn(`[RoundManager] map {map.Name} has no part named {team.Name}Spawn`)
	return map:GetPivot() + Vector3.new(0, 6, 0)
end

local function startRound(map: Model)
	local players = Players:GetPlayers()
	for i = #players, 2, -1 do -- shuffle, so the teams are different every round
		local j = math.random(1, i)
		players[i], players[j] = players[j], players[i]
	end
	for index, player in players do
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid and humanoid.Health > 0 then -- no character yet (still loading): stays in the lobby
			local team = TEAMS[(index - 1) % #TEAMS + 1]
			player.Neutral = false
			player.Team = team
			alive[player] = team
			roundTrove:Connect(humanoid.Died, function()
				knockOut(player, "died")
			end)
			local target = spawnCFrame(map, team, index)
			task.spawn(function()
				-- Load the map around the player first (StreamingEnabled), so they do not fall through it.
				pcall(function()
					player:RequestStreamAroundAsync(target.Position)
				end)
				if alive[player] == team then -- still in the round
					PlayerService.Teleport(player, target)
				end
			end)
			print(`[RoundManager] {player.Name} is on team {team.Name}`)
		end
	end
end

-- Runs the round timer. Returns the winning team, or nil for a draw.
local function runRound(): Team?
	local startTeams = teamsWithPlayers()
	for timeLeft = ROUND_SECONDS, 1, -1 do
		local parts = {}
		for _, team in TEAMS do
			table.insert(parts, `{team.Name} {countAlive(team)}`)
		end
		setState("Round", timeLeft, table.concat(parts, " vs "))
		if next(alive) == nil then
			return nil -- everyone is out
		end
		if startTeams >= 2 and teamsWithPlayers() == 1 then
			break -- only one team is left: it wins now
		end
		task.wait(1)
	end
	local best: Team? = nil
	local bestCount, tie = 0, false
	for _, team in TEAMS do
		local count = countAlive(team)
		if count > bestCount then
			best, bestCount, tie = team, count, false
		elseif count == bestCount and count > 0 then
			tie = true
		end
	end
	return if tie then nil else best
end

local function endRound(map: Model, winner: Team?)
	roundTrove:Clean() -- disconnects the Died connections
	local message = if winner then `{winner.Name} team wins!` else "Draw! Nobody wins"
	setState("Ended", END_SECONDS, message)
	if winner then
		print(`[RoundManager] winner: {winner.Name}`)
		for _, player in winner:GetPlayers() do
			if Data.IsLoaded(player) and Economy.Add(player, "Coins", WIN_COINS) then
				print(`[RoundManager] {player.Name} got {WIN_COINS} Coins`)
			end
		end
	else
		print("[RoundManager] draw")
	end
	for player in alive do -- players who died already respawned in the lobby
		PlayerService.Teleport(player, RoundMaps.LOBBY_CFRAME)
	end
	for _, player in Players:GetPlayers() do
		player.Neutral = true -- no team: Roblox also clears player.Team
	end
	table.clear(alive)
	map:Destroy()
	for timeLeft = END_SECONDS, 1, -1 do -- the winner message counts down
		setState("Ended", timeLeft, message)
		task.wait(1)
	end
end

Players.PlayerAdded:Connect(function(player: Player)
	if roundState:Get("Phase") == "Round" then
		print(`[RoundManager] {player.Name} joined during a round: waits in the lobby`)
	end
end)
Players.PlayerRemoving:Connect(function(player: Player)
	knockOut(player, "left")
end)

print("[RoundManager] ready")
while true do
	local playerCount = #Players:GetPlayers()
	if playerCount < minPlayers() then
		setState("Waiting", 0, `Waiting for players ({playerCount}/{minPlayers()})`)
		task.wait(1)
		continue
	end
	local enough = true
	for timeLeft = INTERMISSION_SECONDS, 1, -1 do
		if #Players:GetPlayers() < minPlayers() then
			enough = false -- someone left during the countdown
			break
		end
		setState("Intermission", timeLeft, "Intermission")
		task.wait(1)
	end
	local map = if enough then pickMap() else nil
	if map then
		print("[RoundManager] round started")
		startRound(map)
		if teamsWithPlayers() < math.min(2, minPlayers()) then
			-- Only one team has players (someone had no character): no free win.
			print("[RoundManager] not enough players on teams")
			endRound(map, nil)
		else
			endRound(map, runRound())
		end
	elseif enough then
		task.wait(5) -- no map: try again in 5 seconds
	end
end
```

What it does: the `while true do` loop at the end is the whole game. `alive` holds who is still in the round. `Humanoid.Died` and leaving the game both call `knockOut`.

## Step 3 — Show the countdown on every screen

Create a **LocalScript** in **StarterPlayer → StarterPlayerScripts** named **RoundHud**:

```lua
-- LocalScript: StarterPlayer/StarterPlayerScripts/RoundHud
local Players = game:GetService("Players")
local Gaxia = require(game:GetService("ReplicatedStorage").Gaxia_Packages)

local player = Players.LocalPlayer

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "RoundHud"
screenGui.ResetOnSpawn = false -- keep the label after the character respawns
screenGui.Parent = player:WaitForChild("PlayerGui")

local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(320, 40)
label.Position = UDim2.new(0.5, -160, 0, 10)
label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
label.BackgroundTransparency = 0.4
label.TextColor3 = Color3.fromRGB(255, 255, 255)
label.Font = Enum.Font.GothamBold
label.TextScaled = true
label.Text = "..."
label.Parent = screenGui

-- State.Get waits for the server to create the container, then returns it (or nil).
local roundState = Gaxia.State.Get("RoundInfo")
assert(roundState, "RoundHud: state 'RoundInfo' not found. Is the Script ServerScriptService/RoundManager running?")

local function refresh()
	local status = tostring(roundState:Get("Status") or "...")
	local timeLeft = tonumber(roundState:Get("TimeLeft")) or 0
	label.Text = if timeLeft > 0 then `{status} - {timeLeft} s` else status
end
roundState:OnChanged("Status", refresh)
roundState:OnChanged("TimeLeft", refresh)
roundState:OnChanged("Phase", function(phase: any)
	print(`[RoundHud] phase: {tostring(phase)}`)
end)
print(`[RoundHud] phase: {tostring(roundState:Get("Phase"))}`) -- the phase right now
refresh()
print("[RoundHud] ready")
```

What it does: the label changes every time the server sets `Status` or `TimeLeft`. No loop is needed on the client.

## Check that it works

1. Press **Play** in Studio. Output shows `[RoundManager] ready` and `[RoundHud] ready`, and no red errors.
2. The top label shows `Intermission - 15 s` (or a smaller number), counting down. Output shows `[RoundHud] phase: Intermission` (or `Waiting` first, then `Intermission`).
3. After 15 seconds Output shows `[RoundManager] map: Grassland` (or `Desert`), `[RoundManager] round started` and `[RoundManager] <YourName> is on team Red` (or Blue). You stand on a floating island. Your name in the player list is in the team color.
4. The label shows `Red 1 vs Blue 0 - 60 s`, counting down. When it ends, Output shows `[RoundManager] winner: Red` and `[RoundManager] <YourName> got 25 Coins`. The label shows `Red team wins! - 5 s`, counting down to 1. You are back above the Baseplate.
5. Walk off the island during a round. Output shows `[RoundManager] <YourName> is out (died)`, then `[RoundManager] draw` (nobody is left). If `AntiCheat` is installed, a yellow `[AntiCheat] observe mode ... Combat` warning may also show: that death did not go through `RegisterDamage` ([anticheat-and-bans](anticheat-and-bans.md)).
6. Two players: in the **Test** tab, set **Clients and Servers** to 2 players and click **Start**. When the round starts, Output shows one player on team Red and one on team Blue.
7. Minimum players (optional): Studio needs only `STUDIO_MIN_PLAYERS` (1) players, so first set `STUDIO_MIN_PLAYERS = 2` in RoundManager. Start 2 players again. Close one player window during the countdown: the label shows `Waiting for players (1/2)`. Set `STUDIO_MIN_PLAYERS` back to `1` when you are done.

## Common mistakes

| Wrong | Right | Why |
|---|---|---|
| `character.HumanoidRootPart.CFrame = spawn.CFrame` | `PlayerService.Teleport(player, cframe)` | A big jump without it is a `Teleport` cheat flag. Teleport tells AntiCheat it is allowed. |
| The countdown in a LocalScript with its own `task.wait` loop | The server sets `TimeLeft` in `RoundInfo`; the client only shows it | Each client would count on its own and drift. Players who join late would see a different number. |
| `roundState:Set(...)` in RoundHud | Only RoundManager sets the state | A client `Set` changes only that client's copy. The server never sees it. |
| `humanoid.Died:Connect(...)` every round, never disconnected | `roundTrove:Connect(humanoid.Died, ...)` and `roundTrove:Clean()` at the end | Old connections pile up. A death in a later round runs old code. |
| `MIN_PLAYERS = 1` for the live game | `MIN_PLAYERS = 2`, `STUDIO_MIN_PLAYERS = 1` | One player alone always wins. Studio Play only lifts the limit while you test. |
| `State.Create("Round", ...)` | `State.Create("RoundInfo", ...)` | [show-values-on-screen](show-values-on-screen.md) already uses `Round` with other keys. Two scripts in one container overwrite each other. |
| `PlayerService.Teleport(...)` right after the map is cloned, with no `RequestStreamAroundAsync` | `pcall(function() player:RequestStreamAroundAsync(target.Position) end)` first, then Teleport | With `Workspace.StreamingEnabled` on (new places have it on), the far map may not be loaded on the client yet. The player falls through it, dies and is out. |
| A round that starts with players on one team only | `teamsWithPlayers() < math.min(2, minPlayers())` → end as a draw with no Coins | The lone team would win `WIN_COINS` for free. An alt account that resets at the right moment could farm Coins. |
| Map parts with `Anchored = false` | Anchor every map part | Unanchored floors fall into the void before players arrive. |

## Change it

- Use your own maps: in **ServerStorage**, make a **Folder** named **Maps**. Put one **Model** per map in it. Each Model needs a part named `RedSpawn` and a part named `BlueSpawn`. Place them far from the lobby. RoundMaps then builds nothing.
- Times and reward: change `INTERMISSION_SECONDS`, `ROUND_SECONDS`, `MIN_PLAYERS` and `WIN_COINS` at the top of RoundManager.
- A third team: add `makeTeam("Green", BrickColor.new("Bright green"))` to `TEAMS`, and a part named `GreenSpawn` to every map.
- Your lobby somewhere else: change `RoundMaps.LOBBY_CFRAME` to a point above your lobby floor.
- Coins on the leaderboard and in a label: [currency-and-leaderstats](currency-and-leaderstats.md), [show-values-on-screen](show-values-on-screen.md). A message when a team wins: send it with `Gaxia.Net.FireAllClients` and show a toast ([ui](ui.md)).

## See also

- [API: Player](../api/Player.md) · [API: State](../api/Core.ReplicatedState.md) · [API: Trove](../api/Core.Trove.md) · [API: Economy](../api/Economy.md)
- [Show values on screen](show-values-on-screen.md) · [Zones and interactions](zones-and-interactions.md) · [Signals, cleanup and timing](signals-cleanup-and-timing.md) · [Troubleshooting](../troubleshooting.md)
