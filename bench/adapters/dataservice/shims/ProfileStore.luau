--!optimize 2
-- In-memory stand-in for lm-loleris/profilestore@1.0.3 (saving is out of scope for the benchmark).
-- Implements only what DataServiceServer calls: ProfileStore.New(index, template) -> store with
-- StartSessionAsync / Mock:StartSessionAsync / GetAsync / RemoveAsync / MessageAsync, and profiles with
-- Data, AddUserId, Reconcile, OnSessionEnd, MessageHandler, EndSession.
--
-- Loading: when `ProfileStore._awaitData` is true, StartSessionAsync yields (like a real DataStore load) until
-- the adapter supplies that key's Data with `ProfileStore._supply(key, data)`. Otherwise a new profile gets a
-- deep copy of the template, like a first-time player.

local ProfileStore = {}
ProfileStore._awaitData = false

local waiting = {} -- [key] = thread parked in StartSessionAsync
local pending = {} -- [key] = data supplied before the load started

local function deepCopy(t)
	local out = {}
	for k, v in t do
		out[k] = if type(v) == "table" then deepCopy(v) else v
	end
	return out
end

local function reconcile(target, template)
	for k, v in template do
		if type(k) == "string" and target[k] == nil then
			target[k] = if type(v) == "table" then deepCopy(v) else v
		elseif type(target[k]) == "table" and type(v) == "table" then
			reconcile(target[k], v)
		end
	end
end

-- Minimal signal (ProfileStore ships its own).
local function newSignal()
	local fns = {}
	return {
		Connect = function(_self, fn)
			table.insert(fns, fn)
			return {
				Disconnect = function()
					local i = table.find(fns, fn)
					if i then
						table.remove(fns, i)
					end
				end,
			}
		end,
		_fire = function(...)
			for _, fn in table.clone(fns) do
				fn(...)
			end
		end,
	}
end

local function newProfile(store, data)
	local profile = { Data = data }
	profile.OnSessionEnd = newSignal()
	function profile.AddUserId() end
	function profile.Reconcile(self)
		reconcile(self.Data, store._template)
	end
	function profile.MessageHandler() end
	function profile.EndSession(self)
		-- The real ProfileStore releases the session and fires OnSessionEnd.
		self.OnSessionEnd._fire()
	end
	return profile
end

function ProfileStore.New(index: string, template)
	local store = { _index = index, _template = template or {} }
	function store.StartSessionAsync(self, key: string, _params)
		local data = pending[key]
		if data ~= nil then
			pending[key] = nil
		elseif ProfileStore._awaitData then
			waiting[key] = coroutine.running()
			data = coroutine.yield()
		else
			data = deepCopy(self._template)
		end
		return newProfile(self, data)
	end
	function store.GetAsync(self, key: string)
		return self:StartSessionAsync(key)
	end
	function store.RemoveAsync() end
	function store.MessageAsync()
		return false
	end
	store.Mock = store
	return store
end

-- Adapter hook: hands `data` to the load of `key` (resumes it if it is already waiting).
function ProfileStore._supply(key: string, data)
	local thread = waiting[key]
	if thread then
		waiting[key] = nil
		task.spawn(thread, data)
	else
		pending[key] = data
	end
end

return ProfileStore
