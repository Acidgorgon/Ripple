--!optimize 2
local Ripple = require("./Client")
local cashFns, cardFns = {}, {}
Ripple.Club.added(function(club)
	Ripple.changed(club, "Cash", function(v)
		for _, fn in cashFns do
			fn(v)
		end
	end)
	Ripple.changed(club, "Owned", function()
		for _, fn in cardFns do
			fn()
		end
	end)
end)
local api = {}
function api.onCash(fn)
	table.insert(cashFns, fn)
end
function api.onCards(fn)
	table.insert(cardFns, fn)
end
function api.get()
	return Ripple.Club.get()
end
return api
