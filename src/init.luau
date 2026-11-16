-- Ripple compiler CLI:
--   ripple <schema.ripple> [--out <dir>] [--watch]          (installed binary)
--   lune run src/init.luau -- <schema.ripple> [--out <dir>]  (from a checkout)
-- Writes <dir>/Server.luau and <dir>/Client.luau (default dir: next to the schema, "<name>.ripple" -> "<name>/").
local fs = require("@lune/fs")
local process = require("@lune/process")
local task = require("@lune/task")
local Parser = require("@self/Parser")
local Generator = require("@self/Generator")

local VERSION = "0.1.0"
local BUNDLED = (_G :: any).RIPPLE_RUNTIME -- set by the single-file build (scripts/bundle.py)

local SRC_DIR = string.match(debug.info(1, "s"), "^(.*)[/\\]") or "."

local USAGE = [[
usage: ripple <schema.ripple> [--out <dir>] [--watch]

  -o, --out <dir>   where to write Server.luau and Client.luau (default: <schema name>/ next to it)
  -w, --watch       regenerate whenever the schema changes
  -v, --version     print the version]]

local args = process.args
local input, outDir, watch
local i = 1
while i <= #args do
	local a = args[i]
	if a == "--out" or a == "-o" then
		outDir = args[i + 1]
		i += 2
	elseif a == "--watch" or a == "-w" then
		watch = true
		i += 1
	elseif a == "--version" or a == "-v" then
		print("ripple " .. VERSION)
		process.exit(0)
	elseif a == "--help" or a == "-h" then
		print(USAGE)
		process.exit(0)
	elseif a == "--" then
		i += 1
	else
		input = a
		i += 1
	end
end
if not input then
	print(USAGE)
	process.exit(1)
end
outDir = outDir or (string.gsub(input, "%.ripple$", ""))

local function runtime(name)
	if BUNDLED then
		return BUNDLED[name]
	end
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

-- Returns true on success. Errors in the schema are printed, never thrown, so --watch keeps running.
local function compile(): boolean
	local okRead, src = pcall(fs.readFile, input)
	if not okRead then
		print(`ripple: cannot read {input}`)
		return false
	end
	local ok, schema = pcall(Parser.parse, src)
	if not ok then
		print(schema)
		return false
	end
	local okGen, gen = pcall(Generator.generate, schema)
	if not okGen then
		print(gen)
		return false
	end
	if not fs.isDir(outDir) then
		fs.writeDir(outDir)
	end
	fs.writeFile(outDir .. "/Server.luau", splice(runtime("Server.luau"), gen.server, gen.types))
	fs.writeFile(outDir .. "/Client.luau", splice(runtime("Client.luau"), gen.client, gen.clientTypes))
	print(`ripple: wrote {outDir}/Server.luau and {outDir}/Client.luau ({#schema.states} state(s))`)
	return true
end

local ok = compile()
if not watch then
	process.exit(if ok then 0 else 1)
end

local function stamp(): number?
	local okMeta, meta = pcall(fs.metadata, input)
	if okMeta and meta.exists and meta.modifiedAt then
		return meta.modifiedAt.unixTimestampMillis
	end
	return nil
end
print(`ripple: watching {input} (Ctrl+C to stop)`)
local last = stamp()
while true do
	task.wait(0.25)
	local now = stamp()
	if now ~= nil and now ~= last then
		last = now
		compile()
	end
end
