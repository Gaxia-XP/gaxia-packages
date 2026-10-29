--!strict
-- Config/Player.lua — PlayerService tunables
--
-- MaxWalkSpeed: Player.SetWalkSpeed clamps to [0, MaxWalkSpeed]. Runtime override
-- via flag "Player.MaxWalkSpeed" (EConfig.Set / /flag set Player.MaxWalkSpeed 32).

export type PlayerConfig = {
	MaxWalkSpeed: number,
}

local Player: PlayerConfig = {
	MaxWalkSpeed = 500,
}

return Player
