--!optimize 2
-- Reflex 4.x (littensy/reflex) with its broadcaster / broadcast receiver.
-- The library is mounted per machine as an Instance tree in the Wally layout (reflex/ + Promise
-- sibling), since Reflex requires its modules through `script.X` / `script.Parent.X`.
-- Shim (mock gap only): the mock's Instance has no `FindFirstAncestor`, which reflex/Promise.lua
-- calls on its own script to locate the Promise package; the adapter adds it to the mounted
-- library instances only.
local A = ...
local Adapter = {}

local function findFirstAncestor(self, name: string)
	local parent = self.Parent
	while parent ~= nil do
		if rawget(parent, "Name") == name then
			return parent
		end
		parent = parent.Parent
	end
	return nil
end

local function addShims(inst)
	rawset(inst, "FindFirstAncestor", findFirstAncestor)
	for _, child in inst:GetChildren() do
		addShims(child)
	end
end

function Adapter.compile(schema: string, side: "server" | "client")
	local dir = `{A.outDir}/{schema}`
	if readfile(`{dir}/ok`) == nil then
		return nil, `schema {schema} was not built (see {dir}/compile.log)`
	end
	A.Mock.compileTree(dir)
	A.Mock.compileTree(`{A.outDir}/_shared/reflex`)
	return { schema = schema, side = side, path = `{dir}/{side}.luau` }
end

function Adapter.start(handle, env)
	if not env._reflexMounted then
		env._reflexMounted = true
		addShims(env:mountTree(`{A.outDir}/_shared/reflex`, nil, "_Index"))
	end
	return env:requireFile(handle.path)
end

return Adapter
