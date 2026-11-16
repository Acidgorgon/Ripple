--!strict
-- Ripple schema parser. Grammar (Blink-style):
--
--   file      := { decl }
--   decl      := "option" Name "=" (string | Name | number)
--              | "type" Name "=" type
--              | "struct" Name structBody
--              | "map" Name "=" mapBody
--              | "enum" Name "=" "{" Name { "," Name } [","] "}"
--              | "state" Name "{" { Name ":" (type | Name) [","] } "}"     -- keys: Scope, Data
--   type      := base [ "?" ] [ "[" [range] "]" ] [ "?" ]
--   base      := primitive [ "(" range ")" ] | Name | "struct" structBody | "map" mapBody | "any"
--   structBody:= "{" { ["server"] Name ":" type [","] } "}"   -- `server` fields are saved/validated, never replicated
--   mapBody   := "{" "[" type "]" ":" type "}"
--   range     := [number] ".." [number] | number
--
-- Comments: "--" to end of line and "--[[ ... ]]".

export type Type = {
	kind: "prim" | "struct" | "map" | "array" | "enum" | "any" | "ref",
	prim: string?,
	fields: { { name: string, type: Type } }?,
	key: Type?,
	value: Type?,
	element: Type?,
	optional: boolean?,
	name: string?, -- named type (struct/map/enum declarations, refs)
	values: { string }?, -- enum
	line: number?,
}

export type State = { name: string, scope: string, data: Type, line: number }
export type Schema = {
	options: { [string]: any },
	types: { [string]: Type },
	order: { string },
	states: { State },
}

local PRIMS = {
	u8 = true, u16 = true, u32 = true, i8 = true, i16 = true, i32 = true, f32 = true, f64 = true,
	uint = true, int = true, boolean = true, string = true, vector = true, buffer = true,
}

local function tokenize(src: string)
	local toks = {}
	local i, n, line = 1, #src, 1
	while i <= n do
		local c = string.sub(src, i, i)
		if c == "\n" then
			line += 1
			i += 1
		elseif string.match(c, "%s") then
			i += 1
		elseif string.sub(src, i, i + 3) == "--[[" then
			local e = string.find(src, "]]", i + 4, true) or n
			for _ in string.gmatch(string.sub(src, i, e), "\n") do
				line += 1
			end
			i = e + 2
		elseif string.sub(src, i, i + 1) == "--" then
			local e = string.find(src, "\n", i, true) or (n + 1)
			i = e
		elseif string.sub(src, i, i + 1) == ".." then
			table.insert(toks, { t = "..", v = "..", line = line })
			i += 2
		elseif string.match(c, "[%a_]") then
			local s, e = string.find(src, "^[%w_]+", i)
			table.insert(toks, { t = "name", v = string.sub(src, s :: number, e :: number), line = line })
			i = (e :: number) + 1
		elseif string.match(c, "[%d%-]") then
			local s, e = string.find(src, "^%-?%d+%.?%d*", i)
			if s == nil then
				error(`ripple: line {line}: unexpected '{c}'`, 0)
			end
			-- don't swallow ".." of a range: "0..10"
			local text = string.sub(src, s :: number, e :: number)
			if string.sub(text, -1) == "." then
				text = string.sub(text, 1, -2)
				e = (e :: number) - 1
			end
			table.insert(toks, { t = "number", v = tonumber(text), line = line })
			i = (e :: number) + 1
		elseif c == '"' then
			local e = string.find(src, '"', i + 1, true)
			if not e then
				error(`ripple: line {line}: unterminated string`, 0)
			end
			table.insert(toks, { t = "string", v = string.sub(src, i + 1, e - 1), line = line })
			i = e + 1
		elseif string.match(c, "[{}%[%]:,=?()]") then
			table.insert(toks, { t = c, v = c, line = line })
			i += 1
		else
			error(`ripple: line {line}: unexpected character '{c}'`, 0)
		end
	end
	table.insert(toks, { t = "eof", v = "<end of file>", line = line })
	return toks
end

local Parser = {}

