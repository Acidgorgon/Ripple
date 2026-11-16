--!optimize 2
-- Charm + Charm Sync client, schema "club": a local signal receives this player's club key.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Charm = require("../_shared/charm/packages/charm/src")
local CharmSync = require("../_shared/charm/packages/charm-sync/src")
local client = CharmSync.client

local syncEvent = ReplicatedStorage:WaitForChild("CharmSyncClub")

local getClub, setClub = Charm.signal(nil :: any)

client.addSignals({
	[`club-{Players.LocalPlayer.UserId}`] = setClub,
})

syncEvent.OnClientEvent:Connect(function(payloads)
	client.patch(payloads)
end)

local function selectCash()
	local club = getClub()
	return if club then club.Cash else nil
end

local function selectOwned()
	local club = getClub()
	return if club then club.Owned else nil
end

local api = {}
function api.onCash(fn)
	Charm.subscribe(selectCash, function(cash)
		fn(cash)
	end)
end
function api.onCards(fn)
	Charm.subscribe(selectOwned, function()
		fn()
	end)
end
function api.get()
	return getClub()
end
return api
