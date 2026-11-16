--!optimize 1
-- Ripple test suite. Run from the repo root:
--   lune run src/init.luau -- tests/schema.ripple --out tests/gen
--   bench/host/build/luau-bench tests/run.luau
local function import(path, ...)
	return assert(loadstring(readfile(path), "@" .. path))(...)
end
local ROOT = arg[1] or "."
local Mock = import(ROOT .. "/bench/lib/mock.luau")
Mock.installGlobals()
local world = Mock.newWorld()
local players = {}
for i = 1, 3 do
	players[i] = world:addPlayer()
end
local R = world.server:requireFile(ROOT .. "/tests/gen/Server.luau")
local C = {}
for i = 1, 3 do
	C[i] = world.clients[i]:requireFile(ROOT .. "/tests/gen/Client.luau")
end

local function step()
	world:stepServer(1 / 30)
	for i = 1, #world.clients do
		world:stepClient(i, 1 / 30)
	end
	world:deliver()
	for i = 1, #world.clients do
		world:receiveClient(i)
	end
	world:receiveServer()
end

local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		passed += 1
		print("ok    " .. name)
	else
		failed += 1
		print("FAIL  " .. name .. "\n" .. tostring(err))
	end
end

local SERVER_ONLY = { Secret = true, Log = true }

local function deepEq(a, b, path, skipTop)
	if type(a) ~= type(b) then
		error(`{path}: type {type(a)} vs {type(b)} ({tostring(a)} vs {tostring(b)})`, 0)
	end
	if type(a) == "buffer" then
		if buffer.tostring(a) ~= buffer.tostring(b) then
			error(`{path}: buffers differ`, 0)
		end
		return
	end
	if typeof(a) == "Vector3" then
		if (a - b).Magnitude > 1e-3 then
			error(`{path}: {a} vs {b}`, 0)
		end
		return
	end
	if type(a) ~= "table" then
		if a ~= b and not (a ~= a and b ~= b) then
			error(`{path}: {tostring(a)} vs {tostring(b)}`, 0)
		end
		return
	end
	for k, v in a do
		if skipTop and SERVER_ONLY[k] then
			continue
		end
		deepEq(v, b[k], `{path}.{tostring(k)}`)
	end
	for k, v in b do
		if skipTop and SERVER_ONLY[k] then
			continue
		end
		if a[k] == nil then
			error(`{path}.{tostring(k)}: missing on the expected side (got {tostring(v)})`, 0)
		end
	end
end

local function bigData()
	local d = {}
	for i = 1, 40 do
		d["F" .. i] = i
	end
	d.Name = "club"
	d.Phase = "Lobby"
	d.Inv = { [1] = { Id = 1, Count = 2 }, [2] = { Id = 2, Count = 3, Tag = "x" } }
	d.Bag = { { Id = 9, Count = 1 } }
	d.Tags = { "a", "b" }
	d.Extra = { nested = { 1, 2, 3 }, flag = true, n = -5, f = 0.5 }
	d.Secret = "hidden"
	d.Log = { a = 1 }
	d.Nested = { x = { y = 1 } }
	d.Huge = 2 ^ 40
	d.Neg = -123456
	d.Ratio = 0.25
	d.Flag = false
	d.Blob = buffer.fromstring("blob")
	return d
end

local big
test("create replicates a full snapshot to the owner only", function()
	big = R.Big.new(players[1], bigData())
	step()
	local got = C[1].Big.get()
	assert(got, "owner has no Big")
	deepEq(R.raw(big), got, "Big", true)
	assert(got.Secret == nil and got.Log == nil, "server-only fields leaked to the client")
	assert(C[2].Big.get(players[1]) == nil, "another player received a private state")
	assert(C[2].Big.get() == nil)
end)

test("writes replicate as deltas", function()
	big.F1 = 200
	big.F40 = 7
	big.Name = "renamed"
	big.Phase = "Playing"
	big.Pos = Vector3.new(1, 2, 3)
	big.Inv[5] = { Id = 5, Count = 1 }
	big.Inv[1].Count = 99
	big.Inv[2] = nil
	big.Nested.x.z = -4
	big.Nested.w = { q = 1 }
	big.Extra.nested[4] = 4
	big.Extra.flag = nil
	big.Huge += 1
	big.Opt = { Id = 3, Count = 3 }
	step()
	deepEq(R.raw(big), C[1].Big.get(), "Big", true)
end)

