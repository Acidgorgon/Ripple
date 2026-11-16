--!optimize 2
-- Shared Reflex slice for schema "club" (required by both server and client root producers).
-- State: { [userIdString]: Club }. Keys are strings so the state survives remote serialization.
-- Every action names the owner first, which the server's beforeDispatch uses to keep it private.
local Reflex = require("../_shared/reflex/reflex")

local function withClub(state, userId: string, recipe)
	local club = state[userId]
	if club == nil then
		return state
	end
	local nextState = table.clone(state)
	local nextClub = table.clone(club)
	recipe(nextClub, club)
	nextState[userId] = nextClub
	return nextState
end

local clubs = Reflex.createProducer({} :: { [string]: any }, {
	addClub = function(state, userId: string, data)
		local nextState = table.clone(state)
		nextState[userId] = data
		return nextState
	end,
	removeClub = function(state, userId: string)
		local nextState = table.clone(state)
		nextState[userId] = nil
		return nextState
	end,
	setCash = function(state, userId: string, cash: number)
		return withClub(state, userId, function(nextClub)
			nextClub.Cash = cash
		end)
	end,
	setStat = function(state, userId: string, statKey: string, value: number)
		return withClub(state, userId, function(nextClub, club)
			local stats = table.clone(club.Stats)
			stats[statKey] = value
			nextClub.Stats = stats
		end)
	end,
	setCard = function(state, userId: string, instanceId: string, card)
		return withClub(state, userId, function(nextClub, club)
			local owned = table.clone(club.Owned)
			owned[instanceId] = card
			nextClub.Owned = owned
		end)
	end,
	setCardLevel = function(state, userId: string, instanceId: string, level: number)
		return withClub(state, userId, function(nextClub, club)
			local owned = table.clone(club.Owned)
			local card = table.clone(owned[instanceId])
			card.Level = level
			owned[instanceId] = card
			nextClub.Owned = owned
		end)
	end,
})

return { clubs = clubs }
