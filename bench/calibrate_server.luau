-- Ripple calibration: Roblox's own C++ cost of sending remote arguments (tables vs buffers).
-- Put in ServerScriptService of an EMPTY baseplate, press Play (Play Solo). Prints results to Output.
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local remote = Instance.new("RemoteEvent")
remote.Name = "RippleCal"
remote.Parent = RS

local player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
task.wait(4)

local function card(i)
	return { CardId = i % 2000 + 1, Level = i % 30 + 1, Dupes = i % 5, Bonus = i % 20, Locked = i % 7 == 0 }
end
local function club(n)
	local owned = {}
	for k = 1, n do
		owned["i" .. (100000 + k)] = card(k)
	end
	local slots = {}
	for k = 1, 11 do
		slots[k] = "i" .. (100000 + k)
	end
	return {
		Cash = 1012345, OfflinePending = 10, Tier = 2, KitColor = "Royal Blue", Style = "Balanced",
		Styles = { Balanced = true, Attack = true, Defend = false, Counter = true, Press = true, Possession = false, Wing = true, Long = true },
		Slots = slots,
		Stats = { Wins = 1, Draws = 2, Losses = 3, Goals = 4, Conceded = 5, Played = 6, PacksOpened = 7, Xp = 8, Streak = 9, BestStreak = 10 },
		Trophies = { League1 = 1, League2 = 2, League3 = 3, Cup1 = 4, Cup2 = 5, Cup3 = 6, Super = 7, Champions = 8, Draft = 0, Nations = 1, Climb = 2, Tour = 3 },
		Pity = 3,
		Owned = owned,
	}
end
local function match()
	local players = {}
	for k = 1, 22 do
		players[k] = { Stamina = 99.5, Cards = 0 }
	end
	return { HomeScore = 1, AwayScore = 2, Clock = 1234.5, Phase = 2, Possession = 50, Players = players }
end

local cases = {
	{ "club table (300 cards)", { club(300) } },
	{ "Owned map only (300 cards)", { club(300).Owned } },
	{ "one card table", { card(5) } },
	{ "path set (1, {'Cash'}, n)", { 1, { "Cash" }, 1234567 } },
	{ "path set card (1, {'Owned', id}, card)", { 1, { "Owned", "i100005" }, card(5) } },
	{ "match table (22 players)", { match() } },
	{ "buffer 4550 B", { buffer.create(4550) } },
	{ "buffer 120 B", { buffer.create(120) } },
	{ "buffer 24 B", { buffer.create(24) } },
	{ "single number", { 1234567 } },
}

local PER_FRAME, FRAMES = 10, 30
local results = {}
for _, case in cases do
	local name, args = case[1], case[2]
	-- warm-up
	for _ = 1, 5 do
		remote:FireClient(player, table.unpack(args))
	end
	task.wait(0.2)
	local total, n = 0, 0
	for _ = 1, FRAMES do
		for _ = 1, PER_FRAME do
			local t0 = os.clock()
			remote:FireClient(player, table.unpack(args))
			total += os.clock() - t0
			n += 1
		end
		task.wait()
	end
	table.insert(results, string.format("[RippleCal] %-40s %9.2f us per FireClient", name, total / n * 1e6))
	task.wait(0.5)
end
-- FireAllClients with one player, for reference
do
	local args = { match() }
	local total, n = 0, 0
	for _ = 1, FRAMES do
		for _ = 1, PER_FRAME do
			local t0 = os.clock()
			remote:FireAllClients(table.unpack(args))
			total += os.clock() - t0
			n += 1
		end
		task.wait()
	end
	table.insert(results, string.format("[RippleCal] %-40s %9.2f us per FireAllClients", "match table", total / n * 1e6))
end
-- Pure Lua reference on this machine: deep copy of the club table (what the benchmark VM charges as 'network')
do
	local function deep(v)
		if type(v) ~= "table" then
			return v
		end
		local o = {}
		for k, x in v do
			o[k] = deep(x)
		end
		return o
	end
	local c = club(300)
	local t0 = os.clock()
	for _ = 1, 100 do
		deep(c)
	end
	table.insert(results, string.format("[RippleCal] %-40s %9.2f us (Luau deep copy reference)", "club table deep copy", (os.clock() - t0) / 100 * 1e6))
end
for _, line in results do
	print(line)
end
print("[RippleCal] done")
