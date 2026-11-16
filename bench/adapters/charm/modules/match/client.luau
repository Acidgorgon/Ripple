--!optimize 2
-- Charm + Charm Sync client, schema "match".
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Charm = require("../_shared/charm/packages/charm/src")
local CharmSync = require("../_shared/charm/packages/charm-sync/src")
local client = CharmSync.client

local syncEvent = ReplicatedStorage:WaitForChild("CharmSyncMatch")

local getMatch, setMatch = Charm.signal(nil :: any)
client.addSignals({ match = setMatch })

syncEvent.OnClientEvent:Connect(function(payloads)
	client.patch(payloads)
end)

local function selectClock()
	local match = getMatch()
	return if match then match.Clock else nil
end

local api = {}
function api.onClock(fn)
	Charm.subscribe(selectClock, function(clock)
		fn(clock)
	end)
end
function api.get()
	return getMatch()
end
return api
