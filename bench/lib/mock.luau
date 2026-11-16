--!optimize 2
-- Roblox mock environment for running networking libraries (Blink/Zap
-- generated modules, ByteNet-style ModuleScript libraries, plain RemoteEvent
-- code) under a plain Luau VM (the luau-bench host), with one server and N
-- simulated clients living in the same VM.
--
-- Overview
--   World            one server + N clients ("machines"), the network between
--                    them, and one task scheduler.
--   Environment      a machine: its own DataModel (`game`), `_G`, `shared`,
--                    module cache. world.server and world.clients[i].
--   Instances        a small Instance model (Name/ClassName/Parent/children,
--                    FindFirstChild, WaitForChild, GetChildren, IsA, Destroy,
--                    attributes, `inst.ChildName` lookup).
--   Replication      instances the server parents under ReplicatedStorage or
--                    Workspace are visible to every client through lazily
--                    created per-client replicas (so each client has its own
--                    RemoteEvent endpoint with its own OnClientEvent).
--   Remotes          RemoteEvent / UnreliableRemoteEvent with any arguments.
--                    Firing only QUEUES the call (allocation-free in steady
--                    state). `World:deliver()` is the network phase: it deep
--                    copies arguments (buffers and tables are copied, like
--                    Roblox does), estimates wire bytes, and fills receiver
--                    inboxes. `World:receiveClient(i)` / `World:receiveServer()`
--                    then run the OnClientEvent / OnServerEvent handlers.
--   Modules          `Mock.compileFile(path)` compiles once (shared code);
--                    `env:requireFile(path)` / `require(moduleScript)` /
--                    `require("./relative")` instantiate per environment.
--                    `env:mountTree(diskDir, parent, name)` exposes a library
--                    directory (Rojo layout: init.luau + children) as a
--                    ModuleScript/Folder tree so `script.Parent.X` works.
--
-- How mocks are injected: every module is compiled with ONE extra line
-- inserted right after its leading `--!` directive comments:
--     local game, workspace, Instance, task, warn, typeof, _G, shared, script, require = ...
-- and instantiated by calling the chunk with that environment's values. No
-- setfenv/getfenv is used, so the global environment stays "safe": imports and
-- builtin fastcalls (buffer.*, bit32.*, Vector3.new -> vector builtin) keep
-- working exactly as in Roblox. Stateless Roblox globals (Vector3, tick, time)
-- are installed as real globals by `Mock.installGlobals()`.

local Mock = {}

--------------------------------------------------------------------------------
-- Stateless globals
--------------------------------------------------------------------------------

-- Native Luau vectors behave like Vector3 for everything these libraries need:
-- .X/.Y/.Z, equality, arithmetic. (No .Magnitude/.Unit: avoid range-validated
-- vectors such as Blink's `vector(0..1)` in scenarios.)
function Mock.installGlobals()
	Vector3 = table.freeze({
		new = vector.create,
		zero = vector.zero,
		one = vector.one,
	})
	tick = os.clock
	time = os.clock
	-- Load-time stub only: some libraries build CFrame lookup tables when
	-- they load (QuickNet's axis alignments). The values are opaque; no
	-- scenario sends a CFrame, and doing CFrame math on them errors.
	local cframeMT = { __robloxtype = "CFrame" }
	local function cframe(position: vector?)
		return table.freeze(setmetatable({ Position = position or vector.zero }, cframeMT))
	end
	CFrame = table.freeze({
		identity = cframe(),
		new = function(x, y, z)
			return cframe(if type(x) == "number" then vector.create(x, y, z) else x)
		end,
		fromMatrix = function(position)
			return cframe(position)
		end,
		Angles = function()
			return cframe()
		end,
		fromEulerAnglesXYZ = function()
			return cframe()
		end,
	})
	-- Load-time stub only: `Enum.<Type>.<Item>` gives a stable placeholder item
	-- (Name, Value, EnumType) for libraries that list enum items when they load
	-- (QuickNet's TweenInfo tables, Packet's Enums list). No scenario sends one.
	local itemMT = { __robloxtype = "EnumItem" }
	local typeMT = { __robloxtype = "Enum" }
	function typeMT.__index(enumType, itemName)
		local count = rawget(enumType, "_count") + 1
		rawset(enumType, "_count", count)
		local item = setmetatable({ Name = itemName, Value = count - 1, EnumType = enumType }, itemMT)
		rawset(enumType, itemName, item)
		return item
	end
	Enum = setmetatable({}, {
		__index = function(enums, typeName)
			local enumType = setmetatable({ Name = typeName, _count = 0 }, typeMT)
			rawset(enums, typeName, enumType)
			return enumType
		end,
	})
end

--------------------------------------------------------------------------------
-- Signal: a minimal RBXScriptSignal
--------------------------------------------------------------------------------

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local fns = self._signal._fns
	local index = table.find(fns, self._fn)
	if index then
		table.remove(fns, index)
	end
end

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _fns = {} }, Signal)
end

