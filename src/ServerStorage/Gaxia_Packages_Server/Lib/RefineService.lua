--!strict
-- ─────────────────────────────────────────────────────────────
-- RefineService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/RefineService
-- Purpose : Server-authoritative crafting / refining / transmuting engine. Every
--           crafting game re-implements "consume these items, grant those" with
--           hand-rolled (and exploitable) inventory math. Refine defines recipes
--           (inputs → outputs, optional level gate) and runs them ATOMICALLY:
--           inputs are verified-then-consumed and refunded if anything fails, so
--           a craft can never half-apply or duplicate. Supports instant Craft
--           AND timed Begin/Claim (smelters, kilns, idle crafters) with the
--           timer in os.time so it keeps running while the player is offline.
--
-- Access  : Gaxia.Refine  (server)
--   Gaxia.Refine.DefineRecipe("Bronze", { Inputs={Copper=1,Tin=1}, Outputs={Bronze=1} })
--   local ok, err = Gaxia.Refine.Craft(player, "Bronze")
--   local jobId = Gaxia.Refine.Begin(player, "Steel")  -- timed; later Claim(jobId)
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local SharedPkg = require(ReplicatedStorage:WaitForChild("Gaxia_Packages"):WaitForChild("init")) :: any
local Signal = SharedPkg.Signal

local GaxiaServer: any = nil
local function server(): any
	if not GaxiaServer then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server"):WaitForChild("init")
		GaxiaServer = require(serverInit :: any)
	end
	return GaxiaServer
end

local JOBS_KEY : string = "RefineJobs"

export type Recipe = {
	Inputs: { [string]: number },
	Outputs: { [string]: number },
	Duration: number?,      -- seconds; >0 means it must go through Begin/Claim
	RequiresLevel: number?, -- optional level gate (checked via Gaxia.Level)
}
export type Job = { recipeId: string, completeAt: number }

local RefineService = {}

RefineService.OnCraft = Signal.new()    -- (player, recipeId, outputs)
RefineService.OnBegin = Signal.new()    -- (player, jobId, recipeId, completeAt)
RefineService.OnComplete = Signal.new() -- (player, jobId, recipeId, outputs)

local recipes: { [string]: Recipe } = {}

-- ── Recipe registry ──

function RefineService.DefineRecipe(id: string, recipe: Recipe): ()
	recipes[id] = recipe
end

function RefineService.DefineMany(defs: { [string]: Recipe }): ()
	for id, r in pairs(defs) do
		recipes[id] = r
	end
end

function RefineService.GetRecipe(id: string): Recipe?
	return recipes[id]
end

function RefineService.ListRecipes(): { string }
	local out: { string } = {}
	for id in pairs(recipes) do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

-- ── Internal: inventory + gating ──

local function meetsLevel(player: Player, recipe: Recipe): boolean
	if not recipe.RequiresLevel then
		return true
	end
	local lvl = server().Level
	if not lvl or typeof(lvl.GetLevel) ~= "function" then
		return true -- no level system wired → don't block
	end
	local ok, current = pcall(lvl.GetLevel, player)
	return (not ok) or (current >= recipe.RequiresLevel)
end

-- Verify every input is in stock, then consume them all. If any consume fails,
-- refund what was already taken so the craft is all-or-nothing.
local function consumeInputs(player: Player, recipe: Recipe): boolean
	local Item = server().Item
	for id, cnt in pairs(recipe.Inputs) do
		if not Item.Has(player, id, cnt) then
			return false
		end
	end
	local removed: { [string]: number } = {}
	for id, cnt in pairs(recipe.Inputs) do
		if Item.Remove(player, id, cnt) then
			removed[id] = cnt
		else
			for rid, rcnt in pairs(removed) do
				Item.Give(player, rid, rcnt)
			end
			return false
		end
	end
	return true
end

local function produceOutputs(player: Player, recipe: Recipe): ()
	local Item = server().Item
	for id, cnt in pairs(recipe.Outputs) do
		Item.Give(player, id, cnt)
	end
