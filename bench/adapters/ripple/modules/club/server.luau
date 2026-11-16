--!optimize 2
local Ripple = require("./Server")
local api = {}
function api.create(player, data)
	return Ripple.Club.new(player, data)
end
function api.setCash(club, v)
	club.Cash = v
end
function api.setStat(club, key, v)
	club.Stats[key] = v
end
function api.setCard(club, id, card)
	club.Owned[id] = card
end
function api.setCardLevel(club, id, level)
	club.Owned[id].Level = level
end
function api.destroy(club)
	Ripple.destroy(club)
end
return api
