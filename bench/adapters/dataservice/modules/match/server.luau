--!optimize 2
-- Match schema on Dataservice. Dataservice has no shared state: it replicates one data table per player,
-- to that player. A game that uses it for everything puts the match state in every player's data under
-- "Match" and repeats each write for every player (one FireClient per player per write). Every player's
-- data references the same server table, so the repeated Data:set calls write the same field.
-- (A real game would also strip "Match" before saving; saving is out of scope here.)
-- Later joiners get the current state through DataService's onPlayerInit override.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local DataService = require(ReplicatedStorage.Packages.DataService).server

DataService:init({
	template = {},
	useMock = true, -- DataService's documented test mode (Mock store); the store is faked anyway
})

local match = nil

function DataService.onPlayerInit(_self, _player, data)
	data.Match = match
end

local api = {}

function api.create(data)
	match = data
	for _, player in Players:GetPlayers() do
		DataService:set(player, { "Match" }, data)
	end
	return data
end

function api.setClock(_h, v)
	for _, player in Players:GetPlayers() do
		DataService:set(player, { "Match", "Clock" }, v)
	end
end

function api.setStamina(_h, k, v)
	for _, player in Players:GetPlayers() do
		DataService:set(player, { "Match", "Players", k, "Stamina" }, v)
	end
end

function api.setScore(_h, home, away)
	for _, player in Players:GetPlayers() do
		DataService:set(player, { "Match", "HomeScore" }, home)
		DataService:set(player, { "Match", "AwayScore" }, away)
	end
end

function api.setPhase(_h, v)
	for _, player in Players:GetPlayers() do
		DataService:set(player, { "Match", "Phase" }, v)
	end
end

return api
