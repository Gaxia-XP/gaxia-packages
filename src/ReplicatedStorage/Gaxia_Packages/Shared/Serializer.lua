--!strict
-- ─────────────────────────────────────────────────────────────
-- Serializer.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/Serializer
-- Purpose : Encode/decode nested tables to a JSON string, round-tripping the
--           common Roblox value types (Vector3/Vector2/CFrame/Color3) that
--           plain JSON drops. Closes ReplicatedState's "scalars only" gap —
--           store a nested table as one Attribute/DataStore string and rebuild
--           it with the Roblox types intact.
--
-- Access  : Gaxia.Serializer  (shared)
--   local s = Gaxia.Serializer.Encode({ pos = Vector3.new(1,2,3), tint = Color3.new(1,0,0) })
--   local t = Gaxia.Serializer.Decode(s)   -- t.pos is a real Vector3 again
-- ─────────────────────────────────────────────────────────────
local HttpService = game:GetService("HttpService")

local Serializer = {}

-- Replace Roblox value types with tagged plain tables (recursively).
local function pack(v: any): any
	local tv = typeof(v)
	if tv == "Vector3" then
		return { __t = "Vector3", x = v.X, y = v.Y, z = v.Z }
	elseif tv == "Vector2" then
		return { __t = "Vector2", x = v.X, y = v.Y }
	elseif tv == "Color3" then
		return { __t = "Color3", r = v.R, g = v.G, b = v.B }
	elseif tv == "CFrame" then
		return { __t = "CFrame", c = { v:GetComponents() } }
	elseif tv == "table" then
		local out = {}
		for k, val in pairs(v) do
			out[k] = pack(val)
		end
		return out
	end
	-- number / string / boolean pass through unchanged.
	return v
end

-- Inverse of pack(): rebuild Roblox value types from their tagged tables.
local function unpack(v: any): any
	if typeof(v) == "table" then
		local tag = v.__t
		if tag == "Vector3" then
			return Vector3.new(v.x, v.y, v.z)
		elseif tag == "Vector2" then
			return Vector2.new(v.x, v.y)
		elseif tag == "Color3" then
			return Color3.new(v.r, v.g, v.b)
		elseif tag == "CFrame" then
			return CFrame.new(table.unpack(v.c))
		end
		local out = {}
		for k, val in pairs(v) do
			out[k] = unpack(val)
		end
		return out
	end
	return v
end

-- ── Public API ──

function Serializer.Encode(value: any): string
	return HttpService:JSONEncode(pack(value))
end

function Serializer.Decode(str: string): any
	return unpack(HttpService:JSONDecode(str))
end

-- Table form (no JSON string) — useful for an Attribute round-trip or when the
-- caller wants to do its own JSON step.
function Serializer.Pack(value: any): any
	return pack(value)
end

function Serializer.Unpack(value: any): any
	return unpack(value)
end

return Serializer
