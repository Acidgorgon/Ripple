--!optimize 2
-- Charm + Charm Sync, schema "club". Pattern from the charm-sync README ("Quick Start"):
-- one server signal holds every player's club in a map, and each player is subscribed to a
-- player-unique key (`club-<UserId>`) bound to a computed that selects their entry, so a
-- client only ever receives its own club. Writes are immutable updates (clone the changed path).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Charm = require("../_shared/charm/packages/charm/src")
local CharmSync = require("../_shared/charm/packages/charm-sync/src")
local server = CharmSync.server

-- Sync settings: patches every frame (interval 0 = on the next Heartbeat), latest-state diffs only,
-- array fix-up on (plain RemoteEvent arguments). These are the defaults, set explicitly.
CharmSync.config.interval = 0
CharmSync.config.preserveHistory = false
CharmSync.config.fixArrays = true

local syncEvent = Instance.new("RemoteEvent")
syncEvent.Name = "CharmSyncClub"
syncEvent.Parent = ReplicatedStorage

-- store
local getClubs, setClubs = Charm.signal({} :: { [number]: any })

server.connect(function(player, payloads)
	syncEvent:FireClient(player, payloads)
end)

Players.PlayerRemoving:Connect(function(player)
	server.removeClient(player)
end)

local function updateClub(h, recipe)
	local userId = h.userId
	setClubs(function(clubs)
		local nextClubs = table.clone(clubs)
		nextClubs[userId] = recipe(clubs[userId])
		return nextClubs
	end)
end

local api = {}

-- Data loaded for a player: store it and start syncing that player's key (full state goes out as
-- the `init` payload on the next sync).
function api.create(player, data)
	local userId = player.UserId
	local key = `club-{userId}`
	setClubs(function(clubs)
		local nextClubs = table.clone(clubs)
		nextClubs[userId] = data
		return nextClubs
	end)
	server.addSignalsToClient(player, {
		[key] = Charm.computed(function()
			return getClubs()[userId]
		end),
	})
	return { player = player, userId = userId, key = key }
end

function api.setCash(h, cash)
	updateClub(h, function(club)
		local nextClub = table.clone(club)
		nextClub.Cash = cash
		return nextClub
	end)
end

function api.setStat(h, statKey, value)
	updateClub(h, function(club)
		local nextClub = table.clone(club)
		local stats = table.clone(club.Stats)
		stats[statKey] = value
		nextClub.Stats = stats
		return nextClub
	end)
end

function api.setCard(h, instanceId, card)
	updateClub(h, function(club)
		local nextClub = table.clone(club)
		local owned = table.clone(club.Owned)
		owned[instanceId] = card
		nextClub.Owned = owned
		return nextClub
	end)
end

function api.setCardLevel(h, instanceId, level)
	updateClub(h, function(club)
		local nextClub = table.clone(club)
		local owned = table.clone(club.Owned)
		local card = table.clone(club.Owned[instanceId])
		card.Level = level
		owned[instanceId] = card
		nextClub.Owned = owned
		return nextClub
	end)
end

-- Player left: unsubscribe their key (stops tracking it) and drop their data.
function api.destroy(h)
	server.removeSignalsFromClient(h.player, h.key)
	local userId = h.userId
	setClubs(function(clubs)
		local nextClubs = table.clone(clubs)
		nextClubs[userId] = nil
		return nextClubs
	end)
end

return api
