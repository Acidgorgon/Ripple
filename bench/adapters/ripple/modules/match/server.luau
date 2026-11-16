--!optimize 2
local Ripple = require("./Server")
local api = {}
function api.create(data)
	return Ripple.Match.new(data)
end
function api.setClock(m, v)
	m.Clock = v
end
function api.setStamina(m, k, v)
	m.Players[k].Stamina = v
end
function api.setScore(m, home, away)
	m.HomeScore = home
	m.AwayScore = away
end
function api.setPhase(m, v)
	m.Phase = v
end
return api
