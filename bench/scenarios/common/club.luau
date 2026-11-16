--!optimize 2
-- Shared driver code for the "club" schema: FM-shaped private player state.
--
-- Canonical data shape (what create() receives and what a client's get() must return):
--   {
--     Cash: number (integer, 0 .. 2^40), OfflinePending: number (integer), Tier: number (u8),
--     KitColor: string, Style: string,
--     Styles: { [string]: boolean }            -- 8 entries
--     Slots: { string }                        -- 11 card instance ids ("i<N>")
--     Stats: { Wins, Draws, Losses, Goals, Conceded, Played, PacksOpened, Xp: number (u32), Streak, BestStreak: number (u16) }
--     Trophies: { [string]: number }           -- 12 entries (u16)
--     Pity: number (u16),
--     Owned: { [string]: Card }                -- keyed by InstanceId "i<N>" (FM's keys), ~300 entries
--   }
--   Card = { CardId: number (u16), Level: number (u8), Dupes: number (u8), Bonus: number (u8), Locked: boolean }
--
-- Contract (schema "club"); every write targets ONE player's club, replicated to that player only:
--   server: create(player, data) -> handle     data is a fresh table; the library may keep or mutate it
--           setCash(handle, number)
--           setStat(handle, statKey, number)    Stats[statKey] = number
--           setCard(handle, instanceId: string, Card?)  Owned[instanceId] = fresh Card table, or nil to remove
--           setCardLevel(handle, instanceId, number)   Owned[instanceId].Level = number (card exists)
--           destroy(handle)                     stop replicating; the client's get() may then return nil
--   client: onCash(fn(number))                  fired when Cash changes (once per change it observes)
--           onCards(fn())                       fired when anything in Owned changes
--           get() -> club table | nil           the client's current view (read only)

local Club = {}

Club.STAT_KEYS = { "Wins", "Draws", "Losses", "Goals", "Conceded", "Played", "PacksOpened", "Xp", "Streak", "BestStreak" }
Club.STYLE_KEYS = { "Balanced", "Attack", "Defend", "Counter", "Press", "Possession", "Wing", "Long" }
Club.TROPHY_KEYS = {
	"League1", "League2", "League3", "Cup1", "Cup2", "Cup3", "Super", "Champions", "Draft", "Nations", "Climb", "Tour",
}
Club.CARD_COUNT = 300

function Club.newCard(seed: number)
	return {
		CardId = (seed * 7919) % 2000 + 1,
		Level = seed % 30 + 1,
		Dupes = seed % 5,
		Bonus = (seed * 3) % 20,
		Locked = seed % 7 == 0,
	}
end

-- Fresh canonical club for player i (deterministic).
function Club.newData(i: number)
	local owned = {}
	local base = i * 100000
	for k = 1, Club.CARD_COUNT do
		owned[`i{base + k}`] = Club.newCard(i * 1000 + k)
	end
	local slots = table.create(11)
	for k = 1, 11 do
		slots[k] = `i{base + k}`
	end
	local styles = {}
	for k, key in Club.STYLE_KEYS do
		styles[key] = (i + k) % 3 ~= 0
	end
	local stats = {}
	for k, key in Club.STAT_KEYS do
		stats[key] = (i * 13 + k * 101) % 5000
	end
	local trophies = {}
	for k, key in Club.TROPHY_KEYS do
		trophies[key] = (i + k) % 9
	end
	return {
		Cash = 1000000 + i * 12345,
		OfflinePending = i * 10,
		Tier = i % 10 + 1,
		KitColor = "Royal Blue",
		Style = "Balanced",
		Styles = styles,
		Slots = slots,
		Stats = stats,
		Trophies = trophies,
		Pity = i % 50,
		Owned = owned,
	}
end

function Club.copyCard(c)
	return { CardId = c.CardId, Level = c.Level, Dupes = c.Dupes, Bonus = c.Bonus, Locked = c.Locked }
end

-- Deep copy (the driver keeps its own "truth" and hands libraries fresh tables).
function Club.copy(d)
	local owned = {}
	for id, c in d.Owned do
		owned[id] = Club.copyCard(c)
	end
	return {
		Cash = d.Cash,
		OfflinePending = d.OfflinePending,
		Tier = d.Tier,
		KitColor = d.KitColor,
		Style = d.Style,
		Styles = table.clone(d.Styles),
		Slots = table.clone(d.Slots),
		Stats = table.clone(d.Stats),
		Trophies = table.clone(d.Trophies),
		Pity = d.Pity,
		Owned = owned,
	}
end

-- Compares a client view with the truth. `full` also walks Owned and the small maps.
function Club.check(H, got, want, full: boolean, what: string)
	H.checks += 1
	if type(got) ~= "table" then
		H.fail(`{what}: expected a club table, got {typeof(got)}`)
	end
	H.eq(got.Cash, want.Cash, `{what}.Cash`)
	if not full then
		return
	end
	H.eq(got.OfflinePending, want.OfflinePending, `{what}.OfflinePending`)
	H.eq(got.Tier, want.Tier, `{what}.Tier`)
	H.eq(got.KitColor, want.KitColor, `{what}.KitColor`)
	H.eq(got.Style, want.Style, `{what}.Style`)
	H.eq(got.Pity, want.Pity, `{what}.Pity`)
	for _, key in Club.STYLE_KEYS do
		H.eq(got.Styles[key], want.Styles[key], `{what}.Styles.{key}`)
	end
	for k = 1, 11 do
		H.eq(got.Slots[k], want.Slots[k], `{what}.Slots[{k}]`)
	end
	for _, key in Club.STAT_KEYS do
		H.eq(got.Stats[key], want.Stats[key], `{what}.Stats.{key}`)
	end
	for _, key in Club.TROPHY_KEYS do
		H.eq(got.Trophies[key], want.Trophies[key], `{what}.Trophies.{key}`)
	end
	local n = 0
	for id, c in want.Owned do
		n += 1
		local g = got.Owned[id]
		if g == nil then
			H.fail(`{what}.Owned[{id}] missing`)
		end
		H.eq(g.CardId, c.CardId, `{what}.Owned[{id}].CardId`)
		H.eq(g.Level, c.Level, `{what}.Owned[{id}].Level`)
		H.eq(g.Dupes, c.Dupes, `{what}.Owned[{id}].Dupes`)
		H.eq(g.Bonus, c.Bonus, `{what}.Owned[{id}].Bonus`)
		H.eq(g.Locked, c.Locked, `{what}.Owned[{id}].Locked`)
	end
	local gn = 0
	for _ in got.Owned do
		gn += 1
	end
	H.eq(gn, n, `{what} #Owned`)
end

-- Builds a club workload driver. `plan(f, i)` returns which ops player i runs on frame f.
-- opts = { ticksEvery = 30, packEvery = n, packSize = k, levelEvery = n, sellEvery = n, statEvery = n, rejoinPerFrame = n }
function Club.driver(H, opts)
	local S = {
		schema = "club",
		clients = opts.clients or 50,
		fullVerifyEvery = opts.fullVerifyEvery or 30,
		api = {
			server = { "create", "setCash", "setStat", "setCard", "setCardLevel", "destroy" },
			client = { "onCash", "onCards", "get" },
		},
	}
	local truth = {} -- [i] = canonical club
	local handles = {}
	local nextId = {}
	local cashSeen, cardsSeen = {}, {}
	local cardKeys = {} -- [i] = array of owned ids (for deterministic picks)

	local function rebuildKeys(i)
		local keys = {}
		for id in truth[i].Owned do
			table.insert(keys, id)
		end
		table.sort(keys)
		cardKeys[i] = keys
	end

	function S.setup(ctx)
		for i = 1, ctx.nclients do
			cashSeen[i], cardsSeen[i] = 0, 0
			local net = ctx.clients[i]
			net.onCash(function(v)
				cashSeen[i] += 1
				ctx.sink += 1
			end)
			net.onCards(function()
				cardsSeen[i] += 1
			end)
		end
		for i = 1, ctx.nclients do
			truth[i] = Club.newData(i)
			nextId[i] = i * 100000 + Club.CARD_COUNT + 1
			rebuildKeys(i)
			handles[i] = ctx.server.create(ctx.players[i], Club.copy(truth[i]))
		end
	end

	-- prepare (untimed) applies each op to the truth and records it with ready-made fresh tables;
	-- serverSend (timed) only replays the recorded calls against the library.
	local ops = {} -- flat: kind, i, a, b
	local nops = 0
	local OP_REJOIN, OP_CASH, OP_STAT, OP_CARD, OP_LEVEL = 1, 2, 3, 4, 5
	local function push(kind, i, a, b)
		ops[nops + 1] = kind
		ops[nops + 2] = i
		ops[nops + 3] = a
		ops[nops + 4] = b
		nops += 4
	end

	function S.prepare(ctx, f: number)
		table.clear(ops)
		nops = 0
		local n = ctx.nclients
		local rejoin = opts.rejoinPerFrame or 0
		for r = 1, rejoin do
			local i = (f * rejoin + r) % n + 1
			push(OP_REJOIN, i, Club.copy(truth[i]), nil)
		end
		for i = 1, n do
			local t = truth[i]
			if opts.ticksEvery and f % opts.ticksEvery == 0 then
				t.Cash += 10 + i
				push(OP_CASH, i, t.Cash, nil)
			end
			if opts.statEvery and (f + i) % opts.statEvery == 0 then
				local key = Club.STAT_KEYS[(f + i) % #Club.STAT_KEYS + 1]
				t.Stats[key] += 1
				push(OP_STAT, i, key, t.Stats[key])
			end
			if opts.packEvery and (f + i * 3) % opts.packEvery == 0 then
				for _ = 1, opts.packSize or 1 do
					local cn = nextId[i]
					nextId[i] += 1
					local id = `i{cn}`
					local card = Club.newCard(cn)
					t.Owned[id] = card
					push(OP_CARD, i, id, Club.copyCard(card))
				end
				rebuildKeys(i)
			end
			if opts.levelEvery and (f + i * 5) % opts.levelEvery == 0 then
				local keys = cardKeys[i]
				local id = keys[(f * 7 + i) % #keys + 1]
				local c = t.Owned[id]
				c.Level = c.Level % 99 + 1
				push(OP_LEVEL, i, id, c.Level)
			end
			if opts.sellEvery and (f + i * 11) % opts.sellEvery == 0 then
				local keys = cardKeys[i]
				local id = keys[(f * 13 + i) % #keys + 1]
				if tonumber(string.sub(id, 2)) > i * 100000 + 11 then
					t.Owned[id] = nil
					push(OP_CARD, i, id, false)
					rebuildKeys(i)
				end
			end
		end
	end

	function S.serverSend(ctx, f: number)
		local net = ctx.server
		local players = ctx.players
		local create, destroy, setCash, setStat, setCard, setCardLevel =
			net.create, net.destroy, net.setCash, net.setStat, net.setCard, net.setCardLevel
		for k = 1, nops, 4 do
			local kind, i, a, b = ops[k], ops[k + 1], ops[k + 2], ops[k + 3]
			if kind == OP_CASH then
				setCash(handles[i], a)
			elseif kind == OP_STAT then
				setStat(handles[i], a, b)
			elseif kind == OP_CARD then
				setCard(handles[i], a, if b == false then nil else b)
			elseif kind == OP_LEVEL then
				setCardLevel(handles[i], a, b)
			else
				destroy(handles[i])
				handles[i] = create(players[i], a)
			end
		end
	end

	function S.verify(ctx, f: number, full: boolean)
		local sampled = f % ctx.nclients + 1
		for i = 1, ctx.nclients do
			Club.check(H, ctx.clients[i].get(), truth[i], full or i == sampled, `client {i} club`)
		end
	end

	return S
end

return Club
