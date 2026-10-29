-- Default run plus: click every button the player can click in their PlayerGui
-- (on screen, with a handler). Buttons revealed by a click (a confirm dialog)
-- are clicked in a later pass; hidden ones are skipped and listed.
-- Used by `node tools/check-playbooks.mjs --run`; also handy for your own game:
--   node tools/run-game.mjs --game <dir> --scenario tools/harness/scenarios/click-all.lua
harness.advance(2)
local p = harness.join("Player1")
harness.advance(5)
local clicked, skipped = harness.clickAll(p, 0.5)
harness.log(`clicked {#clicked} button(s)`)
if #skipped > 0 then
	harness.log(`skipped {#skipped} hidden button(s): {table.concat(skipped, ", ")}`)
end
harness.advance(5)
