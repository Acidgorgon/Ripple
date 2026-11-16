--!optimize 2
-- ReplicaService: one shared match replica, Replication = "All".
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicaService = require(ServerScriptService.ReplicaService)

local MatchToken = ReplicaService.NewClassToken("Match")

local api = {}
function api.create(data)
	return ReplicaService.NewReplica({ ClassToken = MatchToken, Data = data, Replication = "All" })
end
function api.setClock(replica, v)
	replica:SetValue({ "Clock" }, v)
end
function api.setStamina(replica, index, v)
	replica:SetValue({ "Players", index, "Stamina" }, v)
end
function api.setScore(replica, home, away)
	replica:SetValues({}, { HomeScore = home, AwayScore = away })
end
function api.setPhase(replica, v)
	replica:SetValue({ "Phase" }, v)
end
return api
