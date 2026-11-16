--!optimize 2
-- Ripple adapter: generated Server/Client modules + thin contract modules (modules/<schema>/).
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
