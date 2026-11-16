--!optimize 2
-- Reflex server, schema "match": every action is broadcast to every started player.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Reflex = require("../_shared/reflex/reflex")
local slices = require("./slices")

local dispatchEvent = Instance.new("RemoteEvent")
dispatchEvent.Name = "ReflexMatchDispatch"
dispatchEvent.Parent = ReplicatedStorage
local startEvent = Instance.new("RemoteEvent")
startEvent.Name = "ReflexMatchStart"
startEvent.Parent = ReplicatedStorage

local producer = Reflex.combineProducers(slices)

local broadcaster = Reflex.createBroadcaster({
	producers = slices,
	dispatchRate = 0,
	dispatch = function(player, actions)
		dispatchEvent:FireClient(player, actions)
	end,
})

startEvent.OnServerEvent:Connect(function(player)
	broadcaster:start(player)
end)
Players.PlayerAdded:Connect(function(player)
	broadcaster:start(player)
end)

producer:applyMiddleware(broadcaster.middleware)

local api = {}
function api.create(data)
	producer.setMatch(data)
	return {}
end
function api.setClock(_h, clock)
	producer.setClock(clock)
end
function api.setStamina(_h, index, stamina)
	producer.setStamina(index, stamina)
end
function api.setScore(_h, home, away)
	producer.setScore(home, away)
end
function api.setPhase(_h, phase)
	producer.setPhase(phase)
end
return api
