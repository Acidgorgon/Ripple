--!optimize 2
-- Replica: one replica per player club, subscribed to its owner only.
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local Replica = require(ServerScriptService.ReplicaServer)

local ClubToken = Replica.Token("Club")

-- Players whose RequestData has not arrived yet are subscribed once they become ready.
local waiting = {} -- [Player] = { replica, ... }
Replica.NewReadyPlayer:Connect(function(player)
	local list = waiting[player]
	if list then
		waiting[player] = nil
		for _, replica in list do
			if replica:IsActive() then
				replica:Subscribe(player)
			end
		end
	end
end)
Players.PlayerRemoving:Connect(function(player)
	waiting[player] = nil
end)

local api = {}
function api.create(player, data)
	local replica = Replica.New({
		Token = ClubToken,
		Tags = { UserId = player.UserId },
		Data = data,
	})
	if Replica.ReadyPlayers[player] then
		replica:Subscribe(player)
	else
		local list = waiting[player]
		if list == nil then
			list = {}
			waiting[player] = list
		end
		table.insert(list, replica)
	end
	return replica
end
function api.setCash(replica, v)
	replica:Set({ "Cash" }, v)
end
function api.setStat(replica, key, v)
	replica:Set({ "Stats", key }, v)
end
function api.setCard(replica, id, card)
	replica:Set({ "Owned", id }, card)
end
function api.setCardLevel(replica, id, level)
	replica:Set({ "Owned", id, "Level" }, level)
end
function api.destroy(replica)
	replica:Destroy()
end
return api
