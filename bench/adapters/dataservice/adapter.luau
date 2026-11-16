--!optimize 2
-- Dataservice (leifstout/dataservice@1.0.0 + leifstout/networker@0.3.1 + sleitnick/signal@2.0.3).
-- Every DataService:set(player, path, value) is one Networker FireClient(player, 1, path, value) right away
-- (no batching, no buffers); the client applies it to a plain table and fires changed signals on every path
-- prefix. Library sources are copied unchanged to <outDir>/_shared/Packages (Wally layout) and mounted under
-- the server's ReplicatedStorage, so clients require them through replication, as in a game.
--
-- Shims (mock gaps, adapter only):
--   * Instance.Destroying: Networker connects `remotes.Destroying:Once(...)`; the mock has no Destroying
--     event, so every instance gets a never-firing signal on first access.
--   * Player:Kick: DataService kicks the player when the profile session ends (normal on leave); no-op here.
--   * ProfileStore: in-memory fake (shims/ProfileStore.luau), see build.sh.
local A = ...
local Mock = A.Mock

do
	local mt = getmetatable(Mock.newInstance("Folder"))
	local baseIndex = mt.__index
	local function noKick() end
	mt.__index = function(self, key)
		if key == "Destroying" then
			local signal = Mock.Signal.new()
			rawset(self, key, signal)
			return signal
		elseif key == "Kick" and rawget(self, "ClassName") == "Player" then
			return noKick
		end
		return baseIndex(self, key)
	end
end

local Adapter = {}

function Adapter.compile(schema: string, side: "server" | "client")
	local dir = `{A.outDir}/{schema}`
	if readfile(`{dir}/ok`) == nil then
		return nil, `schema {schema} was not built (see {dir}/compile.log)`
	end
	Mock.compileTree(`{A.outDir}/_shared/Packages`)
	local path = `{dir}/{side}.luau`
	Mock.compileFile(path)
	return { schema = schema, side = side, path = path }
end

function Adapter.start(handle, env)
	if handle.side == "server" then
		env:mountTree(`{A.outDir}/_shared/Packages`, env.ReplicatedStorage, "Packages")
	end
	return env:requireFile(handle.path)
end

return Adapter
