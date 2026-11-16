--!optimize 2
-- ReplicaController: ReplicaOfClassCreated("Club") picks up this player's club; ListenToChange({"Cash"})
-- drives onCash and ListenToRaw (filtered on path[1] == "Owned") drives onCards (new/removed cards and
-- nested Level sets).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicaController = require(ReplicatedStorage:WaitForChild("ReplicaController"))

local current = nil
local cashListeners, cardListeners = {}, {}

ReplicaController.ReplicaOfClassCreated("Club", function(replica)
	current = replica
	replica:ListenToChange({ "Cash" }, function(value)
		for _, fn in cashListeners do
			fn(value)
		end
	end)
	replica:ListenToRaw(function(_action, path)
		if path[1] == "Owned" then
			for _, fn in cardListeners do
				fn()
			end
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
function api.onCash(fn)
	table.insert(cashListeners, fn)
end
function api.onCards(fn)
	table.insert(cardListeners, fn)
end
function api.get()
	return if current then current.Data else nil
end
return api
