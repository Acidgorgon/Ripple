--!optimize 2
local remote = game:GetService("ReplicatedStorage"):WaitForChild("MatchSnapshot")
local current = nil
local clockListeners = {}
remote.OnClientEvent:Connect(function(data)
	local old = current
	current = data
	if old == nil or old.Clock ~= data.Clock then
		for _, fn in clockListeners do
			fn(data.Clock)
		end
	end
end)
local api = {}
function api.onClock(fn)
	table.insert(clockListeners, fn)
end
function api.get()
	return current
end
return api
