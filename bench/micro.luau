--!optimize 2
-- Micro benchmarks of Ripple's hot paths outside the frame harness.
--   luau-bench -O2 --codegen micro.luau <genDir>
local gen = arg[1] or "gen/ripple"
local function import(path, ...)
	return loadstring(readfile(path), "@" .. path)(...)
end
local Mock = import("lib/mock.luau")
Mock.installGlobals()
local world = Mock.newWorld()
local player = world:addPlayer()
local H = { checks = 0, fail = error, eq = function() end }
local Club = import("scenarios/common/club.luau", H)
local S = world.server:requireFile(gen .. "/club/Server.luau")
local C = world.clients[1]:requireFile(gen .. "/club/Client.luau")
local captured
S.setTransport(function(_, b)
	captured = b
end)

local function bench(name, n, fn)
	fn()
	__gc("collect")
	local a0 = __alloc_bytes()
	local t0 = os.clock()
	for _ = 1, n do
		fn()
	end
	local dt = (os.clock() - t0) / n * 1e6
	print(string.format("%-34s %9.2f us   %9.0f B alloc", name, dt, (__alloc_bytes() - a0) / n))
end

local datas = {}
for i = 1, 200 do
	datas[i] = Club.newData(1)
end
local k = 0
bench("(reference) Club.copy only", 200, function()
	k = k % 200 + 1
	local d = Club.copy(datas[k])
end)
k = 0
bench("server new(300 cards)", 200, function()
	k = k % 200 + 1
	local d = Club.copy(datas[k])
	local c = S.Club.new(player, d)
	S.destroy(c)
end)
k = 0
local clubs = {}
bench("server new + flush(snapshot)", 200, function()
	k = k % 200 + 1
	local c = S.Club.new(player, Club.copy(datas[k]))
	S.flush()
	S.destroy(c)
	S.flush()
end)
local club = S.Club.new(player, Club.newData(1))
S.flush()
local snap = captured
print("snapshot bytes", buffer.len(snap))
local club2 = S.Club.new(player, Club.newData(1))
S.flush()
local snap2 = captured
S.destroy(club2)
S.flush()
local destroyBuf = captured
bench("client decode snapshot (+destroy)", 500, function()
	C.receive(snap2)
	C.receive(destroyBuf)
end)
local v = 0
bench("server set Cash x1000", 100, function()
	for _ = 1, 1000 do
		v += 1
		club.Cash = v
	end
end)
bench("server read Cash x1000", 100, function()
	local s = 0
	for _ = 1, 1000 do
		s += club.Cash
	end
end)
bench("server set Owned[id].Level x1000", 100, function()
	local owned = club.Owned
	for i = 1, 1000 do
		owned["i10000" .. (i % 9 + 1)].Level = i % 50 + 1
	end
end)
bench("flush 1 Cash change", 1000, function()
	v += 1
	club.Cash = v
	S.flush()
end)
