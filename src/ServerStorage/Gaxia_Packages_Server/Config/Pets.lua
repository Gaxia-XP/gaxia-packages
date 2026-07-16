--!strict
-- Config/Pets.lua — PetService tunables
-- NOTE: the pet roster (which pets exist, weights, coinBonus) lives in
-- PetService.PET_DEFS, not here.
return {
	EggCost       = 100, -- Coins charged per BasicEgg hatch
	MaxEquipSlots = 3,   -- pets equipped at once (equipped coinBonus stacks additively)
}