end

-- ── Instant craft ──

function RefineService.CanCraft(player: Player, recipeId: string): (boolean, string)
	local recipe = recipes[recipeId]
	if not recipe then
		return false, "unknown recipe"
	end
	if not meetsLevel(player, recipe) then
		return false, "level too low"
	end
	local Item = server().Item
	for id, cnt in pairs(recipe.Inputs) do
		if not Item.Has(player, id, cnt) then
			return false, `missing {id}`
		end
	end
	return true, "ok"
end

function RefineService.Craft(player: Player, recipeId: string): (boolean, string)
	local recipe = recipes[recipeId]
	if not recipe then
		return false, "unknown recipe"
	end
	if recipe.Duration and recipe.Duration > 0 then
		return false, "timed recipe — use Begin/Claim"
	end
	if not meetsLevel(player, recipe) then
		return false, "level too low"
	end
	if not consumeInputs(player, recipe) then
		return false, "insufficient inputs"
	end
	produceOutputs(player, recipe)
	RefineService.OnCraft:Fire(player, recipeId, recipe.Outputs)
	return true, "ok"
end

-- ── Timed Begin / Claim ──

local function loadJobs(player: Player): { [string]: any }
	local Data = server().Data
	local j = Data.Get(player, JOBS_KEY)
	return (typeof(j) == "table") and j or {}
end

local function saveJobs(player: Player, jobs: { [string]: any }): ()
	server().Data.Set(player, JOBS_KEY, jobs)
end

-- Consume inputs now, queue a timed job. Returns jobId (or nil + error).
function RefineService.Begin(player: Player, recipeId: string): (string?, string?)
	local recipe = recipes[recipeId]
	if not recipe then
		return nil, "unknown recipe"
	end
	if not recipe.Duration or recipe.Duration <= 0 then
		return nil, "instant recipe — use Craft"
	end
	if not meetsLevel(player, recipe) then
		return nil, "level too low"
	end
	if not consumeInputs(player, recipe) then
		return nil, "insufficient inputs"
	end
	local jobs = loadJobs(player)
	local seq = (tonumber(jobs.__seq) or 0) + 1
	jobs.__seq = seq
	local jobId = `job_{seq}`
	jobs[jobId] = { recipeId = recipeId, completeAt = os.time() + recipe.Duration }
	saveJobs(player, jobs)
	RefineService.OnBegin:Fire(player, jobId, recipeId, jobs[jobId].completeAt)
	return jobId, nil
end

function RefineService.GetJobs(player: Player): { [string]: Job }
	local jobs = loadJobs(player)
	local out: { [string]: Job } = {}
	for id, j in pairs(jobs) do
		if id ~= "__seq" and typeof(j) == "table" then
			out[id] = j :: Job
		end
	end
	return out
end

function RefineService.GetTimeRemaining(player: Player, jobId: string): number
	local jobs = loadJobs(player)
	local j = jobs[jobId]
	if typeof(j) ~= "table" then
		return 0
	end
	return math.max(0, j.completeAt - os.time())
end

function RefineService.IsReady(player: Player, jobId: string): boolean
	local jobs = loadJobs(player)
	local j = jobs[jobId]
	return typeof(j) == "table" and os.time() >= j.completeAt
end

-- Grant a finished job's outputs and remove it.
function RefineService.Claim(player: Player, jobId: string): (boolean, string)
	local jobs = loadJobs(player)
	local j = jobs[jobId]
	if typeof(j) ~= "table" then
		return false, "no such job"
	end
	if os.time() < j.completeAt then
		return false, "not ready"
	end
	local recipe = recipes[j.recipeId]
	if recipe then
		produceOutputs(player, recipe)
	end
	jobs[jobId] = nil
	saveJobs(player, jobs)
	RefineService.OnComplete:Fire(player, jobId, j.recipeId, recipe and recipe.Outputs or {})
	return true, "ok"
end

return RefineService
