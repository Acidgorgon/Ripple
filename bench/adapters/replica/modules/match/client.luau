--!optimize 2
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Replica = require(ReplicatedStorage:WaitForChild("ReplicaClient"))

local current = nil
local clockListeners = {}

Replica.OnNew("Match", function(replica)
	current = replica
	replica:OnSet({ "Clock" }, function(value)
		for _, fn in clockListeners do
			fn(value)
		end
	end)
	replica.Maid:Add(function()
		if current == replica then
			current = nil
		end
	end)
end)

Replica.RequestData()

local api = {}
function api.onClock(fn)
	table.insert(clockListeners, fn)
end
function api.get()
	return if current then current.Data else nil
end
return api