function Signal:Connect(fn)
	table.insert(self._fns, fn)
	return setmetatable({ Connected = true, _signal = self, _fn = fn }, Connection)
end

function Signal:Once(fn)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Wait()
	error("Signal:Wait() is not supported by the benchmark mock (would yield the frame)")
end

-- Fires connections directly on the calling thread. Roblox runs each
-- connection in an engine thread; that engine cost is identical for every
-- library, so it is left out of the measurement.
function Signal:_fireDirect(...)
	local fns = self._fns
	for i = 1, #fns do
		fns[i](...)
	end
end

Mock.Signal = Signal

--------------------------------------------------------------------------------
-- typeof: Roblox-flavoured
--------------------------------------------------------------------------------

local rawtypeof = typeof

local function robloxTypeof(value: any): string
	local t = rawtypeof(value)
	if t == "vector" then
		return "Vector3"
	elseif t == "table" then
		local mt = getmetatable(value)
		if type(mt) == "table" and rawget(mt, "__robloxtype") then
			return rawget(mt, "__robloxtype")
		end
	end
	return t
end

Mock.typeof = robloxTypeof

--------------------------------------------------------------------------------
-- task library (one per world; Roblox has one scheduler per VM)
--------------------------------------------------------------------------------

local function newTaskLib()
	local deferred = {}
	local deferredCount = 0

	local function resume(co, ...)
		local ok, err = coroutine.resume(co, ...)
		if not ok then
			-- Roblox would only log the error; we fail loudly because listener
			-- errors in this harness mean a correctness check failed.
			error(debug.traceback(co, tostring(err)), 0)
		end
	end

	local lib = {}

	-- Like Roblox: a function argument always gets a brand new thread.
	function lib.spawn(fnOrThread, ...)
		local co = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
		resume(co, ...)
		return co
	end

	function lib.defer(fnOrThread, ...)
		local co = if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
		deferredCount += 1
		deferred[deferredCount] = table.pack(co, ...)
		return co
	end

	function lib.cancel(thread)
		coroutine.close(thread)
	end

	function lib.wait()
		error("task.wait is not supported by the benchmark mock (would yield the frame)")
	end

	-- The mock does not model wall time: a delayed call gets its thread (the
	-- allocation Roblox makes too) but is never resumed. Libraries use delays
	-- only for timeouts/watchdogs that a working run never reaches.
	function lib.delay(_seconds, fnOrThread, ...)
		return if type(fnOrThread) == "thread" then fnOrThread else coroutine.create(fnOrThread)
	end

	function lib.synchronize() end
	function lib.desynchronize() end

	-- Resumes deferred threads until the queue is empty (Roblox resumes
	-- deferred threads at the end of each resumption point).
	function lib._runDeferred()
		local i = 1
		while i <= deferredCount do
			local rec = deferred[i]
			deferred[i] = nil
			resume(rec[1], table.unpack(rec, 2, rec.n))
			i += 1
		end
		deferredCount = 0
	end

	return lib
end

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------

-- Instance objects are tables. Name and ClassName are raw fields; Parent is
-- virtual (stored in _parent, maintained through __index/__newindex) so that
-- reparenting keeps the children lists consistent. Methods a hot path may
-- call (FireClient, GetPlayers, ...) are stored as raw fields for speed.

local Instance = {} -- shared methods
local InstanceMT = { __robloxtype = "Instance" }

local IS_A = {
	RemoteEvent = { RemoteEvent = true, BaseRemoteEvent = true },
	UnreliableRemoteEvent = { UnreliableRemoteEvent = true, BaseRemoteEvent = true },
	ModuleScript = { ModuleScript = true, LuaSourceContainer = true },
	Player = { Player = true },
}

