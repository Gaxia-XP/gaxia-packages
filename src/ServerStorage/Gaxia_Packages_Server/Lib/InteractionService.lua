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

-- ── Dependencies ──
local Lifecycle = require(script.Parent.ServiceLifecycle)
local Config    = require(script.Parent.Parent.Config)
local EConfig   = require(script.Parent.EffectiveConfig)

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
	prompt.MaxActivationDistance = config.MaxDistance
		or EConfig.Get("Interaction.DefaultMaxDistance", Config.Interaction.DefaultMaxDistance or 10)
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
		-- Cast: OnTrigger returns nothing, so pcall's type would have no error value.
		local ok, err = pcall(config.OnTrigger :: (Player) -> ...any, player)
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

-- Pure API: nothing to set up. Registered so Features / IsEnabled know it.
Lifecycle.Define(InteractionService, {
	Name = "Interaction",
	Needs = {},
})

return InteractionService
