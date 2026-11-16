--!optimize 2
-- club_churn: heavy inventory traffic on the same 50 x 300-card clubs. Every player, every 10 frames:
-- a pack of 5 new cards; every 5 frames a card level up and a stat change; every 15 frames a card sale;
-- plus the once-a-second Cash tick. Exercises map adds / removes and nested-field patches.
local H = ...
local Club = H.import("scenarios/common/club.luau", H)
return Club.driver(H, {
	ticksEvery = 30,
	statEvery = 5,
	packEvery = 10,
	packSize = 5,
	levelEvery = 5,
	sellEvery = 15,
	fullVerifyEvery = 60,
})