function InstanceMT.__index(self, key)
	if key == "Parent" then
		return rawget(self, "_parent")
	end
	local method = Instance[key]
	if method ~= nil then
		return method
	end
	-- Per-instance property signals, created on first use (they never fire:
	-- the mock does not change properties behind a library's back).
	if key == "Changed" or key == "AttributeChanged" then
		local signal = Signal.new()
		rawset(self, key, signal)
		return signal
	end
	-- Replicas read through to properties the server set on the original
	-- (e.g. StringValue.Value), like Roblox property replication.
	local server = rawget(self, "_server")
	if server ~= nil and type(key) == "string" and string.sub(key, 1, 1) ~= "_" then
		local value = rawget(server, key)
		if value ~= nil and type(value) ~= "function" then
			return value
		end
	end
	return Instance.FindFirstChild(self, key)
end

function InstanceMT.__newindex(self, key, value)
	if key == "Parent" then
		local old = rawget(self, "_parent")
		if old == value then
			return
		end
		if old ~= nil then
			local siblings = rawget(old, "_children")
			local index = table.find(siblings, self)
			if index then
				table.remove(siblings, index)
			end
		end
		rawset(self, "_parent", value)
		if value ~= nil then
			local children = rawget(value, "_children")
			if children == nil then
				error(`cannot parent {rawget(self, "Name")} to {tostring(value)}: not a mock instance`)
			end
			table.insert(children, self)
		end
		return
	end
	rawset(self, key, value)
end

function InstanceMT.__tostring(self)
	return rawget(self, "Name")
end

local function newInstance(className: string, name: string?)
	return setmetatable({
		ClassName = className,
		Name = name or className,
		_children = {},
		_attributes = {},
	}, InstanceMT)
end

Mock.newInstance = newInstance

function Mock.isInstance(v): boolean
	return type(v) == "table" and getmetatable(v) == InstanceMT
end

function Instance.GetChildren(self)
	local resolve = rawget(self, "_resolveChildren")
	if resolve then
		return resolve(self)
	end
	return table.clone(rawget(self, "_children"))
end

function Instance.FindFirstChild(self, name: string, recursive: boolean?)
	local children = Instance.GetChildren(self)
	for _, child in children do
		if rawget(child, "Name") == name then
			return child
		end
	end
	if recursive then
		for _, child in children do
			local found = Instance.FindFirstChild(child, name, true)
			if found then
				return found
			end
		end
	end
	return nil
end

function Instance.FindFirstChildOfClass(self, className: string)
	for _, child in Instance.GetChildren(self) do
		if rawget(child, "ClassName") == className then
			return child
		end
	end
	return nil
end

function Instance.FindFirstChildWhichIsA(self, className: string)
	for _, child in Instance.GetChildren(self) do
		if Instance.IsA(child, className) then
			return child
		end
	end
	return nil
end

function Instance.WaitForChild(self, name: string)
	local child = Instance.FindFirstChild(self, name)
	if child == nil then
		error(`WaitForChild("{name}") on {rawget(self, "Name")} would yield forever (nothing created it)`)
	end
	return child
end

function Instance.GetDescendants(self)
	local out = {}
	local function walk(inst)
		for _, child in Instance.GetChildren(inst) do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(self)
	return out
end

function Instance.IsA(self, className: string): boolean
	local cls = rawget(self, "ClassName")
	if cls == className or className == "Instance" then
		return true
	end
	local set = IS_A[cls]
	return set ~= nil and set[className] == true
end

function Instance.IsDescendantOf(self, ancestor): boolean
	local p = rawget(self, "_parent")
	while p ~= nil do
		if p == ancestor then
			return true
		end
		p = rawget(p, "_parent")
	end
	return false
end

function Instance.GetFullName(self): string
	local parts = {}
	local inst = self
	while inst ~= nil and rawget(inst, "ClassName") ~= "DataModel" do
		table.insert(parts, 1, rawget(inst, "Name"))
		inst = rawget(inst, "_parent")
	end
	return table.concat(parts, ".")
end

function Instance.Destroy(self)
	self.Parent = nil
end

function Instance.ClearAllChildren(self)
	for _, child in table.clone(rawget(self, "_children")) do
		child.Parent = nil
	end
end

function Instance.GetAttribute(self, name: string)
	return rawget(self, "_attributes")[name]
end

function Instance.SetAttribute(self, name: string, value: any)
	rawget(self, "_attributes")[name] = value
end

function Instance.GetAttributes(self)
	return table.clone(rawget(self, "_attributes"))
end

function Instance.GetPropertyChangedSignal()
	return Signal.new()
end

--------------------------------------------------------------------------------
-- Argument copying and wire size estimate
--------------------------------------------------------------------------------

local function varintSize(n: number): number
	if n < 128 then
		return 1
	elseif n < 16384 then
		return 2
	end
	return 3
end

-- Rough estimate of Roblox's encoding of one remote argument, in bytes:
-- 1 type byte plus payload (number 8, vector 12, Instance 4, string/buffer
-- varint length + bytes, table varint count + entries; array-like tables omit
-- keys). Roblox's per-call packet framing is not modelled (identical for every
-- library); call counts are reported separately so it can be estimated.
local function wireSize(v: any): number
	local t = type(v)
	if t == "buffer" then
		local n = buffer.len(v)
		return 1 + varintSize(n) + n
	elseif t == "string" then
		return 1 + varintSize(#v) + #v
	elseif t == "number" then
		return 9
	elseif t == "vector" then
		return 13
	elseif t == "boolean" or t == "nil" then
		return 1
	elseif t == "table" then
		if getmetatable(v) == InstanceMT then
			return 5
		end
		local n, size = 0, 0
		local arrayLen = #v
		for k, item in v do
			n += 1
			if not (type(k) == "number" and k >= 1 and k <= arrayLen) then
				size += wireSize(k)
			end
			size += wireSize(item)
		end
		return 1 + varintSize(n) + size
	end
	return 1
end

Mock.wireSize = wireSize

-- Copies a remote argument the way the network would: buffers and tables are
-- fresh copies, instances are mapped through `mapInstance` (to the receiving
-- machine's replica), everything else is a value.
local function copyArg(v: any, mapInstance)
	local t = type(v)
	if t == "buffer" then
		local size = buffer.len(v)
		local copy = buffer.create(size)
		buffer.copy(copy, 0, v, 0, size)
		return copy
	elseif t == "table" then
		if getmetatable(v) == InstanceMT then
			return mapInstance(v)
		end
		local copy = {}
		for k, item in v do
			copy[copyArg(k, mapInstance)] = copyArg(item, mapInstance)
		end
		return copy
	end
	return v
end

--------------------------------------------------------------------------------
-- Module compilation (shared code) and instantiation (per environment)
--------------------------------------------------------------------------------

local HEADER = "local game, workspace, Instance, task, warn, typeof, _G, shared, script, require = ...\n"

-- Inserts the injection header after the leading `--!` directive lines so that
-- `--!native` / `--!optimize 2` keep applying.
local function injectHeader(src: string): string
	local pos = 1
	while string.sub(src, pos, pos + 2) == "--!" do
		local nl = string.find(src, "\n", pos, true)
		if nl == nil then
			return src .. "\n" .. HEADER
		end
		pos = nl + 1
	end
	return string.sub(src, 1, pos - 1) .. HEADER .. string.sub(src, pos)
end

Mock.injectHeader = injectHeader

local chunkCache = {} -- [path] = compiled chunk

-- Compiles a module file once. Every environment that requires it runs the
-- same chunk (fresh module state, shared bytecode/native code), like N
-- separate machines each holding ONE copy of the code. (Compiling a copy per
-- simulated client would put N copies of native code in the instruction cache
-- and penalize native code unrealistically.)
function Mock.compileFile(path: string)
	local chunk = chunkCache[path]
	if chunk then
		return chunk
	end
	local src = readfile(path) or error(`cannot read module {path}`)
	local fn, err = loadstring(injectHeader(src), "@" .. path)
	if not fn then
		error(`failed to compile {path}: {err}`)
	end
	chunkCache[path] = fn
	return fn
end

-- Compiles every .luau/.lua file under a directory (for libraries).
function Mock.compileTree(dir: string)
	for _, entry in listdir(dir) or error(`cannot list {dir}`) do
		local path = `{dir}/{entry.name}`
		if entry.dir then
			Mock.compileTree(path)
		elseif string.match(entry.name, "%.luau?$") then
			Mock.compileFile(path)
		end
	end
end

local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "."
end

local function normalize(path: string): string
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return (if string.sub(path, 1, 1) == "/" then "/" else "") .. table.concat(parts, "/")
end

local function fileExists(path: string): boolean
	return readfile(path) ~= nil
end

-- Resolves a string require relative to the requiring file (Luau semantics:
-- "./x" and "../x" are relative to the file's directory; for init.luau files
-- "./x" is relative to the init's parent directory and "@self/x" to its own).
local function resolveStringRequire(fromPath: string, name: string): string
	local base = dirname(fromPath)
	local rel = name
	if string.sub(name, 1, 6) == "@self/" then
		rel = string.sub(name, 7)
	elseif string.match(fromPath, "/init%.luau?$") then
		base = dirname(base)
	end
	local target = normalize(base .. "/" .. rel)
	for _, candidate in { target .. ".luau", target .. ".lua", target .. "/init.luau", target .. "/init.lua" } do
		if fileExists(candidate) then
			return candidate
		end
	end
	error(`require("{name}") from {fromPath}: no module at {target}`)
end

--------------------------------------------------------------------------------
-- World
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- HttpService JSON (small, for libraries that replicate config as JSON)
--------------------------------------------------------------------------------

local function jsonEncode(v: any): string
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" or t == "number" then
		return tostring(v)
	elseif t == "string" then
		return '"' .. string.gsub(v, '[%c"\\]', function(c)
			return string.format("\\u%04x", string.byte(c))
		end) .. '"'
	elseif t == "table" then
		local parts = {}
		if next(v) == nil or #v > 0 then
			for i = 1, #v do
				parts[i] = jsonEncode(v[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for k, item in v do
			table.insert(parts, jsonEncode(tostring(k)) .. ":" .. jsonEncode(item))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error(`JSONEncode: cannot encode a {t}`)
end

local function jsonDecode(s: string): any
	local pos = 1
	local value
	local function skip()
		pos = string.find(s, "[^ \t\r\n]", pos) or #s + 1
	end
	function value()
		skip()
		local c = string.sub(s, pos, pos)
		if c == "{" or c == "[" then
			local out, isObject = {}, c == "{"
			pos += 1
			skip()
			if string.sub(s, pos, pos) == (if isObject then "}" else "]") then
				pos += 1
				return out
			end
			while true do
				if isObject then
					local k = value()
					skip()
					pos += 1 -- ':'
					out[k] = value()
				else
					table.insert(out, value())
				end
				skip()
				local sep = string.sub(s, pos, pos)
				pos += 1
				if sep ~= "," then
					return out
				end
			end
		elseif c == '"' then
			local stop = string.find(s, '"', pos + 1, true)
			local raw = string.sub(s, pos + 1, stop - 1)
			pos = stop + 1
			return (string.gsub(raw, "\\u(%x%x%x%x)", function(h)
				return utf8.char(tonumber(h, 16))
			end))
		elseif string.sub(s, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(s, pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif string.sub(s, pos, pos + 3) == "null" then
			pos += 4
			return nil
		end
		local num = string.match(s, "^-?[%d%.eE+-]+", pos)
		pos += #num
		return tonumber(num)
	end
	return value()
end

local World = {}
World.__index = World

local Env = {} -- environment (machine) methods
Env.__index = Env

local ALL = newproxy() -- target marker for FireAllClients
local QUEUE_SLOTS = 8192
local NIL_RESULT = newproxy() -- cached "module returned nil"

function Mock.newWorld()
	local self = setmetatable({}, World)
	self.task = newTaskLib()
	self.players = {} -- server-side Player objects in join order
	self.clients = {} -- [i] = client environment
	self.clientByPlayer = {}

	-- Outgoing queues: flat arrays of records [remote, target, nargs, args...]
	-- padded to at least 3 args; pos = next free slot. Pre-sized so that the
	-- array part never has to be rebuilt by a rehash (a rehash of a mostly-nil
	-- array can shrink it, and the regrowth would be attributed to the code
	-- that happens to fire next).
	self.s2c, self.s2cPos = table.create(QUEUE_SLOTS), 1
	self.c2s, self.c2sPos = table.create(QUEUE_SLOTS), 1
	self.serverInbox, self.serverInboxPos = table.create(QUEUE_SLOTS), 1

	self.stats = {
		s2cCalls = 0,
		s2cBytes = 0,
		s2cFires = 0, -- server-side Fire calls (FireAllClients counts once)
		s2cFireCopyUs = 0, -- time to copy each fired record once (proxy for engine serialization)
		c2sCalls = 0,
		c2sBytes = 0,
		unreliableOversize = 0, -- unreliable calls > 1000 bytes (Roblox would drop them)
		warnings = 0,
	}
	self.warnings = {}

	self.server = self:_newEnv(true)
	return self
end

function World:_warn(...)
	self.stats.warnings += 1
	if #self.warnings < 20 then
		local parts = table.pack(...)
		for i = 1, parts.n do
			parts[i] = tostring(parts[i])
		end
		table.insert(self.warnings, table.concat(parts, " ", 1, parts.n))
	end
end

-- Appends one remote call record to a flat queue; returns the new position.
-- Allocation-free once the queue array has grown to its working size.
-- Roblox serialises remote arguments when Fire* is called, so a library may
-- reuse (overwrite) a buffer right after firing it (QuickNet recycles its
-- batch buffers by size). Queued buffer arguments are therefore snapshotted
-- at the call into pooled buffers of the same length, which go back to the
-- pool once delivered: no allocation in steady state, one buffer.copy.
local bufferPool = {} -- [length] = { free snapshot buffers }

local function snapshot(v)
	if type(v) ~= "buffer" then
		return v
	end
	local len = buffer.len(v)
	local free = bufferPool[len]
	local copy = if free then table.remove(free) else nil
	if copy == nil then
		copy = buffer.create(len)
	end
	buffer.copy(copy, 0, v, 0, len)
	return copy
end

local function releaseSnapshot(v)
	if type(v) == "buffer" then
		local len = buffer.len(v)
		local free = bufferPool[len]
		if free == nil then
			free = table.create(64)
			bufferPool[len] = free
		end
		table.insert(free, v)
	end
end

local function enqueue(q, pos: number, remote, target, ...)
	local n = select("#", ...)
	q[pos] = remote
	q[pos + 1] = target
	q[pos + 2] = n
	if n <= 3 then
		local a, b, c = ...
		q[pos + 3], q[pos + 4], q[pos + 5] = snapshot(a), snapshot(b), snapshot(c)
		return pos + 6
	end
	for i = 1, n do
		q[pos + 2 + i] = snapshot((select(i, ...)))
	end
	return pos + 3 + n
end

local function recordEnd(pos: number, n: number): number
	return pos + 3 + (if n < 3 then 3 else n)
end

--------------------------------------------------------------------------------
-- Environment (one machine)
--------------------------------------------------------------------------------

function World:_newEnv(isServer: boolean)
	local world = self
	local env = setmetatable({
		world = world,
		isServer = isServer,
		G = {}, -- this machine's _G
		shared = {},
		modules = {}, -- [path] = module result
		loading = {},
		scripts = {}, -- [path] = ModuleScript instance used as `script`
	}, Env)

	local game = newInstance("DataModel", "Game")
	env.game = game
	rawset(game, "GetService", function(_self, name)
		local service = Instance.FindFirstChild(game, name)
		if service == nil then
			error(`mock game:GetService: unknown service "{name}" (add it in lib/mock.luau)`)
		end
		return service
	end)

	local function service(className: string)
		local s = newInstance(className)
		s.Parent = game
		return s
	end

	local RunService = service("RunService")
	for _, name in { "Heartbeat", "PostSimulation", "Stepped", "PreSimulation", "RenderStepped", "PreRender", "PreAnimation" } do
		rawset(RunService, name, Signal.new())
	end
	rawset(RunService, "IsServer", function()
		return isServer
	end)
	rawset(RunService, "IsClient", function()
		return not isServer
	end)
	rawset(RunService, "IsRunning", function()
		return true
	end)
	rawset(RunService, "IsStudio", function()
		return false
	end)
	rawset(RunService, "IsRunMode", function()
		return false
	end)
	env.RunService = RunService

	local Players = service("Players")
	rawset(Players, "PlayerAdded", Signal.new())
	rawset(Players, "PlayerRemoving", Signal.new())
	-- Like Roblox, GetPlayers returns a fresh array on every call (this
	-- allocation is a real cost of calling it from Luau).
	rawset(Players, "GetPlayers", function()
		return table.clone(world.players)
	end)
	env.Players = Players

	env.ReplicatedStorage = service("ReplicatedStorage")
	env.Workspace = service("Workspace")
	rawset(env.Workspace, "GetServerTimeNow", function()
		return os.clock()
	end)
	local HttpService = service("HttpService")
	rawset(HttpService, "JSONEncode", function(_self, value)
		return jsonEncode(value)
	end)
	rawset(HttpService, "JSONDecode", function(_self, text: string)
		return jsonDecode(text)
	end)
	if isServer then
		env.ServerScriptService = service("ServerScriptService")
		env.ServerStorage = service("ServerStorage")
	end

	env.InstanceLib = {
		new = function(className: string, parent)
			local inst
			if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
				if not isServer then
					error(`mock: creating a {className} on the client is not supported`)
				end
				inst = world:_newServerRemote(className)
			else
				inst = newInstance(className)
			end
			if parent then
				inst.Parent = parent
			end
			return inst
		end,
	}
	env.warn = function(...)
		world:_warn(...)
	end
	return env
end

-- The `require` handed to the module at `path`.
function Env:_makeRequire(path: string?)
	return function(target)
		if type(target) == "string" then
			assert(path, "string require from a module without a file path")
			local file = resolveStringRequire(path, target)
			return self:requireFile(file, self.scripts[file])
		end
		local file = type(target) == "table" and (rawget(target, "_path") or nil)
		if not file then
			error(`require: {tostring(target)} is not a ModuleScript backed by a file`)
		end
		return self:requireFile(file, target)
	end
end

-- Runs the module at `path` in this environment once (cached), with `script`
-- set to `scriptInst` (a detached ModuleScript is made if nil). Returns the
-- module's result.
function Env:requireFile(path: string, scriptInst)
	local cached = self.modules[path]
	if cached ~= nil then
		return if cached == NIL_RESULT then nil else cached
	end
	if self.loading[path] then
		error(`cyclic require of {path}`)
	end
	self.loading[path] = true
	if scriptInst == nil then
		scriptInst = self.scripts[path] or newInstance("ModuleScript", string.match(path, "([^/]+)%.luau?$"))
		rawset(scriptInst, "_path", path)
	end
	self.scripts[path] = scriptInst
	local chunk = Mock.compileFile(path)
	local world = self.world
	local result = chunk(
		self.game,
		self.Workspace,
		self.InstanceLib,
		world.task,
		self.warn,
		robloxTypeof,
		self.G,
		self.shared,
		scriptInst,
		self:_makeRequire(path)
	)
	self.loading[path] = nil
	self.modules[path] = if result == nil then NIL_RESULT else result
	return result
end

-- Mounts a library directory (Rojo layout) under `parent` as `name`: a
-- directory with init.luau becomes a ModuleScript, other directories become
-- Folders, *.luau files become ModuleScripts. Mount shared libraries on the
-- SERVER under ReplicatedStorage; clients then see them through replication
-- and `require(ReplicatedStorage.Lib)` works on both sides.
function Env:mountTree(diskPath: string, parent, name: string?)
	local inst
	if listdir(diskPath) ~= nil then
		local init = nil
		for _, candidate in { "/init.luau", "/init.lua" } do
			if fileExists(diskPath .. candidate) then
				init = diskPath .. candidate
			end
		end
		inst = newInstance(if init then "ModuleScript" else "Folder", name or string.match(diskPath, "([^/]+)$"))
		if init then
			rawset(inst, "_path", init)
			self.scripts[init] = inst
		end
		for _, entry in listdir(diskPath) do
			if entry.dir or (string.match(entry.name, "%.luau?$") and not string.match(entry.name, "^init%.luau?$")) then
				self:mountTree(`{diskPath}/{entry.name}`, inst)
			end
		end
	else
		inst = newInstance("ModuleScript", name or string.match(diskPath, "([^/]+)%.luau?$"))
		rawset(inst, "_path", diskPath)
		self.scripts[diskPath] = inst
	end
	inst.Parent = parent
	return inst
end

-- Runs this machine's per-frame RunService signals. Signals without
-- connections are skipped so the (mock-only) stepping cost stays negligible.
local function fireIfConnected(signal, ...)
	if #signal._fns > 0 then
		signal:_fireDirect(...)
	end
end

function Env:step(dt: number)
	local rs = self.RunService
	if not self.isServer then
		fireIfConnected(rs.PreRender, dt)
		fireIfConnected(rs.RenderStepped, dt)
	end
	fireIfConnected(rs.PreAnimation, dt)
	fireIfConnected(rs.PreSimulation, dt)
	fireIfConnected(rs.Stepped, 0, dt)
	fireIfConnected(rs.PostSimulation, dt)
	fireIfConnected(rs.Heartbeat, dt)
	self.world.task._runDeferred()
end

--------------------------------------------------------------------------------
-- Server remotes
--------------------------------------------------------------------------------

function World:_newServerRemote(className: string)
	local world = self
	local remote = newInstance(className)
	rawset(remote, "OnServerEvent", Signal.new())
	rawset(remote, "OnClientEvent", Signal.new()) -- exists but never fires on the server
	rawset(remote, "FireClient", function(_self, player, ...)
		world.s2cPos = enqueue(world.s2c, world.s2cPos, remote, player, ...)
	end)
	rawset(remote, "FireAllClients", function(_self, ...)
		world.s2cPos = enqueue(world.s2c, world.s2cPos, remote, ALL, ...)
	end)
	rawset(remote, "FireServer", function()
		error("FireServer can only be called from the client")
	end)
	return remote
end

--------------------------------------------------------------------------------
-- Client environments and replication
--------------------------------------------------------------------------------

-- Returns client `client`'s replica of server instance `inst`, or nil if the
-- instance is not replicated (it must live under ReplicatedStorage or
-- Workspace; Player objects are shared as-is).
function World:_replicaOf(client, inst)
	if inst == nil then
		return nil
	end
	local replica = client.replicas[inst]
	if replica then
		return replica
	end
	local cls = rawget(inst, "ClassName")
	if cls == "Player" then
		return inst
	elseif inst == self.server.ReplicatedStorage then
		return client.ReplicatedStorage
	elseif inst == self.server.Workspace then
		return client.Workspace
	end
	local parentReplica = self:_replicaOf(client, rawget(inst, "_parent"))
	if parentReplica == nil then
		return nil
	end

	local world = self
	replica = setmetatable({
		ClassName = cls,
		Name = rawget(inst, "Name"),
		_children = {},
		_attributes = table.clone(rawget(inst, "_attributes")),
		_server = inst,
		_parent = parentReplica,
		_path = rawget(inst, "_path"),
		_resolveChildren = function(r)
			return world:_replicaChildren(client, r)
		end,
	}, InstanceMT)

	if cls == "RemoteEvent" or cls == "UnreliableRemoteEvent" then
		local player = client.player
		rawset(replica, "OnClientEvent", Signal.new())
		rawset(replica, "OnServerEvent", Signal.new())
		rawset(replica, "FireServer", function(_self, ...)
			world.c2sPos = enqueue(world.c2s, world.c2sPos, inst, player, ...)
		end)
		rawset(replica, "FireClient", function()
			error("FireClient can only be called from the server")
		end)
		rawset(replica, "FireAllClients", function()
			error("FireAllClients can only be called from the server")
		end)
	end
	client.replicas[inst] = replica
	return replica
end

-- Children of a replicated container/replica: replicas of the server-side
-- children plus anything the client created locally under it.
function World:_replicaChildren(client, r)
	local server = rawget(r, "_server")
	local out = {}
	if server then
		for _, child in rawget(server, "_children") do
			table.insert(out, self:_replicaOf(client, child))
		end
	end
	for _, child in rawget(r, "_children") do
		table.insert(out, child)
	end
	return out
end

function World:_newClientEnv(index: number, player)
	local client = self:_newEnv(false)
	client.index = index
	client.player = player
	client.replicas = {} -- [server instance] = this client's replica
	client.inbox, client.inboxPos = table.create(1024), 1

	-- Replicated containers: their children are the server's (plus local ones).
	local world = self
	for _, name in { "ReplicatedStorage", "Workspace" } do
		local container = client[name]
		rawset(container, "_server", self.server[name])
		rawset(container, "_resolveChildren", function(r)
			return world:_replicaChildren(client, r)
		end)
	end
	rawset(client.Players, "LocalPlayer", player)
	return client
end

-- Adds a player to the server (fires PlayerAdded everywhere) and creates its
-- client environment. Returns the Player and the client environment.
function World:addPlayer()
	local index = #self.players + 1
	local player = newInstance("Player", `Player{index}`)
	rawset(player, "UserId", 1000 + index)
	rawset(player, "DisplayName", rawget(player, "Name"))
	player.Parent = self.server.Players
	table.insert(self.players, player)
	local client = self:_newClientEnv(index, player)
	self.clients[index] = client
	self.clientByPlayer[player] = client
	-- Roblox runs connections in new threads; spawning keeps that semantic.
	local envs = { self.server }
	for _, c in self.clients do
		table.insert(envs, c)
	end
	for _, env in envs do
		for _, fn in table.clone(env.Players.PlayerAdded._fns) do
			self.task.spawn(fn, player)
		end
	end
	return player, client
end

--------------------------------------------------------------------------------
-- Network phase
--------------------------------------------------------------------------------

local function isUnreliable(remote): boolean
	return rawget(remote, "ClassName") == "UnreliableRemoteEvent"
end

-- Copies one queued call (at q[pos]) into a receiver inbox as the record
-- [signal, player-or-false, nargs, args...]. Returns new inbox end and wire size.
local function deliverRecord(q, pos, n, inbox, inboxPos, signal, player, mapInstance)
	local bytes = 0
	inbox[inboxPos] = signal
	inbox[inboxPos + 1] = player
	inbox[inboxPos + 2] = n
	for i = 1, n do
		local v = q[pos + 2 + i]
		bytes += wireSize(v)
		inbox[inboxPos + 2 + i] = copyArg(v, mapInstance)
	end
	return inboxPos + 3 + n, bytes
end

-- Network phase: moves every queued remote call into the receivers' inboxes,
-- deep-copying arguments and counting wire bytes.
function World:deliver()
	local stats = self.stats
	local clients = self.clients

	local q = self.s2c
	local pos = 1
	while pos < self.s2cPos do
		local remote, target, n = q[pos], q[pos + 1], q[pos + 2]
		local function deliverTo(client)
			local endpoint = self:_replicaOf(client, remote)
			if endpoint == nil then
				return -- the client cannot see this remote (not replicated)
			end
			local function mapInstance(inst)
				return self:_replicaOf(client, inst) or inst
			end
			local bytes
			client.inboxPos, bytes =
				deliverRecord(q, pos, n, client.inbox, client.inboxPos, endpoint.OnClientEvent, false, mapInstance)
			stats.s2cCalls += 1
			stats.s2cBytes += bytes
			if isUnreliable(remote) and bytes > 1000 then
				stats.unreliableOversize += 1
			end
		end
		stats.s2cFires += 1
		if target == ALL then
			for c = 1, #clients do
				if c == 1 then
					local t0 = os.clock()
					deliverTo(clients[c])
					stats.s2cFireCopyUs += (os.clock() - t0) * 1e6
				else
					deliverTo(clients[c])
				end
			end
		else
			local t0 = os.clock()
			deliverTo(self.clientByPlayer[target] or error("FireClient: unknown player " .. tostring(target)))
			stats.s2cFireCopyUs += (os.clock() - t0) * 1e6
		end
		local nextPos = recordEnd(pos, n)
		for i = pos, nextPos - 1 do
			releaseSnapshot(q[i])
			q[i] = nil
		end
		pos = nextPos
	end
	self.s2cPos = 1

	local function toServer(inst)
		return rawget(inst, "_server") or inst
	end
	q = self.c2s
	pos = 1
	while pos < self.c2sPos do
		local remote, player, n = q[pos], q[pos + 1], q[pos + 2]
		local bytes
		self.serverInboxPos, bytes =
			deliverRecord(q, pos, n, self.serverInbox, self.serverInboxPos, rawget(remote, "OnServerEvent"), player, toServer)
		stats.c2sCalls += 1
		stats.c2sBytes += bytes
		if isUnreliable(remote) and bytes > 1000 then
			stats.unreliableOversize += 1
		end
		local nextPos = recordEnd(pos, n)
		for i = pos, nextPos - 1 do
			releaseSnapshot(q[i])
			q[i] = nil
		end
		pos = nextPos
	end
	self.c2sPos = 1
end

-- Runs the handlers of every call in an inbox, then clears it.
local function drainInbox(inbox, endPos)
	local pos = 1
	while pos < endPos do
		local signal, player, n = inbox[pos], inbox[pos + 1], inbox[pos + 2]
		if player then
			if n == 2 then
				signal:_fireDirect(player, inbox[pos + 3], inbox[pos + 4])
			elseif n == 1 then
				signal:_fireDirect(player, inbox[pos + 3])
			else
				signal:_fireDirect(player, table.unpack(inbox, pos + 3, pos + 2 + n))
			end
		else
			if n == 2 then
				signal:_fireDirect(inbox[pos + 3], inbox[pos + 4])
			elseif n == 1 then
				signal:_fireDirect(inbox[pos + 3])
			else
				signal:_fireDirect(table.unpack(inbox, pos + 3, pos + 2 + n))
			end
		end
		for i = pos, pos + 2 + n do
			inbox[i] = nil
		end
		pos += 3 + n
	end
end

-- Receive phase for one client: OnClientEvent handlers, then deferred threads.
function World:receiveClient(index: number)
	local client = self.clients[index]
	drainInbox(client.inbox, client.inboxPos)
	client.inboxPos = 1
	self.task._runDeferred()
end

-- Receive phase for the server.
function World:receiveServer()
	drainInbox(self.serverInbox, self.serverInboxPos)
	self.serverInboxPos = 1
	self.task._runDeferred()
end

-- End-of-frame stepping (RunService signals; Blink's StepReplication runs on
-- Heartbeat).
function World:stepServer(dt: number)
	self.server:step(dt)
end

function World:stepClient(index: number, dt: number)
	self.clients[index]:step(dt)
end

return Mock
