-- Ripple compiler CLI:  lune run src/init.luau -- <schema.ripple> [--out <dir>]
-- Writes <dir>/Server.luau and <dir>/Client.luau (default dir: next to the schema, "<name>.ripple" -> "<name>/").
local fs = require("@lune/fs")
local process = require("@lune/process")
local Parser = require("@self/Parser")
local Generator = require("@self/Generator")

local SRC_DIR = string.match(debug.info(1, "s"), "^(.*)[/\\]") or "."

local args = process.args
local input, outDir
local i = 1
while i <= #args do
	local a = args[i]
	if a == "--out" or a == "-o" then
		outDir = args[i + 1]
		i += 2
	else
		input = a
		i += 1
	end
end
if not input then
	print("usage: ripple <schema.ripple> [--out <dir>]")
	process.exit(1)
end
outDir = outDir or (string.gsub(input, "%.ripple$", ""))

local ok, schema = pcall(Parser.parse, fs.readFile(input))
if not ok then
	print(schema)
	process.exit(1)
end
local gen = Generator.generate(schema)

local function runtime(name)
	for _, base in { SRC_DIR .. "/runtime/", "src/runtime/" } do
		local path = base .. name
		if fs.isFile(path) then
			return fs.readFile(path)
		end
	end
	error("runtime template not found: " .. name)
end

local function splice(template: string, body: string, types: string): string
	local a, b = string.find(template, "--@@GENERATED@@", 1, true)
	assert(a, "template marker missing")
	return string.sub(template, 1, a - 1) .. types .. "\n\n" .. body .. string.sub(template, b + 1)
end

if not fs.isDir(outDir) then
	fs.writeDir(outDir)
end
fs.writeFile(outDir .. "/Server.luau", splice(runtime("Server.luau"), gen.server, gen.types))
fs.writeFile(outDir .. "/Client.luau", splice(runtime("Client.luau"), gen.client, gen.clientTypes))
print(`ripple: wrote {outDir}/Server.luau and {outDir}/Client.luau ({#schema.states} state(s))`)
