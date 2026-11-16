--!optimize 2
-- Replica: one shared match replica, Replicate()d to every (current and future) ready player.
local ServerScriptService = game:GetService("ServerScriptService")
local Replica = require(ServerScriptService.ReplicaServer)

local MatchToken = Replica.Token("Match")

local api = {}
function api.create(data)
	local replica = Replica.New({ Token = MatchToken, Data = data })
	replica:Replicate()
	return replica
end
function api.setClock(replica, v)
	replica:Set({ "Clock" }, v)
end
function api.setStamina(replica, index, v)
	replica:Set({ "Players", index, "Stamina" }, v)
end
function api.setScore(replica, home, away)
	replica:SetValues({}, { HomeScore = home, AwayScore = away })
end
function api.setPhase(replica, v)
	replica:Set({ "Phase" }, v)
end
return api
