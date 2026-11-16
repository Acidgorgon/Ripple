--!optimize 2
-- loleris' ReplicaService (standalone version), github.com/MadStudioRoblox/ReplicaService.
-- Every server setter (SetValue / SetValues / Destroy) fires its RemoteEvent call immediately, once per
-- replicated active player: there is no batching / flush interval to configure.
--
-- The library is mounted where its Rojo project puts it: ReplicatedStorage.{ReplicaController,
-- MadworkScriptSignal, MadworkMaid, RateLimiter} and ServerScriptService.ReplicaService. The per-schema
-- modules require it the way a game does. The Examples folder (ServerStorage) and the Experimental
-- listeners module are not mounted.
--
-- Shims (adapter only; the library source is unmodified):
--   1. game:IsLoaded() on clients (the mock DataModel lacks it): returns true.
--      ReplicaController.RequestData() waits for it before firing the request.
--   2. task.wait: the mock errors on it. RequestData() spawns a thread that fires the request and then
--      loops `while task.wait(10) do <re-request if no data yet> end`. The shim yields that thread
--      forever (the mock has no wall time, like its task.delay), i.e. the 10 s retry never comes due.
--   3. Join handshake: each client's start pumps the mock network once (RequestData to the server, the
--      initial replica package + "data sent" back) so every player is an ActivePlayer before the
--      scenario's setup creates replicas, like a real join where the handshake precedes gameplay.
--      (ReplicaService would otherwise keep the replica pending and send it a frame later.) Counted in
--      client init.
local A = ...
local Mock = A.Mock
local LIB = `{A.outDir}/_shared/replicaservice`
local RS = `{LIB}/ReplicatedStorage`

local SHARED = { "MadworkScriptSignal", "MadworkMaid", "RateLimiter" }

local Adapter = {}

function Adapter.compile(schema: string, side: "server" | "client")
	local dir = `{A.outDir}/{schema}`
	if readfile(`{dir}/ok`) == nil then
		return nil, `schema {schema} was not built (see {dir}/compile.log)`
	end
	for _, name in SHARED do
		Mock.compileFile(`{RS}/{name}.lua`)
	end
	if side == "server" then
		Mock.compileFile(`{LIB}/ServerScriptService/ReplicaService.lua`)
	else
		Mock.compileFile(`{RS}/ReplicaController.lua`)
	end
	local path = `{dir}/{side}.luau`
	Mock.compileFile(path)
	return { schema = schema, side = side, path = path }
end

function Adapter.start(handle, env)
	local world = env.world
	-- Shim 2.
	world.task.wait = function()
		return coroutine.yield()
	end
	if env.isServer then
		if env.ReplicatedStorage:FindFirstChild("ReplicaController") == nil then
			for _, name in SHARED do
				env:mountTree(`{RS}/{name}.lua`, env.ReplicatedStorage, name)
			end
			env:mountTree(`{RS}/ReplicaController.lua`, env.ReplicatedStorage, "ReplicaController")
			env:mountTree(`{LIB}/ServerScriptService/ReplicaService.lua`, env.ServerScriptService, "ReplicaService")
		end
		return env:requireFile(handle.path)
	end
	-- Shim 1.
	rawset(env.game, "IsLoaded", function()
		return true
	end)
	local api = env:requireFile(handle.path) -- calls ReplicaController.RequestData()
	-- Shim 3.
	world:deliver()
	world:receiveServer()
	world:deliver()
	world:receiveClient(env.index)
	return api
end

return Adapter
