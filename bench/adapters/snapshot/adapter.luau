--!optimize 2
-- Full-snapshot baseline: what a game does without a replication library (FM's ClubChanged before deltas).
-- Writes mutate a plain server table and mark it dirty; on Heartbeat every dirty state is sent WHOLE with
-- one FireClient per subscriber; the client replaces its copy and fires its listeners.
-- Caveat: the mock does not model Roblox's C++ cost of serializing table arguments, so CPU is a lower bound;
-- wire bytes are the mock's estimate of Roblox's encoding.
local A = ...
local Adapter = {}
function Adapter.compile(schema: string, side: "server" | "client")
	local dir = `{A.outDir}/{schema}`
	if readfile(`{dir}/ok`) == nil then
		return nil, `schema {schema} was not built (see {dir}/compile.log)`
	end
	local path = `{dir}/{side}.luau`
	A.Mock.compileFile(path)
	return { schema = schema, side = side, path = path }
end
function Adapter.start(handle, env)
	return env:requireFile(handle.path)
end
return Adapter
