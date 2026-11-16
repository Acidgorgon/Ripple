--!optimize 2
-- match_shared: one shared match state replicated to all 50 clients (scoreboard + 22 players).
-- Every frame the clock moves and 4 player stamina values change; every 90 frames the score changes and the
-- phase flips. Measures encode-once / send-to-everyone.
--
-- Canonical data shape:
--   { HomeScore: number (u8), AwayScore: number (u8), Clock: number (f32, multiples of 1/32),
--     Phase: number (u8, 0..5), Possession: number (u8 0..100),
--     Players: { { Stamina: number (0..100, multiples of 0.5), Cards: number (u8) } }  -- exactly 22 }
-- Contract (schema "match"):
--   server: create(data) -> handle (replicated to every player, including later joiners)
--           setClock(h, number), setStamina(h, index 1..22, number), setScore(h, home, away), setPhase(h, number)
--   client: onClock(fn(number)), get() -> match table | nil
local H = ...

local S = {
	schema = "match",
	clients = 50,
	fullVerifyEvery = 10,
	api = {
		server = { "create", "setClock", "setStamina", "setScore", "setPhase" },
		client = { "onClock", "get" },
	},
}

local truth
local handle
local clockSeen = {}

local function newData()
	local players = table.create(22)
	for k = 1, 22 do
		players[k] = { Stamina = 100, Cards = 0 }
	end
	return { HomeScore = 0, AwayScore = 0, Clock = 0, Phase = 1, Possession = 50, Players = players }
end

local function copy(d)
	local players = table.create(22)
	for k, p in d.Players do
		players[k] = { Stamina = p.Stamina, Cards = p.Cards }
	end
	return {
		HomeScore = d.HomeScore, AwayScore = d.AwayScore, Clock = d.Clock, Phase = d.Phase,
		Possession = d.Possession, Players = players,
	}
end

function S.setup(ctx)
	for i = 1, ctx.nclients do
		clockSeen[i] = 0
		ctx.clients[i].onClock(function(v)
			clockSeen[i] += 1
			ctx.sink += 1
		end)
	end
	truth = newData()
	handle = ctx.server.create(copy(truth))
end

function S.serverSend(ctx, f: number)
	local net = ctx.server
	truth.Clock = (f % 172800) / 32
	net.setClock(handle, truth.Clock)
	for r = 1, 4 do
		local k = (f * 4 + r) % 22 + 1
		local p = truth.Players[k]
		p.Stamina = if p.Stamina <= 1 then 100 else p.Stamina - 0.5
		net.setStamina(handle, k, p.Stamina)
	end
	if f % 90 == 0 then
		if f % 180 == 0 then
			truth.HomeScore = (truth.HomeScore + 1) % 256
		else
			truth.AwayScore = (truth.AwayScore + 1) % 256
		end
		net.setScore(handle, truth.HomeScore, truth.AwayScore)
		truth.Phase = truth.Phase % 5 + 1
		net.setPhase(handle, truth.Phase)
	end
end

function S.verify(ctx, f: number, full: boolean)
	local sampled = f % ctx.nclients + 1
	for i = 1, ctx.nclients do
		local got = ctx.clients[i].get()
		local what = `client {i} match`
		if type(got) ~= "table" then
			H.fail(`{what}: expected a table, got {typeof(got)}`)
		end
		H.eq(got.Clock, truth.Clock, `{what}.Clock`)
		if full or i == sampled then
			H.eq(got.HomeScore, truth.HomeScore, `{what}.HomeScore`)
			H.eq(got.AwayScore, truth.AwayScore, `{what}.AwayScore`)
			H.eq(got.Phase, truth.Phase, `{what}.Phase`)
			H.eq(got.Possession, truth.Possession, `{what}.Possession`)
			for k = 1, 22 do
				H.eq(got.Players[k].Stamina, truth.Players[k].Stamina, `{what}.Players[{k}].Stamina`)
				H.eq(got.Players[k].Cards, truth.Players[k].Cards, `{what}.Players[{k}].Cards`)
			end
		end
	end
end

return S
