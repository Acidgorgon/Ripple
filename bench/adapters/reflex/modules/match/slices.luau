--!optimize 2
-- Shared Reflex slice for schema "match".
local Reflex = require("../_shared/reflex/reflex")

local function update(state, recipe)
	local nextState = table.clone(state)
	recipe(nextState, state)
	return nextState
end

local match = Reflex.createProducer(nil :: any, {
	setMatch = function(_state, data)
		return data
	end,
	setClock = function(state, clock: number)
		return update(state, function(nextState)
			nextState.Clock = clock
		end)
	end,
	setStamina = function(state, index: number, stamina: number)
		return update(state, function(nextState)
			local players = table.clone(state.Players)
			local p = table.clone(players[index])
			p.Stamina = stamina
			players[index] = p
			nextState.Players = players
		end)
	end,
	setScore = function(state, home: number, away: number)
		return update(state, function(nextState)
			nextState.HomeScore = home
			nextState.AwayScore = away
		end)
	end,
	setPhase = function(state, phase: number)
		return update(state, function(nextState)
			nextState.Phase = phase
		end)
	end,
})

return { match = match }
