--!optimize 2
local remote = game:GetService("ReplicatedStorage"):WaitForChild("ClubSnapshot")
local current = nil
local cashListeners, cardListeners = {}, {}
remote.OnClientEvent:Connect(function(data)
	if data == false then
		current = nil
		return
	end
	local old = current
	current = data
	if old == nil or old.Cash ~= data.Cash then
		for _, fn in cashListeners do
			fn(data.Cash)
		end
	end
	-- A snapshot cannot tell what changed inside Owned without a deep compare: listeners always run.
	for _, fn in cardListeners do
		fn()
	end
end)
local api = {}
function api.onCash(fn)
	table.insert(cashListeners, fn)
end
function api.onCards(fn)
	table.insert(cardListeners, fn)
end
function api.get()
	return current
end
return api
