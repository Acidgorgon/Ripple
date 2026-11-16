--!optimize 2
-- club_join: snapshot cost. Every frame one player "rejoins": its club is destroyed and created again from a
-- full 300-card table, which must reach the client in full. Plus the once-a-second Cash tick.
local H = ...
local Club = H.import("scenarios/common/club.luau", H)
return Club.driver(H, {
	ticksEvery = 30,
	rejoinPerFrame = 1,
})
