--!optimize 2
-- club_tick: FM's case. 50 players each own a ~300-card club (private state, replicated to its owner).
-- Once a second (every 30th frame, all players on the same frame, like FM's coin loop) every player's Cash
-- changes. Rarely: a stat change (every 300 frames per player), a pack of 3 cards (every 900), a card level
-- up (every 600) and a card sale (every 900). This is mostly "one number changes on a big table".
local H = ...
local Club = H.import("scenarios/common/club.luau", H)
return Club.driver(H, {
	ticksEvery = 30,
	statEvery = 300,
	packEvery = 900,
	packSize = 3,
	levelEvery = 600,
	sellEvery = 900,
})
