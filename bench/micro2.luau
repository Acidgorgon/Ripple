--!optimize 2
local gen = arg[1] or "gen/ripple"
local function import(path, ...)
	return loadstring(readfile(path), "@" .. path)(...)
end
local Mock = import("lib/mock.luau")
Mock.installGlobals()
local world = Mock.newWorld()
local players = {}
for i = 1, 50 do
	players[i] = world:addPlayer()
end
local H = { checks = 0, fail = error, eq = function() end }
local Club = import("scenarios/common/club.luau", H)
local S = world.server:requireFile(gen .. "/club/Server.luau")
local mode = arg[2] or "remote"
if mode == "null" then
	S.setTransport(function() end)
end
local clubs = {}
for i = 1, 50 do
	clubs[i] = S.Club.new(players[i], Club.newData(i))
end
S.flush()
world:deliver()
local function bench(name, n, fn)
	fn()
	__gc("collect")
	local a0 = __alloc_bytes()
	local t0 = os.clock()
	for _ = 1, n do
		fn()
	end
	local dt = (os.clock() - t0) / n * 1e6
	print(string.format("%-40s %9.2f us   %9.0f B alloc", name, dt, (__alloc_bytes() - a0) / n))
end
local v = 0
bench("50 Cash sets", 2000, function()
	v += 1
	for i = 1, 50 do
		clubs[i].Cash = v
	end
end)
bench("50 Cash sets + flush (" .. mode .. ")", 2000, function()
	v += 1
	for i = 1, 50 do
		clubs[i].Cash = v
	end
	S.flush()
	world.server = world.server -- keep
	for _, q in world do end
end)
bench("empty flush", 20000, function()
	S.flush()
end)
