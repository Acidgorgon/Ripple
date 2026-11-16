--!optimize 2
local Ripple = require("./Client")
local clockFns = {}
Ripple.Match.added(function(m)
	Ripple.changed(m, "Clock", function(v)
		for _, fn in clockFns do
			fn(v)
		end
	end)
end)
local api = {}
function api.onClock(fn)
	table.insert(clockFns, fn)
end
function api.get()
	return Ripple.Match.get()
end
return api
