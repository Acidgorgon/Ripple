--!optimize 2
-- ReplicaService: one replica per player club, replicated to that player only.
-- Replication uses the documented player-set form {[player] = true} rather than the bare `player` form:
-- mock Players are Luau tables, so type(player) == "table" would send NewReplica down its player-set branch.
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicaService = require(ServerScriptService.ReplicaService)

local ClubToken = ReplicaService.NewClassToken("Club")

local api = {}
function api.create(player, data)
	return ReplicaService.NewReplica({
		ClassToken = ClubToken,
		Tags = { Player = player },
		Data = data,
		Replication = { [player] = true },
	})
end
function api.setCash(replica, v)
	replica:SetValue({ "Cash" }, v)
end
function api.setStat(replica, key, v)
	replica:SetValue({ "Stats", key }, v)
end
function api.setCard(replica, id, card)
	replica:SetValue({ "Owned", id }, card)
end
function api.setCardLevel(replica, id, level)
	replica:SetValue({ "Owned", id, "Level" }, level)
end
function api.destroy(replica)
	replica:Destroy()
end
return api
