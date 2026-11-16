--!optimize 2
-- Charm (signals) + Charm Sync (littensy/charm monorepo: charm 0.11.x, charm-sync 0.4.x).
-- The library is mounted per machine as an Instance tree (Rojo layout) so that charm-sync's
-- `Charm.luau` link (`require(script.Parent.Parent.charm.src)`) and its string requires both resolve.
-- Shim (mock gap only): `debug.profilebegin/profileend` (Roblox-only, used by charm-sync's Heartbeat
-- interval) are installed as no-ops when missing.
local A = ...
local Adapter = {}

if debug.profilebegin == nil then
	debug.profilebegin = function(_label: string) end
	debug.profileend = function() end
end

function Adapter.compile(schema: string, side: "server" | "client")
	local dir = `{A.outDir}/{schema}`
	if readfile(`{dir}/ok`) == nil then
		return nil, `schema {schema} was not built (see {dir}/compile.log)`
	end
	local path = `{dir}/{side}.luau`
	A.Mock.compileFile(path)
	A.Mock.compileTree(`{A.outDir}/_shared/charm`)
	return { schema = schema, side = side, path = path }
end

function Adapter.start(handle, env)
	-- Each machine gets its own (unparented) copy of the package tree, like a client's own DataModel.
	if not env._charmMounted then
		env._charmMounted = true
		env:mountTree(`{A.outDir}/_shared/charm/packages`, nil, "Packages")
	end
	return env:requireFile(handle.path)
end

return Adapter
