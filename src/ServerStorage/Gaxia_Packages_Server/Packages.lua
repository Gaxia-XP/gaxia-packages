--!strict
-- ─────────────────────────────────────────────────────────────
-- Packages.lua
-- Location: ServerStorage/Gaxia_Packages_Server/Packages
-- Purpose : The package catalogue: which modules make up each package, which
--           packages it needs, and whether it starts when the server boots.
--           Install only the packages a game uses:
--             • Studio: Gaxia Companion → Install tab → tick packages → Install.
--             • Rojo:   node tools/packages.mjs build --select Data,Economy --out <dir>
--           Either way, the packages you pick plus everything they Require are
--           installed, nothing else, and the pick is recorded on both package roots
--           (attribute "GaxiaPackages"). At boot the server starts every picked
--           service and every installed package that has Boot = true; any other
--           installed service starts the first time game code uses it.
--
-- Fields  : Name        loader key (GaxiaServer.<Name> / Gaxia.<Name>) and the name
--                       ServerStorage.GaxiaFeatures and the picker use
--           Category    groups the picker
--           Boot        start at server boot whenever installed, also when only
--                       because another package Requires it (it has work to do
--                       before its first call: player hooks, remotes, loops, receipts)
--           Server      module paths under Gaxia_Packages_Server
--           Replicated  module paths under ReplicatedStorage.Gaxia_Packages
--           Requires    packages this one's modules require. GENERATED from the
--                       source — run `node tools/packages.mjs fix` after changing
--                       a require; `check` fails while it is stale.
--
-- Core is always installed. Every module in the two packages belongs to Core or
-- to exactly one package (`node tools/packages.mjs check` enforces it).
-- ─────────────────────────────────────────────────────────────

local Types = require(script.Parent.Types)

