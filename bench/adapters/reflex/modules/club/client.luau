--!optimize 2
-- Reflex client, schema "club": root producer from the shared slices + broadcast receiver.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Reflex = require("../_shared/reflex/reflex")
local slices = require("./slices")

local dispatchEvent = ReplicatedStorage:WaitForChild("ReflexClubDispatch")
local startEvent = ReplicatedStorage:WaitForChild("ReflexClubStart")

local producer = Reflex.combineProducers(slices)

local receiver = Reflex.createBroadcastReceiver({
	start = function()
		startEvent:FireServer()
	end,
})
dispatchEvent.OnClientEvent:Connect(function(actions)
	receiver:dispatch(actions)
end)
producer:applyMiddleware(receiver.middleware)

local userId = tostring(Players.LocalPlayer.UserId)

local function selectClub(state)
	return state.clubs[userId]
end
local function selectCash(state)
	local club = state.clubs[userId]
	return if club then club.Cash else nil
end
local function selectOwned(state)
	local club = state.clubs[userId]
	return if club then club.Owned else nil
end

local api = {}
function api.onCash(fn)
	producer:subscribe(selectCash, function(cash)
		fn(cash)
	end)
end
function api.onCards(fn)
	producer:subscribe(selectOwned, function()
		fn()
	end)
end
function api.get()
	return producer:getState(selectClub)
end
return api
