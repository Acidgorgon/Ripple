--!optimize 2
-- Match schema on Dataservice, client side: the match lives under "Match" in this player's own data.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataService = require(ReplicatedStorage.Packages.DataService).client

local clockFns = {}

-- init() yields until the server's init arrives, as in a LocalScript; listeners connect after it.
task.spawn(function()
	DataService:init()
	for _, fn in clockFns do
		DataService:getChangedSignal({ "Match", "Clock" }):Connect(fn)
	end
end)

local api = {}

function api.onClock(fn)
	table.insert(clockFns, fn)
	if DataService._data then
		DataService:getChangedSignal({ "Match", "Clock" }):Connect(fn)
	end
end

function api.get()
	if DataService._data == nil then
		return nil -- DataService:get() would yield until the first init
	end
	return DataService:get({ "Match" })
end

return api
