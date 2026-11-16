--!optimize 2
-- loleris' Replica (2025 successor of ReplicaService), github.com/MadStudioRoblox/Replica.
-- The library replicates every server write immediately: each Replica:Set() fires one
-- RemoteEvent call per subscribed ready player (there is no batching / flush interval to set).
--
-- The library tree is mounted where its Rojo project puts it:
--   ReplicatedStorage.ReplicaShared (Remote, Signal, Maid, RateLimit), ReplicatedStorage.ReplicaClient,
--   ServerScriptService.ReplicaServer
-- and the per-schema modules require it the way a game does (require(ServerScriptService.ReplicaServer)).
--
-- Shims (adapter only; the library source is unmodified):
--   1. CollectionService: the mock has none. Replica uses it only for BindToInstance (tag the bind
--      NumberValue / watch tagged instances), which the benchmark never calls, so it gets a stub service
--      (AddTag/RemoveTag/HasTag no-ops, GetTagged -> {}, Get*Signal -> a mock Signal that never fires).
--   2. task.wait: the mock errors on it. ReplicaClient.RequestData() spawns a thread that fires the
--      request and then loops `while task.wait(2) do <re-request if not ready> end`. The shim yields the
--      thread forever (the mock has no wall time, like its task.delay), i.e. the 2 s retry never comes due.
--   3. Join handshake: Replica only subscribes "ready" players (those whose RequestData reached the
--      server). Like a real join, where the handshake completes before gameplay, each client's start
--      pumps the mock network once (client -> server RequestData, server -> client initial creation +
--      ready signal) so the scenario's setup sees every player ready. This is counted in client init.
local A = ...
local Mock = A.Mock
local LIB = `{A.outDir}/_shared/replica`

local LIB_SERVER = {
	`{LIB}/ReplicatedStorage/ReplicaShared/Signal.luau`,
	`{LIB}/ReplicatedStorage/ReplicaShared/Maid.luau`,
	`{LIB}/ReplicatedStorage/ReplicaShared/Remote.luau`,
	`{LIB}/ReplicatedStorage/ReplicaShared/RateLimit.luau`,
	`{LIB}/ServerScriptService/ReplicaServer.luau`,
}
local LIB_CLIENT = {
	`{LIB}/ReplicatedStorage/ReplicaShared/Signal.luau`,
	`{LIB}/ReplicatedStorage/ReplicaShared/Maid.luau`,
	`{LIB}/ReplicatedStorage/ReplicaShared/Remote.luau`,
	`{LIB}/ReplicatedStorage/ReplicaClient.luau`,
}

local Adapter = {}

function Adapter.compile(schema: string, side: "server" | "client")
	local dir = `{A.outDir}/{schema}`
	if readfile(`{dir}/ok`) == nil then
		return nil, `schema {schema} was not built (see {dir}/compile.log)`
	end
	for _, path in if side == "server" then LIB_SERVER else LIB_CLIENT do
		Mock.compileFile(path)
	end
	local path = `{dir}/{side}.luau`
	Mock.compileFile(path)
	return { schema = schema, side = side, path = path }
end

-- Shim 1: stub CollectionService.
local function addCollectionService(env)
	local game = env.game
	if game:FindFirstChild("CollectionService") then
		return
	end
	local cs = Mock.newInstance("CollectionService")
	local signals = {}
	local function signal(kind: string, tag: string)
		local key = kind .. tag
		local s = signals[key]
		if s == nil then
			s = Mock.Signal.new()
			signals[key] = s
		end
		return s
	end
	rawset(cs, "AddTag", function() end)
	rawset(cs, "RemoveTag", function() end)
	rawset(cs, "HasTag", function()
		return false
	end)
	rawset(cs, "GetTagged", function()
		return {}
	end)
	rawset(cs, "GetInstanceAddedSignal", function(_self, tag)
		return signal("+", tag)
	end)
	rawset(cs, "GetInstanceRemovedSignal", function(_self, tag)
		return signal("-", tag)
	end)
	cs.Parent = game
end

-- Shim 2: task.wait yields forever.
local function patchTaskWait(world)
	world.task.wait = function()
		return coroutine.yield()
	end
end

-- Shim 4: Roblox serializes remote arguments at the Fire* call; the mock deep-copies tables only at
-- delivery. ReplicaServer fires ReplicaCreate with the replica group's shared `creation` map and
-- Replica:Destroy() later removes the entry from that same map, so a replica created and destroyed
-- within one frame (scenario setup + frame 1 rejoin) would reach the client as an empty creation
-- followed by a destroy of an unknown id. The ReplicaCreate remote's FireClient therefore clones the
-- creation map(s) (one level: id -> self_creation entry) at the call. Replica data itself is still
-- copied at delivery (later Sets in the same frame are idempotent on it).
local function patchCreateSnapshot(env)
	local container = env.ReplicatedStorage:FindFirstChild("RemoteEvents")
	local remote = container and container:FindFirstChild("ReplicaCreate")
	if remote == nil or rawget(remote, "_adapterPatched") then
		return
	end
	rawset(remote, "_adapterPatched", true)
	local fire = rawget(remote, "FireClient")
	rawset(remote, "FireClient", function(self, player, creation, ...)
		local copy
		if type(creation[1]) == "table" then -- pack: { creation, ... }
			copy = table.create(#creation)
			for i, c in creation do
				copy[i] = table.clone(c)
			end
		else
			copy = table.clone(creation)
		end
		return fire(self, player, copy, ...)
	end)
end

function Adapter.start(handle, env)
	local world = env.world
	patchTaskWait(world)
	addCollectionService(env)
	if env.isServer then
		if env.ReplicatedStorage:FindFirstChild("ReplicaShared") == nil then
			env:mountTree(`{LIB}/ReplicatedStorage/ReplicaShared`, env.ReplicatedStorage, "ReplicaShared")
			env:mountTree(`{LIB}/ReplicatedStorage/ReplicaClient.luau`, env.ReplicatedStorage, "ReplicaClient")
			env:mountTree(`{LIB}/ServerScriptService/ReplicaServer.luau`, env.ServerScriptService, "ReplicaServer")
		end
		local api = env:requireFile(handle.path)
		patchCreateSnapshot(env)
		return api
	end
	local api = env:requireFile(handle.path) -- calls Replica.RequestData()
	-- Shim 3: complete the join handshake for this client.
	world:deliver()
	world:receiveServer()
	world:deliver()
	world:receiveClient(env.index)
	return api
end

return Adapter
