--!optimize 2
-- Runs ONE scenario once and prints a JSON result line to stdout.
--
--   luau-bench [-O2] [--codegen] lib/run_scenario.luau <benchRoot> <adapter> <scenario> <outDir> <frames> <warmup>
--
-- <adapter> names adapters/<adapter>/adapter.luau; <outDir> is that adapter's
-- build output (gen/<label>). The scenario driver scenarios/<scenario>.luau
-- talks only to the per-schema contract API the adapter returns.
--
-- Per frame the harness runs these phases, each measured separately
-- (wall time via os.clock, allocations via the host's exact onallocate hook):
--   prepare      (untimed)  driver builds/mutates the payloads it will send
--   server_send  (timed)    driver calls the server API (fire functions)
--   client_send  (timed)    driver calls each client's API
--   server_step  (timed)    server RunService signals (Heartbeat -> e.g. Blink StepReplication)
--   client_step  (timed)    each client's RunService signals
--   network      (timed, mock cost only) arguments copied into receiver inboxes
--   client_recv  (timed)    OnClientEvent handlers (decode + dispatch + listeners)
--   server_recv  (timed)    OnServerEvent handlers
--   verify       (untimed)  driver checks received values == sent values

local benchRoot, adapterName, scenarioName, outDir, framesArg, warmupArg = arg[1], arg[2], arg[3], arg[4], arg[5], arg[6]
assert(
	benchRoot and adapterName and scenarioName and outDir,
	"usage: run_scenario.luau <benchRoot> <adapter> <scenario> <outDir> [frames] [warmup]"
)
local FRAMES = tonumber(framesArg) or 600
local WARMUP = tonumber(warmupArg) or 120
local DT = 1 / 30

local function import(path: string, ...)
	local src = readfile(path) or error(`cannot read {path}`)
	local fn, err = loadstring(src, "@" .. path)
	if not fn then
		error(err)
	end
	return fn(...)
end

local Json = import(`{benchRoot}/lib/json.luau`)
local Mock = import(`{benchRoot}/lib/mock.luau`)

--------------------------------------------------------------------------------
-- Helpers handed to scenario drivers
--------------------------------------------------------------------------------

local H = {}
H.checks = 0
H.import = function(rel: string, ...)
	return import(`{benchRoot}/{rel}`, ...)
end

local currentFrame = 0

function H.fail(msg: string)
	error(`[verify] scenario {scenarioName}, frame {currentFrame}: {msg}`, 2)
end

function H.eq(actual: any, expected: any, what: string)
	H.checks += 1
	if actual ~= expected then
		H.fail(`{what}: expected {tostring(expected)}, got {tostring(actual)}`)
	end
end

function H.near(actual: number, expected: number, tol: number, what: string)
	H.checks += 1
	if type(actual) ~= "number" or math.abs(actual - expected) > tol then
		H.fail(`{what}: expected {tostring(expected)} (+-{tol}), got {tostring(actual)}`)
	end
end

function H.vecNear(actual: any, expected: vector, tol: number, what: string)
	H.checks += 1
	if typeof(actual) ~= "vector" then
		H.fail(`{what}: expected a vector, got {typeof(actual)}`)
	end
	if math.abs(actual.X - expected.X) > tol or math.abs(actual.Y - expected.Y) > tol or math.abs(actual.Z - expected.Z) > tol then
		H.fail(`{what}: expected {tostring(expected)} (+-{tol}), got {tostring(actual)}`)
	end
end

-- Compares two "set" tables ({[string]: boolean}); a missing key counts as false.
function H.setEq(actual: any, expected: { [string]: boolean }, keys: { string }, what: string)
	H.checks += 1
	if type(actual) ~= "table" then
		H.fail(`{what}: expected a table, got {typeof(actual)}`)
	end
	for _, k in keys do
		if (actual[k] == true) ~= (expected[k] == true) then
			H.fail(`{what}.{k}: expected {tostring(expected[k])}, got {tostring(actual[k])}`)
		end
	end
end

--------------------------------------------------------------------------------
-- Load scenario + generated modules
--------------------------------------------------------------------------------

local scenario = import(`{benchRoot}/scenarios/{scenarioName}.luau`, H)
local adapter = import(`{benchRoot}/adapters/{adapterName}/adapter.luau`, {
	Mock = Mock,
	outDir = outDir,
	benchRoot = benchRoot,
})
local SCHEMA = scenario.schema
local NCLIENTS = scenario.clients

-- Fails with a clear message when an adapter's API misses a contract entry.
local function checkApi(api, side: string)
	for _, name in scenario.api[side] do
		if api == nil or api[name] == nil then
			error(`adapter {adapterName}: {side} API for schema {SCHEMA} lacks "{name}" (scenario {scenarioName})`)
		end
	end
end

-- An unsupported schema is reported as a skip, not a failure: the JSON line
-- carries `skipped`, and the run.py treats it as such (the process then
-- stops with an error since Luau has no os.exit).
local function skip(reason: string)
	print(Json.encode({ scenario = scenarioName, skipped = reason }))
	error("skipped: " .. reason, 0)
end

Mock.installGlobals()
local world = Mock.newWorld()

local function liveAfterGC(): number
	__gc("collect")
	__gc("collect")
	return __live_bytes()
end

local heap = {}
local load = {}

-- Heap accounting (live bytes after a full GC, deltas between steps):
--   *_code  : compiled chunks (bytecode protos, constants, debug info)
--   *_state : what starting the library leaves alive (tables, closures,
--             buffers, remotes ...), per machine
--   client_module = client_code + client_state: what ONE client machine holds
local live0 = liveAfterGC()
local a0, c0, t0 = __alloc_bytes(), __alloc_count(), os.clock()
local serverHandle, why = adapter.compile(SCHEMA, "server")
if serverHandle == nil then
	skip(why or "schema not supported by adapter")
end
load.server_compile_us = (os.clock() - t0) * 1e6
local live1 = liveAfterGC()
t0 = os.clock()
local server = adapter.start(serverHandle, world.server)
load.server_init_us = (os.clock() - t0) * 1e6
load.server_alloc_bytes = __alloc_bytes() - a0
load.server_allocs = __alloc_count() - c0
checkApi(server, "server")
local live2 = liveAfterGC()

local players = {}
local playerIndex = {}
for i = 1, NCLIENTS do
	local player = world:addPlayer()
	players[i] = player
	playerIndex[player] = i
end
local live3 = liveAfterGC()

local clients = {}
t0 = os.clock()
local clientHandle, whyClient = adapter.compile(SCHEMA, "client")
if clientHandle == nil then
	skip(whyClient or "schema not supported by adapter")
end
load.client_compile_us = (os.clock() - t0) * 1e6
local live4 = liveAfterGC()
a0, c0, t0 = __alloc_bytes(), __alloc_count(), os.clock()
for i = 1, NCLIENTS do
	clients[i] = adapter.start(clientHandle, world.clients[i])
end
load.client_init_us = (os.clock() - t0) * 1e6 / NCLIENTS
load.client_init_alloc_bytes = (__alloc_bytes() - a0) / NCLIENTS
load.client_init_allocs = (__alloc_count() - c0) / NCLIENTS
checkApi(clients[1], "client")
local live5 = liveAfterGC()

heap.server_code = live1 - live0
heap.server_state = live2 - live1
heap.server_module = live2 - live0
heap.client_code = live4 - live3
heap.client_state = (live5 - live4) / NCLIENTS
heap.client_module = heap.client_code + heap.client_state

local ctx = {
	server = server,
	clients = clients,
	players = players,
	playerIndex = playerIndex,
	nclients = NCLIENTS,
	world = world,
	sink = 0,
}

scenario.setup(ctx)
local liveSetup = liveAfterGC()

--------------------------------------------------------------------------------
-- Frame loop
--------------------------------------------------------------------------------

local PHASES = { "server_send", "client_send", "server_step", "client_step", "network", "client_recv", "server_recv" }
local acc = {}
local function resetAcc()
	for _, name in PHASES do
		acc[name] = { time = 0, bytes = 0, count = 0 }
	end
	acc.client_recv_max_time = 0 -- sum over frames of the slowest client's receive time
end
resetAcc()

local clock, allocBytes, allocCount = os.clock, __alloc_bytes, __alloc_count

local prepare = scenario.prepare
local serverSend = scenario.serverSend
local clientSend = scenario.clientSend
local verify = scenario.verify
local FULL_VERIFY_EVERY = scenario.fullVerifyEvery or 10

local function frame(f: number)
	currentFrame = f
	if prepare then
		prepare(ctx, f)
	end

	local t, b, c
	local a

	if serverSend then
		t, b, c = clock(), allocBytes(), allocCount()
		serverSend(ctx, f)
		a = acc.server_send
		a.time += clock() - t
		a.bytes += allocBytes() - b
		a.count += allocCount() - c
	end

	if clientSend then
		a = acc.client_send
		for i = 1, NCLIENTS do
			t, b, c = clock(), allocBytes(), allocCount()
			clientSend(ctx, f, i)
			a.time += clock() - t
			a.bytes += allocBytes() - b
			a.count += allocCount() - c
		end
	end

	t, b, c = clock(), allocBytes(), allocCount()
	world:stepServer(DT)
	a = acc.server_step
	a.time += clock() - t
	a.bytes += allocBytes() - b
	a.count += allocCount() - c

	a = acc.client_step
	for i = 1, NCLIENTS do
		t, b, c = clock(), allocBytes(), allocCount()
		world:stepClient(i, DT)
		a.time += clock() - t
		a.bytes += allocBytes() - b
		a.count += allocCount() - c
	end

	t, b, c = clock(), allocBytes(), allocCount()
	world:deliver()
	a = acc.network
	a.time += clock() - t
	a.bytes += allocBytes() - b
	a.count += allocCount() - c

	a = acc.client_recv
	local maxTime = 0
	for i = 1, NCLIENTS do
		t, b, c = clock(), allocBytes(), allocCount()
		world:receiveClient(i)
		local dt = clock() - t
		a.time += dt
		a.bytes += allocBytes() - b
		a.count += allocCount() - c
		if dt > maxTime then
			maxTime = dt
		end
	end
	acc.client_recv_max_time += maxTime

	t, b, c = clock(), allocBytes(), allocCount()
	world:receiveServer()
	a = acc.server_recv
	a.time += clock() - t
	a.bytes += allocBytes() - b
	a.count += allocCount() - c

	if verify then
		verify(ctx, f, f % FULL_VERIFY_EVERY == 0)
	end
end

for f = 1, WARMUP do
	frame(f)
end

resetAcc()
for k in world.stats do
	world.stats[k] = 0
end
local checksBefore = H.checks
local runStart = clock()

for f = WARMUP + 1, WARMUP + FRAMES do
	frame(f)
end

local runWall = clock() - runStart
local liveEnd = liveAfterGC()

-- Whole-VM live heap (includes mock + driver state) and how much it grew
-- while running frames (send buffers, queues, listener-held payloads, ...).
heap.after_setup = liveSetup
heap.steady = liveEnd
heap.steady_growth = liveEnd - liveSetup

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

local phases = {}
local totalUs, totalBytes, totalAllocs = 0, 0, 0
for _, name in PHASES do
	local a = acc[name]
	phases[name] = {
		us = a.time * 1e6 / FRAMES,
		alloc_bytes = a.bytes / FRAMES,
		allocs = a.count / FRAMES,
	}
	if name ~= "network" then
		totalUs += a.time * 1e6 / FRAMES
		totalBytes += a.bytes / FRAMES
		totalAllocs += a.count / FRAMES
	end
end
phases.client_recv_per_client = {
	us = phases.client_recv.us / NCLIENTS,
	alloc_bytes = phases.client_recv.alloc_bytes / NCLIENTS,
	allocs = phases.client_recv.allocs / NCLIENTS,
}
-- average over frames of the slowest client's receive time that frame
phases.client_recv_max_client_us = acc.client_recv_max_time * 1e6 / FRAMES
-- Everything except the mock network copy: the cost the library adds to a frame,
-- summed over the server and all clients.
phases.total = { us = totalUs, alloc_bytes = totalBytes, allocs = totalAllocs }

local stats = world.stats
local result = {
	scenario = scenarioName,
	adapter = adapterName,
	schema = SCHEMA,
	native = __native(),
	optlevel = __optlevel(),
	frames = FRAMES,
	warmup = WARMUP,
	clients = NCLIENTS,
	phases = phases,
	wire = {
		s2c_bytes_per_frame = stats.s2cBytes / FRAMES,
		s2c_calls_per_frame = stats.s2cCalls / FRAMES,
		s2c_fires_per_frame = stats.s2cFires / FRAMES,
		s2c_fire_copy_us_per_frame = stats.s2cFireCopyUs / FRAMES,
		c2s_bytes_per_frame = stats.c2sBytes / FRAMES,
		c2s_calls_per_frame = stats.c2sCalls / FRAMES,
		unreliable_oversize = stats.unreliableOversize,
	},
	heap = heap,
	load = load,
	native_code_bytes = __native_code_bytes(),
	warnings = stats.warnings,
	warning_samples = world.warnings,
	verify_checks = H.checks - checksBefore,
	run_wall_s = runWall,
	sink = ctx.sink,
}

print(Json.encode(result))
