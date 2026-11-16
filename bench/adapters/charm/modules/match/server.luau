--!optimize 2
-- Charm + Charm Sync, schema "match": one shared signal synced to every player under the key "match".
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Charm = require("../_shared/charm/packages/charm/src")
local CharmSync = require("../_shared/charm/packages/charm-sync/src")
local server = CharmSync.server

CharmSync.config.interval = 0
CharmSync.config.preserveHistory = false
CharmSync.config.fixArrays = true

local syncEvent = Instance.new("RemoteEvent")
syncEvent.Name = "CharmSyncMatch"
syncEvent.Parent = ReplicatedStorage

local getMatch, setMatch = Charm.signal(nil :: any)
local synced = { match = getMatch }

server.connect(function(player, payloads)
	syncEvent:FireClient(player, payloads)
end)

local function onPlayerAdded(player)
	server.addSignalsToClient(player, synced)
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end
Players.PlayerRemoving:Connect(function(player)
	server.removeClient(player)
end)

local function update(recipe)
	setMatch(function(match)
		local nextMatch = table.clone(match)
		recipe(nextMatch, match)
		return nextMatch
	end)
end

local api = {}
function api.create(data)
	setMatch(data)
	return {}
end
function api.setClock(_h, clock)
	update(function(nextMatch)
		nextMatch.Clock = clock
	end)
end
function api.setStamina(_h, index, stamina)
	update(function(nextMatch, match)
		local players = table.clone(match.Players)
		local p = table.clone(players[index])
		p.Stamina = stamina
		players[index] = p
		nextMatch.Players = players
	end)
end
function api.setScore(_h, home, away)
	update(function(nextMatch)
		nextMatch.HomeScore = home
		nextMatch.AwayScore = away
	end)
end
function api.setPhase(_h, phase)
	update(function(nextMatch)
		nextMatch.Phase = phase
	end)
end
return api
