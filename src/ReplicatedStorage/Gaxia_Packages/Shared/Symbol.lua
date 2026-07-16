--!strict
-- ============================================================
-- Symbol (ModuleScript)
-- Location : ReplicatedStorage/Gaxia_Packages/Shared/Symbol
-- Purpose  : Unique identifier type comparable by reference
--            only (similar to JavaScript Symbol). Two calls
--            with the same name still produce distinct values.
-- ============================================================

-- ── Types ────────────────────────────────────────────────────

export type Symbol = {
	_name : string,
}

-- ── Metatable ────────────────────────────────────────────────

-- Single shared metatable — each symbol stays unique because the *table*
-- identity is unique, not the metatable identity
local SymbolMeta = {
	-- Produce a readable description without leaking internal equality
	__tostring = function(self: Symbol): string
		if self._name ~= "" then
			return `Symbol({self._name})`
		end
		return "Symbol()"
	end,
}

-- ── Module ───────────────────────────────────────────────────

local SymbolModule = {}

--- Create a new unique symbol with an optional human-readable name.
--- The name is purely for debugging — two Symbol("Foo") calls are NOT equal.
function SymbolModule.new(name: string?): Symbol
	local sym : Symbol = setmetatable({
		_name = name or "",
	}, SymbolMeta) :: any
	return sym
end

-- ── Callable Wrapper ─────────────────────────────────────────

-- Wrap the module table so callers can write either:
--   Symbol("Name")        (callable form, JS-like)
--   Symbol.new("Name")    (explicit constructor)
local SymbolCallable = setmetatable(SymbolModule, {
	__call = function(_self: any, name: string?): Symbol
		return SymbolModule.new(name)
	end,
})

return SymbolCallable
