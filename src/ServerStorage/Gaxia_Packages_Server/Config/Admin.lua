--!strict
-- Config/Admin.lua — Admin / moderation (AdminCommands + ChatCommandSystem)
--
-- Bootstrap: group-owned places have no creator auto-grant (CreatorId = group),
-- so seed initial admins here rather than shipping with zero admins.
export type AdminConfig = {
	Enabled: boolean,
	CommandPrefix: string,
	AutoGrantCreator: boolean,
	-- Role name -> tier; a higher tier includes every lower one.
	Tiers: { [string]: number },
	-- UserId -> role name.
	Bootstrap: { [number]: string },
	-- Alias -> command name.
	Aliases: { [string]: string },
	Disabled: { string },
	Stores: {
		Bans: string,
		Friends: string,
		Guilds: string,
		GuildVaults: string,
		Roles: string,
	},
	ActionWhitelistSeconds: number,
	BanListLimit: number,
}

local Admin: AdminConfig = {
	Enabled          = true,
	CommandPrefix    = "/",
	AutoGrantCreator = true,
	Tiers = { default = 0, moderator = 1, admin = 2, owner = 3 },

	-- Seed roles by UserId (in-memory, re-applied each boot — NOT persisted)
	Bootstrap = {
		-- [123456789] = "owner",
	},

	Aliases = {
		sp = "speed", tp = "teleport",
	},

	-- Commands listed here are still registered but rejected at Run time
	Disabled = {
		-- "give",
	},

	Stores = {
		Bans        = "GaxiaBans",
		Friends     = "GaxiaFriends",
		Guilds      = "GaxiaGuilds",
		GuildVaults = "GaxiaGuildVaults",
		Roles       = "GaxiaRoles",
	},

	-- Wider window = fewer false anti-cheat flags during /tp, but bigger exposure if account is compromised
	ActionWhitelistSeconds = 30,
	BanListLimit           = 50,
}

return Admin
