--!optimize 2
-- Reflex client, schema "match".
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Reflex = require("../_shared/reflex/reflex")
local slices = require("./slices")

local dispatchEvent = ReplicatedStorage:WaitForChild("ReflexMatchDispatch")
local startEvent = ReplicatedStorage:WaitForChild("ReflexMatchStart")

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

local function selectMatch(state)
	return state.match
end
local function selectClock(state)
	local match = state.match
	return if match then match.Clock else nil
end

local api = {}
function api.onClock(fn)
	producer:subscribe(selectClock, function(clock)
		fn(clock)
	end)
end
function api.get()
	return producer:getState(selectMatch)
end
return api