test("server-only fields: tracked for saving, never sent", function()
	R.clearDirty(big)
	step()
	local before = world.stats.s2cBytes
	big.Secret = "changed"
	big.Log.b = 2
	assert(R.isDirty(big), "isDirty after a server-only write")
	step()
	assert(world.stats.s2cBytes == before, "a server-only change sent bytes")
	R.clearDirty(big)
	assert(not R.isDirty(big))
	big.Log.c = 3
	assert(R.isDirty(big), "isDirty after a second server-only write")
end)

test("validation errors point at the bad write", function()
	local function bad(fn, pattern)
		local ok, err = pcall(fn)
		assert(not ok, "expected an error matching " .. pattern)
		assert(string.find(tostring(err), pattern), "error was: " .. tostring(err))
	end
	bad(function() big.F1 = 256 end, "Big.F1 expects u8")
	bad(function() big.F1 = 1.5 end, "Big.F1 expects u8")
	bad(function() big.Name = 5 end, "Big.Name expects string")
	bad(function() big.Nope = 1 end, "has no field 'Nope'")
	bad(function() big.Phase = "Bogus" end, "Big.Phase expects enum")
	bad(function() big.Inv["x"] = { Id = 1, Count = 1 } end, "keys must be u16")
	bad(function() big.Inv[7] = { Id = 1 } end, "Count expects u8")
	bad(function() big.Inv[7] = { Id = 1, Count = 1, Extra = 1 } end, "has no field 'Extra'")
	bad(function() big.Bag[5] = { Id = 1, Count = 1 } end, "would leave a hole")
	bad(function() big.Name = nil end, "Big.Name expects string")
	bad(function() big.Ratio = 0 / 0 end, "Big.Ratio expects f32")
	bad(function() big.Pos = Vector3.new(0 / 0, 0, 0) end, "Big.Pos expects")
	bad(function() R.Big.new(players[2], { F1 = 1 }) end, "expects")
	bad(function() big.Extra = { a = { b = newproxy() } } end, "cannot hold")
	bad(function() big.Extra = function() end end, "cannot hold")
	bad(function() big.Extra = { x = 0 / 0 } end, "cannot hold")
	local cyc = {} cyc.self = cyc
	bad(function() big.Extra = cyc end, "more than 32 deep")
end)

test("arrays: append, remove last, insert/remove in the middle", function()
	big.Bag[2] = { Id = 10, Count = 2 }
	R.insert(big.Tags, "c")
	R.insert(big.Tags, 1, "first")
	step()
	deepEq(R.raw(big), C[1].Big.get(), "Big", true)
	R.remove(big.Tags, 2)
	R.remove(big.Tags)
	big.Bag[2] = nil
	big.Bag[1].Count = 50
	step()
	deepEq(R.raw(big), C[1].Big.get(), "Big", true)
end)

test("client tables keep their identity across patches", function()
	local got = C[1].Big.get()
	local inv, bag = got.Inv, got.Bag
	big.Inv[1].Count = 1
	big.Bag[1].Count = 2
	step()
	assert(C[1].Big.get().Inv == inv and C[1].Big.get().Bag == bag)
end)

