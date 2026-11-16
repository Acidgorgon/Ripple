--!optimize 2
-- Reports, for each generated module given on the command line, the native
-- code size produced by the codegen and the live heap the compiled chunk
-- occupies (bytecode protos, constants, debug info). Run with --codegen.
--
--   luau-bench -O2 --codegen lib/static_metrics.luau <benchRoot> <file.luau>...

local benchRoot = arg[1]
local function import(path: string)
	local fn = assert(loadstring(readfile(path) or error(`cannot read {path}`), "@" .. path))
	return fn()
end
local Json = import(`{benchRoot}/lib/json.luau`)
local Mock = import(`{benchRoot}/lib/mock.luau`)

local out = {}
local keep = {}
for i = 2, #arg do
	local path = arg[i]
	__gc("collect")
	local live0 = __live_bytes()
	local native0 = __native_code_bytes()
	local chunk = Mock.compileFile(path)
	__gc("collect")
	out[path] = {
		native_code_bytes = __native_code_bytes() - native0,
		chunk_heap_bytes = __live_bytes() - live0,
	}
	table.insert(keep, chunk)
end
print(Json.encode(out))
