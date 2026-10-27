--!strict
-- Isolated unit tests against the actual encoder implementation, not NetService.
-- All calls supply a nonce: this suite does NOT test Random or native Roblox
-- passthrough/serialization. The local runner supplies only a fail-closed Random
-- constructor shim; no production source or DataModel is modified.
return function(encoder: any): ()
	local passed = 0
	local key = 1234567
	local nonce = 7654321
	local function expect(condition: boolean, message: string): ()
		assert(condition, `[ENCODER_UNIT] FAIL: {message}`)
		passed += 1
	end
	local function rejects(callback: () -> (), fragment: string): ()
		local ok, problem = pcall(callback)
		expect(not ok, `expected rejection: {fragment}`)
		expect(
			type(problem) == "string" and string.find(problem, fragment, 1, true) ~= nil,
			`expected error containing {fragment}, got {tostring(problem)}`
		)
	end

	local input =
		table.pack("hello\0world", { number = -12.5, enabled = true, disabled = false }, nil)
	local encoded = encoder.Encode(key, input, nonce)
	local decoded = encoder.Decode(key, encoded)
	expect(decoded.n == 3 and decoded[3] == nil, "packed trailing nil preserved")
	expect(decoded[1] == input[1], "binary string roundtrip")
	expect(decoded[2].number == -12.5, "number roundtrip")
	expect(decoded[2].enabled == true and decoded[2].disabled == false, "boolean roundtrip")
	expect(input.n == 3 and input[2].number == -12.5, "input remains intact")
	expect(decoded ~= input and decoded[2] ~= input[2], "roundtrip produces independent tables")
	expect(encoder.Decode(key, encoder.Encode(key, nil, nonce)) == nil, "top-level nil roundtrip")

	local callback = function() end
	local thread = coroutine.create(callback) -- never resumed; no scheduled work
	for _, value in { callback, thread } do
		local fragment = `values of type '{typeof(value)}' cannot be sent through NetService`
		rejects(function()
			encoder.Encode(key, value, nonce)
		end, fragment)
		rejects(function()
			encoder.Encode(key, { ok = true, data = { value = value } }, nonce)
		end, fragment)
		rejects(function()
			encoder.Encode(key, { [value] = "key" }, nonce)
		end, fragment)
	end

	local cyclic: any = {}
	cyclic.self = cyclic
	rejects(function()
		encoder.Encode(key, cyclic, nonce)
	end, "cyclic tables")
	local deep: any = {}
	for _ = 1, 40 do
		deep = { child = deep }
	end
	rejects(function()
		encoder.Encode(key, deep, nonce)
	end, "maximum nesting depth")
	rejects(function()
		encoder.Encode(key, table.create(4096, true), nonce)
	end, "maximum node count")

	local padded = table.clone(encoded)
	padded[4] = "extra"
	rejects(function()
		encoder.Decode(key, padded)
	end, "invalid obfuscation envelope")
	local badNode = table.clone(encoded)
	badNode[3] = table.clone(encoded[3])
	badNode[3][3] = "extra"
	rejects(function()
		encoder.Decode(key, badNode)
	end, "invalid encoded table")
	local badNonce = table.clone(encoded)
	badNonce[2] = 0
	rejects(function()
		encoder.Decode(key, badNonce)
	end, "invalid obfuscation nonce")

	local bounded = encoder.Encode(key, string.rep("x", 129), nonce)
	rejects(function()
		encoder.Decode(key, bounded, { maxStringBytes = 128 })
	end, "maximum string size")
	local aggregate = encoder.Encode(key, { string.rep("x", 128), string.rep("x", 128) }, nonce)
	rejects(function()
		encoder.Decode(key, aggregate, { maxStringBytes = 128, maxTotalStringBytes = 200 })
	end, "total string budget")
	rejects(function()
		encoder.Decode(key, encoded, { maxNodes = 1 })
	end, "maximum node count")

	-- A failed call must not poison the next invocation's local stream/budget.
	expect(
		encoder.Decode(key, encoder.Encode(key, "after failure", nonce)) == "after failure",
		"recovery"
	)
	print(`[ENCODER_UNIT] {passed} assertions passed (unit coverage only; NOT live RPC)`)
	print("[ENCODER_UNIT]" .. " PASS")
end
