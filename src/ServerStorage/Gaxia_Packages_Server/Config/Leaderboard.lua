--!strict
-- Config/Leaderboard.lua — LeaderboardService tunables
return {
	CacheTTL    = 60,  -- query cache TTL (s) — lower = fresher, costlier
	DefaultTopN = 100, -- default rows returned + GetRank scan depth (ranks past this → nil)
}