function Parser.parse(src: string): Schema
	local toks = tokenize(src)
	local p = 1
	local schema: Schema = { options = {}, types = {}, order = {}, states = {} }

	local function peek(o: number?)
		return toks[p + (o or 0)]
	end
	local function fail(msg: string, tok: any?): never
		local t = tok or toks[p]
		error(`ripple: line {t.line}: {msg} (near '{tostring(t.v)}')`, 0)
	end
	local function expect(t: string, v: string?)
		local tok = toks[p]
		if tok.t ~= t or (v ~= nil and tok.v ~= v) then
			fail(`expected '{v or t}'`)
		end
		p += 1
		return tok
	end
	local function accept(t: string, v: string?)
		local tok = toks[p]
		if tok.t == t and (v == nil or tok.v == v) then
			p += 1
			return tok
		end
		return nil
	end

	local parseType: () -> Type

	-- range := number | [number] ".." [number]. A single number means exactly that value (or length).
	local function parseRange(): { min: number?, max: number? }?
		local a = accept("number")
		if accept("..") then
			local b = accept("number")
			if a == nil and b == nil then
				return nil
			end
			if a and b and a.v > b.v then
				fail("range minimum is larger than its maximum")
			end
			return { min = a and a.v, max = b and b.v }
		end
		if a then
			return { min = a.v, max = a.v }
		end
		return nil
	end

	local function parseStructBody(): Type
		expect("{")
		local fields = {}
		local seen = {}
		while not accept("}") do
			local serverOnly = false
			if peek().t == "name" and peek().v == "server" and peek(1).t == "name" then
				p += 1
				serverOnly = true
			end
			local nameTok = expect("name")
			if seen[nameTok.v] then
				fail(`duplicate field '{nameTok.v}'`, nameTok)
			end
			if string.sub(nameTok.v, 1, 2) == "__" then
				fail("field names may not start with '__'", nameTok)
			end
			seen[nameTok.v] = true
			expect(":")
			table.insert(fields, { name = nameTok.v, type = parseType(), serverOnly = serverOnly })
			if not accept(",") then
				expect("}")
				break
			end
		end
		if #fields > 255 then
			fail("a struct may have at most 255 fields")
		end
		return { kind = "struct", fields = fields }
	end

	local function parseMapBody(): Type
		expect("{")
		expect("[")
		local key = parseType()
		expect("]")
		expect(":")
		local value = parseType()
		expect("}")
		return { kind = "map", key = key, value = value }
	end

	local function parseBase(): Type
		local tok = peek()
		if tok.t ~= "name" then
			fail("expected a type")
		end
		p += 1
		local v = tok.v
		if v == "struct" then
			return parseStructBody()
		elseif v == "map" then
			return parseMapBody()
		elseif v == "any" or v == "unknown" then
			return { kind = "any" }
		elseif PRIMS[v] then
			local range = nil
			if accept("(") then
				range = parseRange()
				expect(")")
				if range and (v == "boolean" or v == "vector") then
					fail(`{v} cannot have a range`, tok)
				end
			end
			return { kind = "prim", prim = v, range = range }
		end
		return { kind = "ref", name = v, line = tok.line }
	end

	function parseType(): Type
		local t = parseBase()
		if accept("?") then
			t = table.clone(t)
			t.optional = true
		end
		while accept("[") do
			local len = parseRange()
			expect("]")
			t = { kind = "array", element = t, len = len }
			if accept("?") then
				t.optional = true
			end
		end
		return t
	end

	local function declare(name: string, t: Type, tok)
		if schema.types[name] then
			fail(`'{name}' is declared twice`, tok)
		end
		t.name = name
		schema.types[name] = t
		table.insert(schema.order, name)
	end

	while peek().t ~= "eof" do
		local tok = expect("name")
		local kw = tok.v
		if kw == "option" then
			local name = expect("name").v
			expect("=")
			local val = peek()
			p += 1
			schema.options[name] = val.v
		elseif kw == "type" then
			local nameTok = expect("name")
			expect("=")
			declare(nameTok.v, table.clone(parseType()), nameTok)
		elseif kw == "struct" then
			local nameTok = expect("name")
			accept("=")
			declare(nameTok.v, parseStructBody(), nameTok)
		elseif kw == "map" then
			local nameTok = expect("name")
			expect("=")
			declare(nameTok.v, parseMapBody(), nameTok)
		elseif kw == "enum" then
			local nameTok = expect("name")
			expect("=")
			expect("{")
			local values = {}
			while not accept("}") do
				local v = peek()
				if v.t ~= "name" and v.t ~= "string" then
					fail("expected an enum value")
				end
				p += 1
				table.insert(values, v.v)
				if not accept(",") then
					expect("}")
					break
				end
			end
			if #values == 0 or #values > 256 then
				fail("an enum needs 1 to 256 values", nameTok)
			end
			declare(nameTok.v, { kind = "enum", values = values }, nameTok)
		elseif kw == "state" then
			local nameTok = expect("name")
			expect("{")
			local scope, data = "Player", nil
			while not accept("}") do
				local key = expect("name")
				expect(":")
				if key.v == "Scope" then
					scope = expect("name").v
					if scope ~= "Player" and scope ~= "All" and scope ~= "Manual" then
						fail("Scope must be Player, All or Manual", key)
					end
				elseif key.v == "Data" then
					data = parseType()
				else
					fail(`unknown state option '{key.v}' (expected Scope or Data)`, key)
				end
				if not accept(",") then
					expect("}")
					break
				end
			end
			if data == nil then
				fail(`state '{nameTok.v}' has no Data`, nameTok)
			end
			table.insert(schema.states, { name = nameTok.v, scope = scope, data = data :: Type, line = nameTok.line })
		else
			fail(`unknown declaration '{kw}'`, tok)
		end
	end

	-- Resolve references.
	local function resolve(t: Type, depth: number): Type
		if depth > 64 then
			error("ripple: type nesting too deep (recursive types are not supported)", 0)
		end
		if t.kind == "ref" then
			local target = schema.types[t.name :: string]
			if not target then
				error(`ripple: line {t.line}: unknown type '{t.name}'`, 0)
			end
			local r = resolve(target, depth + 1)
			if t.optional and not r.optional then
				r = table.clone(r)
				r.optional = true
			end
			return r
		elseif t.kind == "struct" then
			for _, f in t.fields :: any do
				f.type = resolve(f.type, depth + 1)
			end
		elseif t.kind == "map" then
			t.key = resolve(t.key :: Type, depth + 1)
			t.value = resolve(t.value :: Type, depth + 1)
			local k = t.key :: Type
			if k.optional or not (k.kind == "prim" or k.kind == "enum" or k.kind == "any") or k.prim == "buffer" then
				error("ripple: map keys must be a non-optional primitive, enum or any", 0)
			end
		elseif t.kind == "array" then
			t.element = resolve(t.element :: Type, depth + 1)
		end
		return t
	end
	for _, name in schema.order do
		schema.types[name] = resolve(schema.types[name], 0)
	end
	for _, st in schema.states do
		st.data = resolve(st.data, 0)
		if st.data.kind ~= "struct" or st.data.optional then
			error(`ripple: line {st.line}: state '{st.name}' Data must be a (non-optional) struct`, 0)
		end
	end
	if #schema.states == 0 then
		error("ripple: the schema declares no state", 0)
	end
	if #schema.states > 255 then
		error("ripple: at most 255 states", 0)
	end
	return schema
end

return Parser