local Packages: Types.PackageManifest = {
	Core = {
		Server = { "Types", "Packages", "Config", "Lib/ServiceLifecycle", "Lib/EffectiveConfig" },
		Replicated = {
			"Features", "Shared/Constants", "Shared/Logger", "Shared/NetService", "Shared/Flags",
			"Shared/ReplicatedState", "Shared/Serializer", "Shared/Signal", "Shared/Trove",
		},
	},

	-- What the framework booted before packages could be picked (Config/Features plus
	-- the client modules the bootstrap pre-warms). The picker offers it as a preset.
	Presets = {
		Default = {
			"AntiCheat", "Data", "Player", "Item", "Economy", "Pet", "Tool", "Zone", "Chat", "Admin",
			"Quest", "Achievement", "Level", "Migration", "Leaderboard", "Messages", "Ban", "Journal",
			"AntiCheatAdmin", "Webhook", "Friend", "Guild", "Input", "Camera", "Sound",
		},
	},

	Packages = {
		-- ── Data & players ───────────────────────────────────
		{
			Name = "Data", Category = "Data & players", Boot = true,
			Description = "Player save data (ProfileService): Get / Set / Save, session locking, auto-save.",
			Server = { "Lib/DataManager" },
			Requires = { "Migration", "Util" },
		},
		{
			Name = "Migration", Category = "Data & players",
			Description = "Schema versioning for saved profiles: register upgrade steps per version.",
			Server = { "Lib/DataMigration" },
			Requires = {},
		},
		{
			Name = "Player", Category = "Data & players", Boot = true,
			Description = "Player lifecycle: joined / left signals, character helpers, leaderstats.",
			Server = { "Lib/PlayerService" },
			Requires = { "Util" },
		},
		{
			Name = "Settings", Category = "Data & players", Boot = true,
			Description = "Per-player settings saved in the profile, with a client remote to read and change them.",
			Server = { "Lib/SettingsService" },
			Requires = { "Data" },
		},
		{
			Name = "Memory", Category = "Data & players",
			Description = "Cross-server short-lived storage over MemoryStoreService (sorted maps, queues).",
			Server = { "Lib/MemoryStore" },
			Requires = {},
		},
		{
			Name = "Messages", Category = "Data & players",
			Description = "Cross-server messaging over MessagingService with JSON payloads.",
			Server = { "Lib/CrossServerMessaging" },
			Requires = {},
		},
		{
			Name = "Teleport", Category = "Data & players",
			Description = "Hardened TeleportService wrapper: retries, reserved servers, teleport data.",
			Server = { "Lib/TeleportService" },
			Requires = {},
		},

		-- ── Economy & items ──────────────────────────────────
		{
			Name = "Economy", Category = "Economy & items",
			Description = "Currencies: atomic Add / Spend / Transfer backed by Data.",
			Server = { "Lib/EconomyService" },
			Requires = { "Data" },
		},
		{
			Name = "Item", Category = "Economy & items",
			Description = "Per-player item counts in the profile: Give / Remove / Has / Count.",
			Server = { "Lib/ItemService" },
			Requires = { "Data" },
		},
		{
			Name = "ItemDef", Category = "Economy & items",
			Description = "Item definition registry: what every item or decoration is.",
			Server = { "Lib/ItemDefinitionService" },
			Requires = {},
		},
		{
			Name = "Inventory", Category = "Economy & items",
			Description = "Deep inventory: unique item instances, stacks and equip slots.",
			Server = { "Lib/InventoryService" },
			Requires = { "Data" },
		},
		{
			Name = "Shop", Category = "Economy & items",
			Description = "Server-authoritative shop catalogue with soft-currency and Robux items.",
			Server = { "Lib/ShopService" },
			Requires = { "Data", "Economy", "Level", "Monetization" },
		},
		{
			Name = "Monetization", Category = "Economy & items", Boot = true,
			Description = "GamePasses and developer products with idempotent ProcessReceipt. Needed to sell developer products.",
			Server = { "Lib/MonetizationService" },
			Requires = { "Data" },
		},
		{
			Name = "Trade", Category = "Economy & items",
			Description = "Two-party, both-confirm, atomic item and currency trading.",
			Server = { "Lib/TradeService" },
			Requires = { "Economy", "Item" },
		},
		{
			Name = "Loot", Category = "Economy & items",
			Description = "Weighted drop tables with saved pity.",
			Server = { "Lib/LootService" },
			Requires = { "Codex", "Data" },
		},
		{
			Name = "Codex", Category = "Economy & items",
			Description = "Collection registry (Pokédex-style discovered / owned tracking).",
			Server = { "Lib/CodexService" },
			Requires = { "Data" },
		},
		{
			Name = "Refine", Category = "Economy & items",
			Description = "Crafting / refining recipes, checked on the server.",
			Server = { "Lib/RefineService" },
			Requires = { "Data", "Item", "Level" },
		},
		{
			Name = "Vault", Category = "Economy & items",
			Description = "Capacity-bounded secure storage (a bank).",
			Server = { "Lib/VaultService" },
			Requires = { "Data", "Item" },
		},
		{
			Name = "DailyReward", Category = "Economy & items",
			Description = "Login-streak daily rewards.",
			Server = { "Lib/DailyRewardService" },
			Requires = { "Data" },
		},
		{
			Name = "Mail", Category = "Economy & items",
			Description = "Saved player inbox with claimable reward attachments.",
			Server = { "Lib/MailService" },
			Requires = { "Data" },
		},

		-- ── Progression & live ops ───────────────────────────
		{
			Name = "Level", Category = "Progression & live ops",
			Description = "XP and levels saved in the profile.",
			Server = { "Lib/LevelSystem" },
			Requires = { "Data" },
		},
		{
			Name = "Quest", Category = "Progression & live ops",
			Description = "Quest registry with per-player progress and rewards.",
			Server = { "Lib/QuestSystem" },
			Requires = { "Data", "Economy", "Item" },
		},
		{
			Name = "Achievement", Category = "Progression & live ops",
			Description = "Achievement registry with saved unlocks.",
			Server = { "Lib/AchievementSystem" },
			Requires = { "Data", "Economy" },
		},
		{
			Name = "Leaderboard", Category = "Progression & live ops",
			Description = "Global top-N boards over OrderedDataStore.",
			Server = { "Lib/LeaderboardService" },
			Requires = {},
		},
		{
			Name = "Event", Category = "Progression & live ops", Boot = true,
			Description = "Timed live-ops events (start / end windows) with a scheduler loop.",
			Server = { "Lib/EventService" },
			Requires = {},
		},
		{
			Name = "Analytics", Category = "Progression & live ops", Boot = true,
			Description = "Typed event funnel: Economy / Level / Quest events routed to one sink.",
			Server = { "Lib/AnalyticsService" },
			Requires = {},
		},
		{
			Name = "Idle", Category = "Progression & live ops", Boot = true,
			Description = "Passive and offline earnings (idle / tycoon loop).",
			Server = { "Lib/IdleService" },
			Requires = { "Data", "Economy" },
		},

		-- ── Gameplay & world ─────────────────────────────────
		{
			Name = "Tool", Category = "Gameplay & world",
			Description = "Tool lifecycle helpers with anti-duplication UIDs.",
			Server = { "Lib/ToolService" },
			Requires = {},
		},
		{
			Name = "Zone", Category = "Gameplay & world",
			Description = "Trigger zones with Enter / Left signals.",
			Server = { "Lib/ZoneService" },
			Requires = {},
		},
		{
			Name = "Cooldown", Category = "Gameplay & world", Boot = true,
			Description = "Server-authoritative cooldowns and debounces (with a sweep loop).",
			Server = { "Lib/CooldownService" },
			Requires = {},
		},
		{
			Name = "Interaction", Category = "Gameplay & world",
			Description = "ProximityPrompt wrapper for \"press E to …\" interactions.",
			Server = { "Lib/InteractionService" },
			Requires = {},
		},
		{
			Name = "Placement", Category = "Gameplay & world", Boot = true,
			Description = "Grid building placement for tycoons, base builders and farms.",
			Server = { "Lib/PlacementService" },
			Requires = { "Data" },
		},
		{
			Name = "Visit", Category = "Gameplay & world", Boot = true,
			Description = "Read-only base / island visiting.",
			Server = { "Lib/VisitService" },
			Requires = {},
		},
		{
			Name = "Protection", Category = "Gameplay & world",
			Description = "Time-boxed shields (\"you can't be raided right now\").",
			Server = { "Lib/ProtectionService" },
			Requires = { "Data" },
		},
		{
			Name = "Raid", Category = "Gameplay & world",
			Description = "Raid / heist state machine.",
			Server = { "Lib/RaidService" },
			Requires = { "Cooldown", "Data", "Economy", "Protection", "Vault" },
		},
		{
			Name = "AI", Category = "Gameplay & world",
			Description = "NPC movement over PathfindingService.",
			Server = { "Lib/AIService" },
			Requires = {},
		},
		{
			Name = "Pet", Category = "Gameplay & world", Boot = true,
			Description = "Stat-boost pets: hatch from eggs, equip, client pet panel (P key).",
			Server = { "Lib/PetService" },
			Replicated = { "Client/UI/PetController" },
			Requires = { "Codex", "Data", "Economy", "Guard", "ItemDef", "Loot", "UI.Toast", "UI.UIController" },
		},

		-- ── Effects ──────────────────────────────────────────
		{
			Name = "VFX", Category = "Effects",
			Description = "Pooled visual-effect registry.",
			Server = { "Lib/VFXService" },
			Requires = { "Pool" },
		},
		{
			Name = "SFX", Category = "Effects",
			Description = "Sound bank and 3D audio.",
			Server = { "Lib/SFXService" },
			Requires = {},
		},
		{
			Name = "Anim", Category = "Effects",
			Description = "Named animation playback over Animator.",
			Server = { "Lib/AnimationService" },
			Requires = {},
		},
		{
			Name = "Motion3D", Category = "Effects",
			Description = "World motion: moving platforms, bobbing collectibles, spinners.",
			Server = { "Lib/Motion3DService" },
			Requires = {},
		},
		{
			Name = "Ragdoll", Category = "Effects",
			Description = "Toggle a character into a physics ragdoll and back.",
			Server = { "Lib/RagdollService" },
			Requires = {},
		},

		-- ── Social ───────────────────────────────────────────
		{
			Name = "Friend", Category = "Social", Boot = true,
			Description = "In-game friends and blocks, with invites and a client friend list.",
			Server = { "Lib/FriendService" },
			Replicated = { "Client/UI/FriendListPanel" },
			Requires = { "Cooldown", "Data", "InviteQueue", "Theme" },
		},
		{
			Name = "Guild", Category = "Social", Boot = true,
			Description = "Saved guilds with cross-server sync and a client guild panel.",
			Server = { "Lib/GuildService" },
			Replicated = { "Client/UI/GuildPanel" },
			Requires = { "Data", "Friend", "GuildLock", "InviteQueue", "Messages", "Theme" },
		},
		{
			Name = "GuildLock", Category = "Social",
			Description = "Cross-server lock for guild record changes.",
			Server = { "Lib/GuildLock" },
			Requires = {},
		},
		{
			Name = "InviteQueue", Category = "Social",
			Description = "Durable cross-server invite delivery.",
			Server = { "Lib/InviteQueue" },
			Requires = {},
		},
		{
			Name = "Party", Category = "Social", Boot = true,
			Description = "Parties and matchmaking for co-op and lobby flows.",
			Server = { "Lib/PartyService" },
			Requires = { "Friend", "InviteQueue", "Memory", "Teleport" },
		},

		-- ── Moderation & safety ──────────────────────────────
		{
			Name = "AntiCheat", Category = "Moderation & safety", Boot = true,
			Description = "Server-side cheat detectors plus the client-side checks (observe mode by default).",
			Server = { "AntiCheat" },
			Replicated = { "Client/ClientAntiCheat" },
			Requires = { "Tool" },
		},
		{
			Name = "Journal", Category = "Moderation & safety", Boot = true,
			Description = "Records AntiCheat flags and actions (ring buffer, optional sink).",
			Server = { "Lib/AntiCheatJournal" },
			Requires = { "AntiCheat" },
		},
		{
			Name = "Ban", Category = "Moderation & safety", Boot = true,
			Description = "Saved bans and an auto-escalation policy for AntiCheat actions.",
			Server = { "Lib/BanService" },
			Requires = {},
		},
		{
			Name = "Chat", Category = "Moderation & safety", Boot = true,
			Description = "Slash-command chat parser with typed arguments, and client replies.",
			Server = { "Lib/ChatCommandSystem" },
			Replicated = { "Client/ChatFeedback" },
			Requires = {},
		},
		{
			Name = "Admin", Category = "Moderation & safety", Boot = true,
			Description = "Role-gated admin commands and the in-game admin panel (F2).",
			Server = { "Lib/AdminCommands" },
			Replicated = { "Client/UI/AdminPanel" },
			Requires = { "Ban", "Chat", "Player", "Theme", "UI.Components", "UI.Toast" },
		},
		{
			Name = "AntiCheatAdmin", Category = "Moderation & safety", Boot = true,
			Description = "Moderator AntiCheat commands: /acflags /acclear /acban /acunban /ac /flag.",
			Server = { "Lib/AntiCheatAdmin" },
			Requires = { "Admin", "AntiCheat", "Ban", "Journal" },
		},
		{
			Name = "Webhook", Category = "Moderation & safety", Boot = true,
			Description = "Outbound webhooks (Discord-first) for bans, AntiCheat and guild events.",
			Server = { "Lib/WebhookService" },
			Requires = {},
		},

		-- ── Client systems ───────────────────────────────────
		{
			Name = "Input", Category = "Client systems",
			Description = "Keybinds for keyboard, mouse and gamepad, with rebinding.",
			Replicated = { "Client/InputManager" },
			Requires = {},
		},
		{
			Name = "Camera", Category = "Client systems",
			Description = "Camera shake and FOV tweens.",
			Replicated = { "Client/CameraController" },
			Requires = {},
		},
		{
			Name = "Sound", Category = "Client systems",
			Description = "Pooled sound playback with a 3-bus mixer.",
			Replicated = { "Client/SoundController" },
			Requires = {},
		},
		{
			Name = "Effects", Category = "Client systems",
			Description = "Pooled particle / beam / trail bursts.",
			Replicated = { "Client/EffectsController" },
			Requires = {},
		},
		{
			Name = "Dialog", Category = "Client systems",
			Description = "Branching NPC dialog with typewriter text and choices.",
			Replicated = { "Client/DialogSystem" },
			Requires = { "Promise" },
		},
		{
			Name = "Cutscene", Category = "Client systems",
			Description = "Sequenced cutscenes: camera tweens, dialog, fades.",
			Replicated = { "Client/CutsceneSystem" },
			Requires = { "Dialog", "Promise" },
		},
		{
			Name = "Tooltip", Category = "Client systems",
			Description = "Hover tooltips with delay and cursor follow.",
			Replicated = { "Client/TooltipSystem" },
			Requires = {},
		},
		{
			Name = "DebugConsole", Category = "Client systems",
			Description = "On-screen developer overlay (F3).",
			Replicated = { "Client/DebugConsole" },
			Requires = {},
		},

		-- ── Client UI ────────────────────────────────────────
		{
			Name = "UI.UIController", Category = "Client UI",
			Description = "Central UI manager that builds the Gaxia templates.",
			Replicated = { "Client/UI/UIController" },
			Requires = { "UI.Templates" },
		},
		{
			Name = "UI.Templates", Category = "Client UI",
			Description = "Code-first builders for the Gaxia UI templates.",
			Replicated = { "Client/UI/Templates" },
			Requires = {},
		},
		{
			Name = "UI.NotificationService", Category = "Client UI",
			Description = "Template-based notifications.",
			Replicated = { "Client/UI/NotificationService" },
			Requires = { "UI.UIController" },
		},
		{
			Name = "UI.Toast", Category = "Client UI",
			Description = "Toast notifications with a FIFO queue.",
			Replicated = { "Client/UI/Toast" },
			Requires = { "Theme" },
		},
		{
			Name = "UI.HUDController", Category = "Client UI",
			Description = "HUD text labels (timers, score).",
			Replicated = { "Client/UI/HUDController" },
			Requires = { "UI.UIController" },
		},
		{
			Name = "UI.HealthBarController", Category = "Client UI",
			Description = "Tweened health bars for any Humanoid.",
			Replicated = { "Client/UI/HealthBarController" },
			Requires = { "UI.UIController" },
		},
		{
			Name = "UI.MenuController", Category = "Client UI",
			Description = "Open / close modal menus.",
			Replicated = { "Client/UI/MenuController" },
			Requires = { "UI.UIController" },
		},
		{
			Name = "UI.InventoryController", Category = "Client UI",
			Description = "Grid inventory screen.",
			Replicated = { "Client/UI/InventoryController" },
			Requires = { "UI.UIController" },
		},
		{
			Name = "UI.LoadingScreenController", Category = "Client UI",
			Description = "Loading screen with progress.",
			Replicated = { "Client/UI/LoadingScreenController" },
			Requires = { "UI.UIController" },
		},
		{
			Name = "UI.StateBinding", Category = "Client UI",
			Description = "Bind a GUI property to a ReplicatedState key.",
			Replicated = { "Client/UI/StateBinding" },
			Requires = {},
		},
		{
			Name = "UI.Responsive", Category = "Client UI",
			Description = "Fit UI to phones, tablets, console and desktop.",
			Replicated = { "Client/UI/Responsive" },
			Requires = {},
		},
		{
			Name = "UI.Router", Category = "Client UI",
			Description = "Screen stack navigation and z-ordering.",
			Replicated = { "Client/UI/Router" },
			Requires = {},
		},
		{
			Name = "UI.Components", Category = "Client UI",
			Description = "Themed widget kit: buttons, toggles, sliders, lists.",
			Replicated = { "Client/UI/Components" },
			Requires = { "Theme" },
		},
		{
			Name = "UI.GamepadNav", Category = "Client UI",
			Description = "Gamepad / console navigation for screens.",
			Replicated = { "Client/UI/GamepadNav" },
			Requires = {},
		},
		{
			Name = "UI.RebindMenu", Category = "Client UI",
			Description = "Settings screen for rebinding Input keys.",
			Replicated = { "Client/UI/RebindMenu" },
			Requires = { "Input", "Theme", "UI.Components" },
		},
		{
			Name = "UI.Accessibility", Category = "Client UI",
			Description = "Accessibility preferences (colour, text size, motion).",
			Replicated = { "Client/UI/Accessibility" },
			Requires = { "Theme" },
		},
		{
			Name = "UI.Haptics", Category = "Client UI",
			Description = "Gamepad rumble feedback.",
			Replicated = { "Client/UI/Haptics" },
			Requires = {},
		},
		{
			Name = "UI.Motion", Category = "Client UI",
			Description = "UI motion presets over TweenService.",
			Replicated = { "Client/UI/Motion" },
			Requires = {},
		},
		{
			Name = "UI.InviteToast", Category = "Client UI",
			Description = "Shows Friend / Guild / Party invites as toasts.",
			Replicated = { "Client/UI/InviteToast" },
			Requires = { "UI.Toast" },
		},

		-- ── Shared utilities ─────────────────────────────────
		{
			Name = "Promise", Category = "Shared utilities",
			Description = "Promises (evaera) with typed wrappers.",
			Replicated = { "Shared/Promise", "Shared/PromiseTypes" },
			Requires = {},
		},
		{
			Name = "Util", Category = "Shared utilities",
			Description = "Table / String / Math / Instance / Player / Debug helpers.",
			Replicated = { "Shared/Util" },
			Requires = {},
		},
		{
			Name = "TweenUtil", Category = "Shared utilities",
			Description = "TweenService presets and promise-based tweens.",
			Replicated = { "Shared/TweenUtil" },
			Requires = { "Promise" },
		},
		{
			Name = "Spring", Category = "Shared utilities",
			Description = "Damped springs for smooth motion.",
			Replicated = { "Shared/Spring" },
			Requires = {},
		},
		{
			Name = "Raycaster", Category = "Shared utilities",
			Description = "Builder-style RaycastParams wrapper.",
			Replicated = { "Shared/Raycaster" },
			Requires = {},
		},
		{
			Name = "Random", Category = "Shared utilities",
			Description = "Seeded RNG streams, weighted choice, shuffle.",
			Replicated = { "Shared/Random" },
			Requires = {},
		},
		{
			Name = "Pool", Category = "Shared utilities",
			Description = "Object pool for reusable instances.",
			Replicated = { "Shared/Pool" },
			Requires = {},
		},
		{
			Name = "Scheduler", Category = "Shared utilities",
			Description = "After / Every / Debounce / Throttle / Stopwatch.",
			Replicated = { "Shared/Scheduler" },
			Requires = {},
		},
		{
			Name = "Guard", Category = "Shared utilities",
			Description = "Runtime schema validation (t-style).",
			Replicated = { "Shared/Guard" },
			Requires = {},
		},
		{
			Name = "Symbol", Category = "Shared utilities",
			Description = "Unique reference-comparable identifiers.",
			Replicated = { "Shared/Symbol" },
			Requires = {},
		},
		{
			Name = "Component", Category = "Shared utilities",
			Description = "Bind behaviour classes to CollectionService tags.",
			Replicated = { "Shared/Component" },
			Requires = { "Promise", "Symbol" },
		},
		{
			Name = "Command", Category = "Shared utilities",
			Description = "Command pattern over NetService remotes.",
			Replicated = { "Shared/Command" },
			Requires = {},
		},
		{
			Name = "Theme", Category = "Shared utilities",
			Description = "UI design tokens (colour, font, spacing, radius).",
			Replicated = { "Shared/Theme" },
			Requires = {},
		},
		{
			Name = "Localization", Category = "Shared utilities",
			Description = "One place every user-facing string goes through (i18n).",
			Replicated = { "Shared/Localization" },
			Requires = {},
		},
		{
			Name = "GuiCodec", Category = "Shared utilities",
			Description = "Convert GUI instances to code and back.",
			Replicated = { "Shared/GuiCodec" },
			Requires = {},
		},
		{
			Name = "Perf", Category = "Shared utilities",
			Description = "FPS, memory and ping readings.",
			Replicated = { "Shared/PerformanceMonitor" },
			Requires = {},
		},
		{
			Name = "Bench", Category = "Shared utilities",
			Description = "Microbenchmarks.",
			Replicated = { "Shared/PerformanceBenchmark" },
			Requires = {},
		},
		{
			Name = "TestRunner", Category = "Shared utilities",
			Description = "Minimal in-game test framework.",
			Replicated = { "Shared/TestRunner" },
			Requires = {},
		},
		{
			Name = "MockPlayer", Category = "Shared utilities",
			Description = "Fake Player objects for tests.",
			Replicated = { "Shared/MockPlayer" },
			Requires = {},
		},

		-- ── Deprecated ───────────────────────────────────────
		{
			Name = "Maid", Category = "Deprecated",
			Description = "Deprecated: use Trove (always installed).",
			Replicated = { "Shared/Maid" },
			Requires = {},
		},
		{
			Name = "Janitor", Category = "Deprecated",
			Description = "Deprecated: use Trove (always installed).",
			Replicated = { "Shared/Janitor" },
			Requires = { "Promise" },
		},
		{
			Name = "ComponentLegacy", Category = "Deprecated",
			Description = "Deprecated: use Component.",
			Replicated = { "Shared/ComponentLegacy" },
			Requires = {},
		},
	},
}

return Packages
