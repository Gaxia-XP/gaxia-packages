--!strict
-- ─────────────────────────────────────────────────────────────
-- AIService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/AIService
-- Purpose : NPC locomotion over PathfindingService. The framework had Raycaster
--           but no pathfinding, so every game re-wrote ComputeAsync + waypoint-
--           walking + jump handling + "stop the current move" bookkeeping (raid
--           attackers, roaming mobs, escort NPCs). AIService wraps it: ComputePath
--           for a route, MoveTo to walk it (handles Jump waypoints, cancellable),
--           Roam for wander, Follow to chase a moving target, Stop to halt. A
--           per-model token makes a new command cleanly cancel the previous one.
--
-- Access  : Gaxia.AI  (server)
--   Gaxia.AI.MoveTo(npcModel, Vector3.new(0,5,40))
--   local stop = Gaxia.AI.Roam(npcModel, spawnPos, 30)   ;  stop()
--   Gaxia.AI.Follow(npcModel, player.Character)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

local DEFAULT_AGENT: { [string]: any } = {
	AgentRadius = 2,
	AgentHeight = 5,
	AgentCanJump = true,
	WaypointSpacing = 4,
}

local AIService = {}

AIService.OnReached = Signal.new() -- (model, target)

-- One active movement token per model; replacing it cancels the prior walk.
local activeTokens: { [Model]: any } = {}

-- ── Helpers ──

local function getHumanoid(model: Model): Humanoid?
	return model:FindFirstChildWhichIsA("Humanoid")
end

local function getRoot(model: Model): BasePart?
	return model.PrimaryPart or (model:FindFirstChild("HumanoidRootPart") :: BasePart?)
end

-- ── PathfindingService wrapper ──

-- Returns the waypoint list (or nil) + the PathStatus name. Pure-ish: no model,
-- just geometry — easy to assert on.
function AIService.ComputePath(from: Vector3, to: Vector3, agentParams: { [string]: any }?): ({ PathWaypoint }?, string)
	local path = PathfindingService:CreatePath(agentParams or DEFAULT_AGENT)
	local ok, err = pcall(function()
		path:ComputeAsync(from, to)
	end)
	if not ok then
		return nil, `error: {tostring(err)}`
	end
	if path.Status ~= Enum.PathStatus.Success then
		return nil, path.Status.Name
	end
	return path:GetWaypoints(), "Success"
end

-- ── Mover ──

-- Walk `model` to `target`, following the path. Yields until arrival, an 8s
-- per-waypoint Humanoid timeout, or cancellation (Stop / a newer command).
-- Returns true if the route completed.
function AIService.MoveTo(model: Model, target: Vector3, agentParams: { [string]: any }?): boolean
	local hum = getHumanoid(model)
	local root = getRoot(model)
	if not hum or not root then
		return false
	end
	local waypoints, status = AIService.ComputePath(root.Position, target, agentParams)
	if not waypoints then
		return false
	end

	local token = {}
	activeTokens[model] = token

	for _, wp in ipairs(waypoints) do
		if activeTokens[model] ~= token then
			return false -- cancelled mid-route
		end
		if wp.Action == Enum.PathWaypointAction.Jump then
			hum:ChangeState(Enum.HumanoidStateType.Jumping)
		end
		hum:MoveTo(wp.Position)
		hum.MoveToFinished:Wait() -- fires on reach or Roblox's 8s auto-timeout
	end

	if activeTokens[model] == token then
		activeTokens[model] = nil
		AIService.OnReached:Fire(model, target)
		return true
	end
	return false
end

-- Halt the model's current movement.
function AIService.Stop(model: Model): ()
	activeTokens[model] = nil
	local hum = getHumanoid(model)
	local root = getRoot(model)
	if hum and root then
		hum:MoveTo(root.Position) -- cancel the in-flight MoveTo target
	end
end

function AIService.IsMoving(model: Model): boolean
	return activeTokens[model] ~= nil
end

-- ── Roam: wander within `radius` of `center` ──
function AIService.Roam(model: Model, center: Vector3, radius: number): () -> ()
	local stopped = false
	local rng = Random.new()
	task.spawn(function()
		while not stopped and model.Parent do
			local angle = rng:NextNumber(0, math.pi * 2)
			local dist = rng:NextNumber(0, radius)
			local target = center + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
			AIService.MoveTo(model, target)
			if stopped then
				break
			end
			task.wait(rng:NextNumber(1, 3))
		end
	end)
	return function()
		stopped = true
		AIService.Stop(model)
	end
end

-- ── Follow: chase a moving target part/model, repathing on an interval ──
function AIService.Follow(model: Model, target: Instance, opts: { Interval: number?, StopDistance: number? }?): () -> ()
	local stopped = false
	local interval = (opts and opts.Interval) or 0.5
	local stopDist = (opts and opts.StopDistance) or 6
	task.spawn(function()
		while not stopped and model.Parent do
			local tp: BasePart? = nil
			if target:IsA("Model") then
				tp = target.PrimaryPart or (target:FindFirstChild("HumanoidRootPart") :: BasePart?)
			elseif target:IsA("BasePart") then
				tp = target
			end
			local root = getRoot(model)
			if tp and root then
				if (tp.Position - root.Position).Magnitude > stopDist then
					AIService.MoveTo(model, tp.Position)
				end
			end
			task.wait(interval)
		end
	end)
	return function()
		stopped = true
		AIService.Stop(model)
	end
end

return AIService
