--!optimize 2
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local remote = Instance.new("RemoteEvent")
remote.Name = "MatchSnapshot"
remote.Parent = ReplicatedStorage

local states = {}
RunService.Heartbeat:Connect(function()
	for h in states do
		if h.dirty then
			h.dirty = false
			remote:FireAllClients(h.data)
		end
	end
end)
local api = {}
function api.create(data)
	local h = { data = data, dirty = true }
	states[h] = true
	return h
end
function api.setClock(h, v)
	h.data.Clock = v
	h.dirty = true
end
function api.setStamina(h, k, v)
	h.data.Players[k].Stamina = v
	h.dirty = true
end
function api.setScore(h, home, away)
	h.data.HomeScore = home
	h.data.AwayScore = away
	h.dirty = true
end
function api.setPhase(h, v)
	h.data.Phase = v
	h.dirty = true
end
return api