test("listeners: field, any-change, observe, disconnect", function()
	local got = C[1].Big.get()
	local seen, anyCount, obs = {}, 0, {}
	local c1 = C[1].changed(got, "F2", function(new, old)
		table.insert(seen, { new, old })
	end)
	C[1].changed(got.Inv, function()
		anyCount += 1
	end)
	C[1].observe(got, "Name", function(v)
		table.insert(obs, v)
	end)
	big.F2 = 22
	big.Inv[1].Count = 5
	big.Inv[9] = { Id = 9, Count = 9 }
	big.Name = "n2"
	step()
	assert(#seen == 1 and seen[1][1] == 22 and seen[1][2] == 2, "F2 listener")
	assert(anyCount == 1, "map any-listener fires once per update, got " .. anyCount)
	assert(#obs == 2 and obs[1] == "renamed" and obs[2] == "n2", "observe")
	c1:Disconnect()
	big.F2 = 23
	step()
	assert(#seen == 1, "disconnected listener fired")
end)

test("randomized edits stay in sync (2000 ops)", function()
	-- small deterministic PRNG (the mock has no Random)
	local seed = 7
	local rng = {}
	function rng:NextNumber()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	function rng:NextInteger(a, b)
		return a + math.floor(self:NextNumber() * (b - a + 1))
	end
	for n = 1, 2000 do
		local r = rng:NextInteger(1, 12)
		if r == 1 then
			big["F" .. rng:NextInteger(1, 40)] = rng:NextInteger(0, 255)
		elseif r == 2 then
			local id = rng:NextInteger(1, 30)
			if rng:NextNumber() < 0.3 then
				big.Inv[id] = nil
			else
				big.Inv[id] = { Id = id, Count = rng:NextInteger(0, 255), Tag = if rng:NextNumber() < 0.5 then "t" .. n else nil }
			end
		elseif r == 3 then
			for id in R.raw(big).Inv do
				if rng:NextNumber() < 0.2 then
					big.Inv[id].Count = rng:NextInteger(0, 255)
					big.Inv[id].Tag = if rng:NextNumber() < 0.5 then nil else "u" .. n
				end
			end
		elseif r == 4 then
			local bag = big.Bag
			local len = #R.raw(big).Bag
			local x = rng:NextNumber()
			if x < 0.4 then
				bag[len + 1] = { Id = n % 65536, Count = n % 256 }
			elseif x < 0.6 and len > 0 then
				R.remove(bag, rng:NextInteger(1, len))
			elseif x < 0.8 then
				R.insert(bag, rng:NextInteger(1, len + 1), { Id = 1, Count = 1 })
			elseif len > 0 then
				bag[rng:NextInteger(1, len)].Count = rng:NextInteger(0, 255)
			end
		elseif r == 5 then
			local k = "k" .. rng:NextInteger(1, 5)
			if rng:NextNumber() < 0.2 then
				big.Nested[k] = nil
			elseif R.raw(big).Nested[k] == nil then
				big.Nested[k] = { a = rng:NextInteger(-100, 100) }
			else
				big.Nested[k]["s" .. rng:NextInteger(1, 4)] = if rng:NextNumber() < 0.2 then nil else rng:NextInteger(-1000, 1000)
			end
		elseif r == 6 then
			local e = big.Extra
			local k = "e" .. rng:NextInteger(1, 6)
			local x = rng:NextNumber()
			if x < 0.25 then
				e[k] = { deep = { v = n } }
			elseif x < 0.5 and type(R.raw(e)[k]) == "table" then
				e[k].deep = if rng:NextNumber() < 0.5 then nil else { v = -n, s = "s" }
			elseif x < 0.75 then
				e[k] = if rng:NextNumber() < 0.5 then n * 0.5 else "str" .. n
			else
				e[k] = nil
			end
		elseif r == 7 then
			big.Opt = if rng:NextNumber() < 0.3 then nil else { Id = n % 65536, Count = 1 }
		elseif r == 8 then
			big.Pos = if rng:NextNumber() < 0.3 then nil else Vector3.new(n, -n, 0.5)
		elseif r == 9 then
			big.Huge = rng:NextInteger(0, 2 ^ 31) * 1000
			big.Neg = -rng:NextInteger(0, 2 ^ 31)
		elseif r == 10 then
			big.Phase = ({ "Lobby", "Playing", "Ended" })[rng:NextInteger(1, 3)]
			big.Flag = not R.raw(big).Flag
		elseif r == 11 then
			big.Tags[#R.raw(big).Tags + 1] = "t" .. n
		else
			big.Ratio = rng:NextInteger(0, 1000) / 8
		end
		if n % 7 == 0 then
			step()
			deepEq(R.raw(big), C[1].Big.get(), `Big (op {n})`, true)
		end
	end
	step()
	deepEq(R.raw(big), C[1].Big.get(), "Big (end)", true)
end)

local worldState
test("Scope All: everyone, late joiners, shared stream", function()
	worldState = R.World.new({ Round = 1, Phase = "Lobby", Scores = {} })
	step()
	for i = 1, 3 do
		deepEq(R.raw(worldState), C[i].World.get(), "World@" .. i)
	end
	worldState.Round = 2
	worldState.Scores.a = 5
	step()
	for i = 1, 3 do
		deepEq(R.raw(worldState), C[i].World.get(), "World@" .. i)
	end
	-- late joiner
	local p4 = world:addPlayer()
	players[4] = p4
	C[4] = world.clients[4]:requireFile(ROOT .. "/tests/gen/Client.luau")
	worldState.Round = 3
	step()
	step()
	for i = 1, 4 do
		deepEq(R.raw(worldState), C[i].World.get(), "World@" .. i)
	end
end)

test("Scope Manual: subscribe / unsubscribe / removed callback", function()
	local room = R.Room.new({ Name = "r", Members = {} })
	R.subscribe(room, players[2])
	step()
	deepEq(R.raw(room), C[2].Room.get(), "Room@2")
	assert(C[1].Room.get() == nil, "unsubscribed player got a manual state")
	local removed = 0
	C[2].Room.removed(function()
		removed += 1
	end)
	room.Members.x = true
	R.unsubscribe(room, players[2])
	step()
	assert(C[2].Room.get() == nil and removed == 1, "unsubscribe")
	R.subscribe(room, players[2])
	step()
	deepEq(R.raw(room), C[2].Room.get(), "Room@2 resubscribed")
end)

test("destroy: client drops it, later writes still change the save data", function()
	local b2 = R.Big.new(players[2], bigData())
	step()
	assert(C[2].Big.get(), "created")
	R.destroy(b2)
	step()
	assert(C[2].Big.get() == nil, "destroyed state still on the client")
	b2.F1 = 9
	assert(R.raw(b2).F1 == 9 and R.isDirty(b2))
end)

test("writes to a replaced child warn and do not replicate", function()
	local warnsBefore = #world.warnings
	local old = big.Inv[1] or big.Inv[next(R.raw(big).Inv)]
	big.Inv[1] = { Id = 1, Count = 1 }
	old.Count = 77
	assert(#world.warnings > warnsBefore or world.stats.warnings > 0, "no warning for a detached write")
	step()
	deepEq(R.raw(big), C[1].Big.get(), "Big", true)
end)

test("ranges: values, string lengths, array lengths, map keys", function()
	local function bad(fn, pattern)
		local ok, err = pcall(fn)
		assert(not ok, "expected an error matching " .. pattern)
		assert(string.find(tostring(err), pattern, 1, true), "error was: " .. tostring(err))
	end
	local r = R.Ranged.new({ Level = 1, Ratio = 0.5, Nick = "acid", Code = "AB12", Team = { 1, 2 }, Tags = { a = 5 } }, { players[1] })
	r.Level = 99
	r.Ratio = 1
	r.Nick = "twelve chars"
	r.Team[3] = 7
	r.Tags.abcdefgh = -5
	bad(function() r.Level = 0 end, "with value 1..99")
	bad(function() r.Level = 100 end, "with value 1..99")
	bad(function() r.Ratio = 1.5 end, "with value 0..1")
	bad(function() r.Nick = "thirteen chrs" end, "with length ..12")
	bad(function() r.Code = "ABC" end, "with length 4..4")
	bad(function() r.Team[4] = 1 end, "must hold 0..3 items")
	bad(function() r.Team[1] = 0 end, "with value 1..")
	bad(function() R.insert(r.Team, 1, 5) end, "must hold 0..3 items")
	bad(function() r.Team = { 1, 2, 3, 4 } end, "must hold 0..3 items")
	bad(function() r.Tags.abcdefghi = 1 end, "keys must be string with length 1..8")
	bad(function() r.Tags[""] = 1 end, "keys must be string with length 1..8")
	bad(function() r.Tags.a = 6 end, "with value -5..5")
	bad(function() R.Ranged.new({ Level = 0, Ratio = 0, Nick = "", Code = "ABCD", Team = {}, Tags = {} }) end, "with value 1..99")
	step()
	deepEq(R.raw(r), C[1].Ranged.get(), "Ranged")
end)

test("destroyed states are freed (no leak)", function()
	local function live()
		__gc("collect")
		__gc("collect")
		return __live_bytes()
	end
	local function cycle(n)
		for _ = 1, n do
			local room = R.Room.new({ Name = string.rep("x", 200), Members = { a = true, b = true } }, { players[1] })
			step()
			R.destroy(room)
			step()
		end
	end
	cycle(20)
	local before = live()
	cycle(300)
	local grew = live() - before
	assert(grew < 20000, `heap grew {grew} bytes over 300 create/destroy cycles`)
end)

print(`\n{passed} passed, {failed} failed`)
if failed > 0 then
	error("tests failed", 0)
end
