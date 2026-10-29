--!strict
-- Config/Social.lua — Social (Party invites, Friend, Guild) tunables
return {
	Friend = {
		MaxFriends         = 200,
		MaxBlocks          = 100,
		RequestCooldownSec = 10,
		OnlineCacheSec     = 60,
		InviteQueueTTLDays = 7,
		RemoteRate         = 4,  -- Events/Friend/Action requests per second per player
		RemoteBurst        = 10, -- requests allowed at once before RemoteRate applies
	},
	Guild = {
		MaxMembers         = 50,
		MaxNameLen         = 24,
		MaxTagLen          = 4,
		MaxDescLen         = 280,
		GuildsPerPlayer    = 1,
		OfficerCap         = 5,
		VaultCapacity      = 500,
		CreateCost         = 0,
		VaultLockTTLSec    = 5,
		InviteQueueTTLDays = 7,
		RemoteRate         = 4,  -- Events/Guild/Action requests per second per player
		RemoteBurst        = 10, -- requests allowed at once before RemoteRate applies
	},
	Party = {
		InviteTTL   = 60, -- seconds; ephemeral RAM-only invites
		MaxPending  = 10, -- per target player across all parties
		RemoteRate  = 4,  -- Events/Party/InviteAction requests per second per player
		RemoteBurst = 10, -- requests allowed at once before RemoteRate applies
	},
}
