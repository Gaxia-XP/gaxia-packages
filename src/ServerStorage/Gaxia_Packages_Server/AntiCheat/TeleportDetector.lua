--!strict
--[[
	Module : TeleportDetector
	Location: ServerStorage.Gaxia_Packages_Server.AntiCheat.TeleportDetector
	Purpose : Flags HRP position deltas larger than TELEPORT_MAX_DELTA between
	          consecutive samples. Ignores ticks where the character re-spawned.
	          Seats: "seated" means Humanoid.SeatPart is set (the server creates
	          the seat weld, so a client cannot fake that the player sits). That
	          does NOT prove the seat moved the player, so a seat is only skipped
	          when the SERVER simulates it (unanchored, GetNetworkOwner() == nil).
	          An anchored seat is checked like walking (it cannot carry anyone).
	          A client-owned seat (an unanchored Seat/VehicleSeat gives its
	          occupant network ownership, so that client can move it anywhere) is
	          checked with the allowance raised by the seat's own speed: MaxDelta
	          + speed * dt * 2. The sample after leaving a seat is compared with
	          the last seated position (allowance from the seat's last speed), so
	          sit / jump off / teleport is flagged. Limit: a client that owns its
	          seat also sets that seat's velocity.
	          The Seated state and Humanoid.Sit are NOT trusted (the owning client
	          sets them, so an exploiter could switch to Seated and teleport).
	          While falling (Freefall now or on the previous sample) downward
	          movement is ignored: a long drop is legitimate. The sideways and
	          upward parts still count, because the client also sets Freefall.
]]

-- ── Dependencies ──
local Types  = require(script.Parent.Parent.Types)
local Config = require(script.Parent.Parent.Config)

-- ── Types ──
type Snapshot = Types.AntiCheatSnapshot
type Flag = Types.AntiCheatFlag

local TeleportCfg = Config.AntiCheat.Teleport

local TELEPORT_MAX_DELTA : number = TeleportCfg.MaxDelta or 50
local TELEPORT_SEVERITY  : string = TeleportCfg.Severity or "hard"

local FREEFALL = Enum.HumanoidStateType.Freefall
-- A client-owned seat may carry the player this many times its sampled speed
-- per second between two samples (speed changes between the samples).
local SEAT_SPEED_SLACK : number = 2

-- (userId) → last sample — clears on respawn so a legitimate Teleport-on-spawn
-- does not register as cheating.
type Last = { pos: Vector3, character: Model, clock: number, seatSpeed: number, falling: boolean }
local lastSnapshot: { [number]: Last } = {}

local TeleportDetector = {}
TeleportDetector.Name = "Teleport"

-- Server-confirmed seat only: SeatPart is set by the seat weld the server makes.
-- The Seated state and Humanoid.Sit come from the owning client and are spoofable.
-- Returns (serverMoved, seatSpeed): serverMoved = the server simulates the seat,
-- so its movement is trusted; seatSpeed = how fast the seat's assembly moves (0
-- when not seated or the seat is anchored).
local function seatInfo(snapshot: Snapshot): (boolean, number)
	local humanoid = snapshot.humanoid
	local seat = if humanoid then humanoid.SeatPart else nil
	if not seat then return false, 0 end
	local root = seat.AssemblyRootPart or seat
	if root.Anchored then
		-- An anchored seat does not move: check the player like a walker.
		return false, 0
	end
	local speed = seat.AssemblyLinearVelocity.Magnitude
	-- GetNetworkOwner errors outside Workspace; that seat is not trusted.
	local ok, owner = pcall(seat.GetNetworkOwner, seat)
	if ok and owner == nil then
		return true, speed
	end
	-- Client-owned: the occupant's client simulates (and can move) the seat.
	return false, speed
end

function TeleportDetector.Sample(player: Player, snapshot: Snapshot): Flag?
	local pos = snapshot.position
	local character = snapshot.character
	if not pos or not character then
		lastSnapshot[player.UserId] = nil
		return nil
	end

	local serverMoved, seatSpeed = seatInfo(snapshot)
	local falling = snapshot.state == FREEFALL
	local clock = snapshot.clock
	local prev = lastSnapshot[player.UserId]
	-- Always update the last snapshot before returning so a flagged tick still
	-- anchors the next comparison (otherwise dual-teleport would be missed). It is
	-- also updated on seated ticks, so the sample after leaving a seat is compared
	-- with the last seated position.
	lastSnapshot[player.UserId] = { pos = pos, character = character, clock = clock, seatSpeed = seatSpeed, falling = falling }

	if not prev then return nil end
	-- Character respawned: a different Model means we lost continuity; skip this tick.
	if prev.character ~= character then return nil end
	-- A server-simulated seat (vehicle, moving seat) carries the character.
	if serverMoved then return nil end

	-- A seat (now, or the one just left) may carry the player at its own speed.
	local dt = math.max(clock - prev.clock, 0)
	local maxDelta = TELEPORT_MAX_DELTA + math.max(seatSpeed, prev.seatSpeed) * dt * SEAT_SPEED_SLACK

	local move = pos - prev.pos
	if falling or prev.falling then
		-- A fall (or its landing) moves the character down fast: ignore the
		-- downward part. Freefall is client-set, so sideways and upward moves
		-- still count.
		move = Vector3.new(move.X, math.max(move.Y, 0), move.Z)
	end
	if move.Magnitude > maxDelta then
		-- Teleport is "hard" right away — there is no benign reason for a
		-- 50+ stud single-tick jump under normal physics.
		return { reason = "Teleport", severity = TELEPORT_SEVERITY }
	end
	return nil
end

return TeleportDetector
