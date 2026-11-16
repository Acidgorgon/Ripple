--!optimize 2
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicaController = require(ReplicatedStorage:WaitForChild("ReplicaController"))

local current = nil
local clockListeners = {}

ReplicaController.ReplicaOfClassCreated("Match", function(replica)
	current = replica
	replica:ListenToChange({ "Clock" }, function(value)
		for _, fn in clockListeners do
			fn(value)
		end
	end)
	replica:AddCleanupTask(function()
		if current == replica then
			current = nil
		end
	end)
end)

ReplicaController.RequestData()

local api = {}
function api.onClock(fn)
	table.insert(clockListeners, fn)
end
function api.get()
	return if current then current.Data else nil
end
return api
