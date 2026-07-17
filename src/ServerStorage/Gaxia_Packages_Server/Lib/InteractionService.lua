--!strict
-- ─────────────────────────────────────────────────────────────
-- InteractionService.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Lib/InteractionService
-- Purpose : ProximityPrompt wrapper — the standard "press E to X" interaction
--           primitive (shops, NPCs, vault stations, pickups). Mounts a prompt
--           on a part/model, wires Triggered → OnTrigger server-side with an
--           optional per-player cooldown, and hands back a Destroy()able handle.
--
-- Access  : Gaxia.Interaction  (server)
--   Gaxia.Interaction.Register(stationModel, {
--     ActionText = "Refine", ObjectText = "Sunwell", HoldDuration = 0.5, Cooldown = 1,
--     OnTrigger = function(player) refine(player) end,
--   })
-- ─────────────────────────────────────────────────────────────
local CollectionService = game:GetService("CollectionService")

local ServerStorage = game:GetService("ServerStorage")

-- ── Lazy server (Config + EConfig) ──
local _server: any = nil
local function server(): any
	if not _server then
		-- Instance-typed local + `:: any` so luau-lsp does not follow this require
		-- back into the loader (false-positive cyclic dep; see IdleService for the why).
		local serverInit: Instance = ServerStorage:WaitForChild("Gaxia_Packages_Server")
		_server = require(serverInit :: any)
	end
	return _server
end

export type InteractionConfig = {
	ActionText: string?,
	ObjectText: string?,
	HoldDuration: number?,
	MaxDistance: number?,
	RequiresLineOfSight: boolean?,
	KeyboardKeyCode: Enum.KeyCode?,
	Cooldown: number?,                 -- per-player debounce (seconds)
	OnTrigger: (player: Player) -> (),
}

export type Handle = {
	Prompt: ProximityPrompt,
	Destroy: () -> (),
}

local InteractionService = {}

-- Resolve a BasePart/Attachment to mount the prompt on.
local function resolveMount(target: Instance): Instance?
	if target:IsA("BasePart") or target:IsA("Attachment") then
		return target
	end
	if target:IsA("Model") then
		return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart")
	end
	return nil
end

function InteractionService.Register(target: Instance, config: InteractionConfig): Handle?
	local mount = resolveMount(target)
	if not mount then
		warn(`[InteractionService] cannot mount a prompt on {target:GetFullName()} — need a BasePart/Attachment/Model-with-parts`)
		return nil
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = config.ActionText or "Interact"
	prompt.ObjectText = config.ObjectText or ""
	prompt.HoldDuration = config.HoldDuration or 0
	local s = server()
	prompt.MaxActivationDistance = config.MaxDistance
		or s.EConfig.Get("Interaction.DefaultMaxDistance", (s.Config.Interaction or {}).DefaultMaxDistance or 10)
	prompt.RequiresLineOfSight = if config.RequiresLineOfSight == nil then false else config.RequiresLineOfSight
	if config.KeyboardKeyCode then
		prompt.KeyboardKeyCode = config.KeyboardKeyCode
	end
	prompt.Parent = mount

	local lastUse: { [Player]: number } = {}
	local cooldown = config.Cooldown

	local conn = prompt.Triggered:Connect(function(player: Player)
		if cooldown then
			local now = os.clock()
			local last = lastUse[player]
			if last and (now - last) < cooldown then
				return
			end
			lastUse[player] = now
		end
		local ok, err = pcall(config.OnTrigger, player)
		if not ok then
			warn(`[InteractionService] OnTrigger errored: {err}`)
		end
	end)

	local handle = {}
	handle.Prompt = prompt
	function handle.Destroy(): ()
		conn:Disconnect()
		prompt:Destroy()
	end
	return handle :: Handle
end

return InteractionService
