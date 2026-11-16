--!optimize 2
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local remote = Instance.new("RemoteEvent")
remote.Name = "ClubSnapshot"
remote.Parent = ReplicatedStorage

local dirty = {} -- [handle] = true
RunService.Heartbeat:Connect(function()
	for h in dirty do
		if h.alive then
			remote:FireClient(h.player, h.data)
		end
		dirty[h] = nil
	end
end)

local api = {}
function api.create(player, data)
	local h = { player = player, data = data, alive = true }
	dirty[h] = true
	return h
end
function api.setCash(h, v)
	h.data.Cash = v
	dirty[h] = true
end
function api.setStat(h, key, v)
	h.data.Stats[key] = v
	dirty[h] = true
end
function api.setCard(h, id, card)
	h.data.Owned[id] = card
	dirty[h] = true
end
function api.setCardLevel(h, id, level)
	h.data.Owned[id].Level = level
	dirty[h] = true
end
function api.destroy(h)
	h.alive = false
	dirty[h] = nil
	remote:FireClient(h.player, false)
end
return api
