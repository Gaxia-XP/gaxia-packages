-- Default run plus: click every button the player's PlayerGui has a handler on.
-- Used by `node tools/check-playbooks.mjs --run`; also handy for your own game:
--   node tools/run-game.mjs --game <dir> --scenario tools/harness/scenarios/click-all.lua
harness.advance(2)
local p = harness.join("Player1")
harness.advance(5)
local clicked = harness.clickAll(p, 0.5)
harness.log(`clicked {#clicked} button(s)`)
harness.advance(5)
