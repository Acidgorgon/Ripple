--!optimize 2
-- Reflex server, schema "club": root producer = combineProducers(shared slices), broadcaster with
-- per-player privacy (beforeDispatch drops other players' club actions, beforeHydrate keeps only
-- the player's own club), dispatchRate 0 (flush every Heartbeat).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Reflex = require("../_shared/reflex/reflex")
local slices = require("./slices")

local dispatchEvent = Instance.new("RemoteEvent")
dispatchEvent.Name = "ReflexClubDispatch"
dispatchEvent.Parent = ReplicatedStorage
local startEvent = Instance.new("RemoteEvent")
startEvent.Name = "ReflexClubStart"
startEvent.Parent = ReplicatedStorage

local producer = Reflex.combineProducers(slices)

local broadcaster = Reflex.createBroadcaster({
	producers = slices,
	dispatchRate = 0,
	dispatch = function(player, actions)
		dispatchEvent:FireClient(player, actions)
	end,
	beforeDispatch = function(player, action)
		if action.arguments[1] ~= tostring(player.UserId) then
			return nil
		end
		return action
	end,
	beforeHydrate = function(player, state)
		local userId = tostring(player.UserId)
		local nextState = table.clone(state)
		nextState.clubs = { [userId] = state.clubs[userId] }
		return nextState
	end,
})

startEvent.OnServerEvent:Connect(function(player)
	broadcaster:start(player)
end)
-- Also start on join (idempotent), so a player receives actions from the moment it joins.
Players.PlayerAdded:Connect(function(player)
	broadcaster:start(player)
end)

producer:applyMiddleware(broadcaster.middleware)

local api = {}
function api.create(player, data)
	local userId = tostring(player.UserId)
	producer.addClub(userId, data)
	return userId
end
function api.setCash(userId, cash)
	producer.setCash(userId, cash)
end
function api.setStat(userId, statKey, value)
	producer.setStat(userId, statKey, value)
end
function api.setCard(userId, instanceId, card)
	producer.setCard(userId, instanceId, card)
end
function api.setCardLevel(userId, instanceId, level)
	producer.setCardLevel(userId, instanceId, level)
end
function api.destroy(userId)
	producer.removeClub(userId)
end
return api
