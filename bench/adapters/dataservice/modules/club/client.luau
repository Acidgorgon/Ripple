--!optimize 2
-- Club schema on Dataservice, client side: DataServiceClient holds the club as a plain table and fires
-- path signals for every prefix of a changed path, so {"Owned", id, "Level"} also fires "Owned".
--
-- Rejoin: in Roblox a rejoining player gets a fresh client, so DataServiceClient sees exactly one init.
-- Here one client environment lives through destroy + create, and DataServiceClient asserts on a second
-- init ("Data already initialized"). The init handler is wrapped to do what the fresh client would: drop
-- the old Data object, take the new table, and reconnect the game's listeners.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataService = require(ReplicatedStorage.Packages.DataService).client

local INIT = 0 -- DataServiceUtils.enums.actions.init

local cashFns, cardFns = {}, {}

local function connectCash(fn)
	DataService:getChangedSignal({ "Cash" }):Connect(fn)
end
local function connectCards(fn)
	DataService:getChangedSignal({ "Owned" }):Connect(function()
		fn()
	end)
end

local initData = DataService[INIT]
DataService[INIT] = function(self, data)
	local old = self._data
	if old then
		old:destroy()
		self._data = nil
	end
	initData(self, data)
	for _, fn in cashFns do
		connectCash(fn)
	end
	for _, fn in cardFns do
		connectCards(fn)
	end
end

-- init() yields until the server's init arrives, as in a LocalScript.
task.spawn(DataService.init, DataService)

local api = {}

function api.onCash(fn)
	table.insert(cashFns, fn)
	if DataService._data then
		connectCash(fn)
	end
end

function api.onCards(fn)
	table.insert(cardFns, fn)
	if DataService._data then
		connectCards(fn)
	end
end

function api.get()
	if DataService._data == nil then
		return nil -- DataService:get() would yield until the first init
	end
	return DataService:get()
end

return api
