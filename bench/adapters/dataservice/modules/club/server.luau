--!optimize 2
-- Club schema on Dataservice: each player's club IS that player's DataService data (one table per player).
-- create(player, data): the player's profile load (started by Players.PlayerAdded) receives `data` from the
--   in-memory ProfileStore fake; DataService then sends the whole table to the client (action init).
-- destroy(player): Players.PlayerRemoving -> DataService ends the session and drops the player's data.
--   A later create() fires Players.PlayerAdded again (a rejoin).
-- Writes are plain DataService:set calls, each replicated immediately.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Packages = ReplicatedStorage.Packages
local DataService = require(Packages.DataService).server
local ProfileStore = require(Packages.ProfileStore) -- in-memory fake (adapter shim)

ProfileStore._awaitData = true -- profiles load with the club handed to create()

DataService:init({
	template = {},
	useMock = true, -- DataService's documented test mode (Mock store); the store is faked anyway
})

-- Fires a mock Players signal the way the engine does (each connection in its own thread).
local function firePlayers(signal, player)
	for _, fn in table.clone(signal._fns) do
		task.spawn(fn, player)
	end
end

local left = {} -- [player] = true after destroy (next create is a rejoin)

local api = {}

function api.create(player, data)
	if left[player] then
		left[player] = nil
		firePlayers(Players.PlayerAdded, player)
	end
	ProfileStore._supply("PLAYER_" .. player.UserId, data)
	return player
end

function api.setCash(player, v)
	DataService:set(player, { "Cash" }, v)
end

function api.setStat(player, key, v)
	DataService:set(player, { "Stats", key }, v)
end

function api.setCard(player, id, card)
	DataService:set(player, { "Owned", id }, card)
end

function api.setCardLevel(player, id, level)
	DataService:set(player, { "Owned", id, "Level" }, level)
end

function api.destroy(player)
	left[player] = true
	firePlayers(Players.PlayerRemoving, player)
end

return api
