--!optimize 2
-- Replica client: Replica.OnNew("Club") picks up this player's club; OnSet({"Cash"}) drives onCash and
-- OnChange (filtered on path[1] == "Owned") drives onCards (new/removed cards and nested Level sets).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Replica = require(ReplicatedStorage:WaitForChild("ReplicaClient"))

local current = nil
local cashListeners, cardListeners = {}, {}

Replica.OnNew("Club", function(replica)
	current = replica
	replica:OnSet({ "Cash" }, function(value)
		for _, fn in cashListeners do
			fn(value)
		end
	end)
	replica:OnChange(function(_action, path)
		if path[1] == "Owned" then
			for _, fn in cardListeners do
				fn()
			end
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
