--!nocheck
-- Ripple code generator: schema -> Server.luau + Client.luau (self-contained, runtime included).
local Codec = require("./Codec")

local Generator = {}

local function fieldBit(i: number): (number, number)
	-- 1-based field index -> (word index 1.., bit value)
	local w = (i - 1) // 32 + 1
	return w, 2 ^ ((i - 1) % 32)
end

local function quote(s: string): string
	return string.format("%q", s)
end

-- Is `name` usable as `t.name`?
local function isIdent(name: string): boolean
	return string.match(name, "^[%a_][%w_]*$") ~= nil
		and not ({ ["and"] = 1, ["break"] = 1, ["do"] = 1, ["else"] = 1, ["elseif"] = 1, ["end"] = 1, ["false"] = 1,
			["for"] = 1, ["function"] = 1, ["if"] = 1, ["in"] = 1, ["local"] = 1, ["nil"] = 1, ["not"] = 1,
			["or"] = 1, ["repeat"] = 1, ["return"] = 1, ["then"] = 1, ["true"] = 1, ["until"] = 1, ["while"] = 1,
			["continue"] = 1, ["export"] = 1, ["type"] = 1 })[name]
end
local function idx(t: string, name: string): string
	return if isIdent(name) then `{t}.{name}` else `{t}[{quote(name)}]`
end

local function isTable(t): boolean
	return t.kind == "struct" or t.kind == "map" or t.kind == "array" or t.kind == "any"
end

function Generator.generate(schema)
	local opts = schema.options
	local remoteName = opts.RemoteName or "Ripple"

	-- Assign ids to every table-typed node (struct/map/array/any), depth-first.
	local descs = {} -- array of { id, type, path }
	local byType = {} -- [type] = desc
	local enums = {} -- [type] = enum id
	local enumList = {}

	local function visit(t, path)
		if t.kind == "enum" then
			if not enums[t] then
				table.insert(enumList, t)
				enums[t] = #enumList
			end
			return
		end
		if not isTable(t) then
			return
		end
		local d = byType[t]
		if d then
			return d
		end
		d = { id = #descs + 1, type = t, path = path }
		byType[t] = d
		table.insert(descs, d)
		if t.kind == "struct" then
			for _, f in t.fields do
				visit(f.type, `{path}.{f.name}`)
			end
		elseif t.kind == "map" then
			visit(t.key, path .. "[key]")
			visit(t.value, path .. "[]")
		elseif t.kind == "array" then
			visit(t.element, path .. "[]")
		end
		return d
	end
	for _, st in schema.states do
		visit(st.data, st.name)
	end
	local function D(t)
		return "T" .. byType[t].id
	end

	----------------------------------------------------------------------------
	-- Shared snippet helpers
	----------------------------------------------------------------------------

	-- Flat struct: every replicated field is a fixed-size, non-optional primitive. Such structs (cards,
	-- items, small records) are encoded and decoded inline with one bounds check and constant offsets.
	local flatCache = {}
	local function flatLayout(t)
		if t.kind ~= "struct" then
			return nil
		end
		local c = flatCache[t]
		if c ~= nil then
			return c or nil
		end
		local fields, off = {}, 0
		for _, f in t.fields do
			if f.serverOnly then
				continue
			end
			local ft = f.type
			local size = ft.kind == "prim" and not ft.optional and Codec.SIZE[ft.prim]
			if not size or #fields >= 16 then
				flatCache[t] = false
				return nil
			end
			table.insert(fields, { name = f.name, prim = ft.prim, off = off })
			off += size
		end
		if #fields == 0 then
			flatCache[t] = false
			return nil
		end
		c = { fields = fields, size = off }
		flatCache[t] = c
		return c
	end
	local function flatWrite(L, e: string): string
		local parts = { `do local q_ = {e} if pos + {L.size} > cap then grow({L.size}) end` }
		for _, f in L.fields do
			table.insert(parts, Codec.WAt(f.prim, idx("q_", f.name), f.off))
		end
		table.insert(parts, `pos += {L.size} end`)
		return table.concat(parts, " ")
	end
	local function flatRead(L, var: string): string
		local ctor = {}
		for _, f in L.fields do
			local key = if isIdent(f.name) then f.name else `[{quote(f.name)}]`
			table.insert(ctor, `{key} = {Codec.RAt(f.prim, f.off)}`)
		end
		return `{var} = \{ {table.concat(ctor, ", ")} } p += {L.size}`
	end

	-- Server: statements writing value expression `e` of type t (t non-optional semantics; caller handles optional).
	local function writeValue(t, e: string): string
		if t.kind == "prim" then
			return Codec.W(t.prim, e)
		elseif t.kind == "enum" then
			return `wenum(ENUM{enums[t]}, {e})`
		elseif t.kind == "any" then
			return `wany({e})`
		else
			local L = flatLayout(t)
			if L then
				return flatWrite(L, e)
			end
			return `{D(t)}_full({e})`
		end
	end
	-- optional-aware
	local function writeMaybe(t, e: string): string
		if t.optional then
			return `if {e} == nil then if pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, 0) pos += 1 else if pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, 1) pos += 1 {writeValue(t, e)} end`
		end
		return writeValue(t, e)
	end
	-- Client: statements reading a value of type t into the (declared) local var.
	-- (client decoders run in local mode: `b`, `p` locals; see Codec.RL)
	local function readValue(t, var: string): string
		if t.kind == "prim" then
			return Codec.RL(t.prim, var)
		elseif t.kind == "enum" then
			return `{var} = ENUMV{enums[t]}[buffer.readu8(b, p) + 1] p += 1`
		elseif t.kind == "any" then
			return `rp = p {var} = rany() p = rp`
		else
			local L = flatLayout(t)
			if L then
				return flatRead(L, var)
			end
			return `rp = p {var} = {D(t)}_full() p = rp`
		end
	end
	local function readMaybe(t, var: string): string
		if t.optional then
			return `if buffer.readu8(b, p) == 0 then p += 1 {var} = nil else p += 1 {readValue(t, var)} end`
		end
		return readValue(t, var)
	end
	-- Server: boolean Luau expression, true when `v` is a valid NON-NIL value of type t (tables: just type()).
	local function validExpr(t, v: string): string
		if t.kind == "prim" then
			local e = Codec.validExpr(t.prim, v)
			local r = t.range
			if r then
				local m = if t.prim == "string" then `#{v}` elseif t.prim == "buffer" then `buffer.len({v})` else v
				if r.min then
					e ..= ` and {m} >= {r.min}`
				end
				if r.max then
					e ..= ` and {m} <= {r.max}`
				end
			end
			return e
		elseif t.kind == "enum" then
			return `ENUM{enums[t]}[{v}] ~= nil`
		elseif t.kind == "any" then
			return "true"
		end
		return `type({v}) == "table"`
	end
	local function typeLabel(t): string
		local s
		if t.kind == "prim" then
			s = Codec.typeName(t.prim)
			local r = t.range
			if r then
				local what = if t.prim == "string" or t.prim == "buffer" then "length" else "value"
				s ..= ` with {what} {r.min or ""}..{r.max or ""}`
			end
		elseif t.kind == "enum" then
			s = "enum " .. (t.name or "") .. " {" .. table.concat(t.values, ", ") .. "}"
		elseif t.kind == "any" then
			s = "any"
		else
			s = t.kind
		end
		return if t.optional then s .. "?" else s
	end

	-- Luau type text
	local clientTypes = false
	local function luauType(t): string
		local s
		if t.kind == "prim" then
			s = ({ boolean = "boolean", string = "string", vector = "Vector3", buffer = "buffer" })[t.prim] or "number"
		elseif t.kind == "enum" then
			local parts = {}
			for _, v in t.values do
				table.insert(parts, quote(v))
			end
			s = table.concat(parts, " | ")
			if #t.values > 1 then
				s = "(" .. s .. ")"
			end
		elseif t.kind == "any" then
			s = "any"
		elseif t.kind == "struct" then
			local parts = {}
			for _, f in t.fields do
				if clientTypes and f.serverOnly then
					continue
				end
				local key = if isIdent(f.name) then f.name else `[{quote(f.name)}]`
				table.insert(parts, `{key}: {luauType(f.type)}`)
			end
			s = "{ " .. table.concat(parts, ", ") .. " }"
		elseif t.kind == "map" then
			s = `\{ [{luauType(t.key)}]: {luauType(t.value)} }`
		elseif t.kind == "array" then
			s = `\{ {luauType(t.element)} }`
		end
		return if t.optional then `{s}?` else s
	end

	----------------------------------------------------------------------------
	-- SERVER
	----------------------------------------------------------------------------
	local S = {}
	local function s(line: string)
		table.insert(S, line)
	end

	s("-- Enums")
	for i, e in enumList do
		local parts = {}
		for k, v in e.values do
			table.insert(parts, `[{quote(v)}] = {k - 1}`)
		end
		s(`local ENUM{i} = \{ {table.concat(parts, ", ")} }`)
	end
	s("")
	s("-- Type descriptors")
	for _, d in descs do
		s(`local T{d.id} = \{ kind = {({ struct = 1, map = 2, array = 3, any = 4 })[d.type.kind]}, path = {quote(d.path)} }`)
	end
	for _, d in descs do
		s(`local T{d.id}_full, T{d.id}_patch, T{d.id}_check`)
	end
	s("")

	for _, d in descs do
		local t = d.type
		local T = "T" .. d.id
		local P = quote(d.path)
		if t.kind == "struct" then
			local n = #t.fields
			local nw = if n <= 32 then 0 else (n - 1) // 32 + 1
			s(`{T}.nw = {nw}`)
			s(`{T}.names = \{ {(function()
				local q = {}
				for _, f in t.fields do
					table.insert(q, quote(f.name))
				end
				return table.concat(q, ", ")
			end)()} }`)
			-- kids (table-typed fields)
			local kids = {}
			for i, f in t.fields do
				if isTable(f.type) then
					table.insert(kids, `\{ name = {quote(f.name)}, idx = {i}, D = {D(f.type)}, so = {f.serverOnly == true} }`)
				end
			end
			if #kids > 0 then
				s(`{T}.kids = \{ {table.concat(kids, ", ")} }`)
			end
			-- setters
			s(`local {T}_set = \{}`)
			for i, f in t.fields do
				local ft = f.type
				local w, bit = fieldBit(i)
				local mark = if nw == 0
					then `M.w = bor(M.w, {bit})`
					else `local ws = M.w ws[{w}] = bor(ws[{w}], {bit})`
				local fpath = quote(d.path .. "." .. f.name)
				local label = quote(typeLabel(ft))
				s(`{idx(T .. "_set", f.name)} = function(M, v)`)
				if isTable(ft) and ft.kind ~= "any" then
					s(`\tif v ~= nil then v = {D(ft)}_check(v) elseif {not ft.optional} then badValue({fpath}, {label}, v) end`)
					s(`\tlocal p, V = M.p, M.V`)
					s(`\tlocal old = rawget(V, {quote(f.name)})`)
					s(`\tif old ~= nil then detach(old) end`)
					s(`\t{idx("p", f.name)} = v`)
					if f.serverOnly then
						s(`\trawset(V, {quote(f.name)}, if v ~= nil then newSaveNode({D(ft)}, v, M) else nil)`)
						s(`\tmarkSave(M)`)
					else
						s(`\trawset(V, {quote(f.name)}, if v ~= nil then newNode({D(ft)}, v, M, {i}) else nil)`)
						s(`\tlocal full = M.full if full == nil then full = \{} M.full = full end full[{i}] = true`)
						s(`\t{mark}`)
						s(`\tif not M.dirty then touch(M) end`)
					end
				elseif ft.kind == "any" then
					s(`\tv = T{byType[ft].id}_check(v)`)
					s(`\tlocal p, V = M.p, M.V`)
					s(`\tlocal old = rawget(V, {quote(f.name)})`)
					s(`\tif old == nil and {idx("p", f.name)} == v and type(v) ~= "table" then return end`)
					s(`\tif old ~= nil then detach(old) end`)
					s(`\t{idx("p", f.name)} = v`)
					if f.serverOnly then
						s(`\trawset(V, {quote(f.name)}, if type(v) == "table" then newSaveNode({D(ft)}, v, M) else v)`)
						s(`\tmarkSave(M)`)
					else
						s(`\trawset(V, {quote(f.name)}, if type(v) == "table" then newNode({D(ft)}, v, M, {i}) else v)`)
						s(`\tlocal full = M.full if full == nil then full = \{} M.full = full end full[{i}] = true`)
						s(`\t{mark}`)
						s(`\tif not M.dirty then touch(M) end`)
					end
				else
					local cond = validExpr(ft, "v")
					if ft.optional then
						cond = `v == nil or ({cond})`
					end
					s(`\tif not ({cond}) then badValue({fpath}, {label}, v) end`)
					s(`\tlocal p = M.p`)
					s(`\tif {idx("p", f.name)} ~= v then`)
					s(`\t\t{idx("p", f.name)} = v`)
					if #kids > 0 then
						s(`\t\t{idx("M.V", f.name)} = v`)
					end
					if f.serverOnly then
						s(`\t\tmarkSave(M)`)
					else
						s(`\t\t{mark}`)
						s(`\t\tif not M.dirty then touch(M) end`)
					end
					s(`\tend`)
				end
				s(`end`)
			end
			s(`{T}.set = {T}_set`)
			s(`{T}.ni = function(P, k, v)`)
			s(`\tlocal f = {T}_set[k]`)
			s(`\tif f == nil then unknownField({P}, k) end`)
			s(`\tf(getmetatable(P), v)`)
			s(`end`)
			-- check
			s(`function {T}_check(v)`)
			s(`\tif type(v) ~= "table" then badValue({P}, "struct", v) end`)
			s(`\tlocal M = getmetatable(v) if M ~= nil and M.D ~= nil then v = deepCopy(M.p) end`)
			s(`\tfor k in v do if {T}_set[k] == nil then unknownField({P}, k) end end`)
			for _, f in t.fields do
				local ft = f.type
				local fpath = quote(d.path .. "." .. f.name)
				local label = quote(typeLabel(ft))
				s(`\tdo local x = {idx("v", f.name)}`)
				if ft.kind == "any" then
					s(`\t\t{idx("v", f.name)} = T{byType[ft].id}_check(x)`)
				elseif isTable(ft) then
					s(`\t\tif x ~= nil then {idx("v", f.name)} = {D(ft)}_check(x) elseif {not ft.optional} then badValue({fpath}, {label}, x) end`)
				else
					local cond = validExpr(ft, "x")
					if ft.optional then
						cond = `x == nil or ({cond})`
					end
					s(`\t\tif not ({cond}) then badValue({fpath}, {label}, x) end`)
				end
				s(`\tend`)
			end
			s(`\treturn v`)
			s(`end`)
			-- full encode
			s(`function {T}_full(p)`)
			for _, f in t.fields do
				if not f.serverOnly then
					s("\t" .. writeMaybe(f.type, idx("p", f.name)))
				end
			end
			s(`end`)
			-- patch encode
			s(`function {T}_patch(M)`)
			s(`\tlocal p = M.p`)
			s(`\tM.dirty = false`)
			if #kids > 0 then
				s(`\tlocal full = M.full M.full = nil`)
				s(`\tlocal V = M.V`)
			end
			-- server-only fields: clean their subtrees, then drop their bits
			local serverMask = {}
			for i, f in t.fields do
				if f.serverOnly then
					local w, bit = fieldBit(i)
					serverMask[w] = (serverMask[w] or 0) + bit
				end
			end
			local function dropServerBits(wname, w)
				if serverMask[w] then
					for i, f in t.fields do
						local fw, bit = fieldBit(i)
						if f.serverOnly and fw == w and isTable(f.type) then
							s(`\tif band({wname}, {bit}) ~= 0 then local c = rawget(M.V, {quote(f.name)}) if c ~= nil then cleanNode(getmetatable(c)) end end`)
						end
					end
					s(`\t{wname} = band({wname}, {0xFFFFFFFF - serverMask[w]})`)
				end
			end
			if nw == 0 then
				s(`\tlocal w1 = M.w M.w = 0`)
				dropServerBits("w1", 1)
				if n <= 8 then
					s(`\tif pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, w1) pos += 1`)
				elseif n <= 16 then
					s(`\tif pos + 2 > cap then grow(2) end buffer.writeu16(buf, pos, w1) pos += 2`)
				else
					s(`\twmask1(w1, {(n + 7) // 8})`)
				end
			else
				s(`\tlocal ws = M.w`)
				local names = {}
				for w = 1, nw do
					table.insert(names, "w" .. w)
				end
				s(`\tlocal {table.concat(names, ", ")} = table.unpack(ws)`)
				s(`\ttable.clear(ws) for i = 1, {nw} do ws[i] = 0 end`)
				for w = 1, nw do
					dropServerBits("w" .. w, w)
				end
				s(`\twmaskN(\{ {table.concat(names, ", ")} }, {(n + 7) // 8})`)
			end
			for i, f in t.fields do
				local ft = f.type
				local w, bit = fieldBit(i)
				if f.serverOnly then
					continue
				end
				s(`\tif band(w{w}, {bit}) ~= 0 then`)
				if isTable(ft) then
					local fe = idx("p", f.name)
					s(`\t\tlocal c = rawget(V, {quote(f.name)})`)
					s(`\t\tlocal cm = if c ~= nil and not (full and full[{i}]) then getmetatable(c) else nil`)
					s(`\t\tif cm ~= nil and cm.dirty then`)
					s(`\t\t\tif pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, 2) pos += 1`)
					s(`\t\t\t{D(ft)}_patch(cm)`)
					s(`\t\telseif {fe} == nil then`)
					s(`\t\t\tif pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, 0) pos += 1`)
					s(`\t\telse`)
					s(`\t\t\tif c ~= nil then cleanNode(getmetatable(c)) end`)
					s(`\t\t\tif pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, 1) pos += 1`)
					s(`\t\t\t{writeValue(ft, fe)}`)
					s(`\t\tend`)
				else
					s(`\t\t{writeMaybe(ft, idx("p", f.name))}`)
				end
				s(`\tend`)
			end
			s(`end`)
		elseif t.kind == "map" or t.kind == "array" then
			local isArr = t.kind == "array"
			local kt = if isArr then { kind = "prim", prim = "uint" } else t.key
			local vt = if isArr then t.element else t.value
			local vTable = isTable(vt)
			if vTable then
				s(`{T}.val = {D(vt)}`)
			end
			local keyCond = if isArr
				then `type(k) == "number" and k >= 1 and k // 1 == k`
				else validExpr(kt, "k")
			local vcond = validExpr(vt, "v")
			local label = quote(typeLabel(vt))
			local klabel = quote(if isArr then "array index" else typeLabel(kt))
			-- __newindex
			s(`{T}.ni = function(P, k, v)`)
			s(`\tlocal M = getmetatable(P)`)
			s(`\tif not ({keyCond}) then badKey({P}, {klabel}, k) end`)
			s(`\tlocal p = M.p`)
			if isArr then
				s(`\tlocal n = #p`)
				s(`\tif k > n + 1 or (v == nil and k ~= n) then badIndex({P}, k, n) end`)
				if t.len and t.len.max then
					s(`\tif k > {t.len.max} and v ~= nil then badLength({P}, {t.len.min or 0}, {t.len.max}, k) end`)
				end
			end
			if vt.kind == "any" then
				s(`\tv = T{byType[vt].id}_check(v)`)
			elseif vTable then
				s(`\tif v ~= nil then v = {D(vt)}_check(v) end`)
			else
				if vt.optional then
					error("ripple: map/array values cannot be optional (use nil to remove a key)", 0)
				end
				s(`\tif v ~= nil and not ({vcond}) then badValue({P} .. "[]", {label}, v) end`)
			end
			if vTable then
				s(`\tlocal V = M.V`)
				s(`\tlocal old = rawget(V, k)`)
				s(`\tif old ~= nil then detach(old) rawset(V, k, nil) elseif p[k] == v and type(v) ~= "table" then return end`)
			else
				s(`\tif p[k] == v then return end`)
			end
			s(`\tp[k] = v`)
			s(`\tM.dk[k] = 2`)
			s(`\tif not M.dirty then touch(M) end`)
			s(`end`)
			-- check
			s(`function {T}_check(v)`)
			s(`\tif type(v) ~= "table" then badValue({P}, {quote(t.kind)}, v) end`)
			s(`\tlocal M = getmetatable(v) if M ~= nil and M.D ~= nil then v = deepCopy(M.p) end`)
			if isArr then
				s(`\tlocal n = 0 for _ in v do n += 1 end`)
				s(`\tif n ~= #v then badValue({P}, "array without holes", v) end`)
				if t.len then
					local lo, hi = t.len.min or 0, t.len.max or 9007199254740991
					s(`\tif n < {lo} or n > {hi} then badLength({P}, {lo}, {hi}, n) end`)
				end
			end
			s(`\tfor k, x in v do`)
			if not isArr then
				s(`\t\tif not ({keyCond}) then badKey({P}, {klabel}, k) end`)
			end
			if vt.kind == "any" then
				s(`\t\tlocal c = T{byType[vt].id}_check(x) if c ~= x then v[k] = c end`)
			elseif vTable then
				s(`\t\tlocal c = {D(vt)}_check(x) if c ~= x then v[k] = c end`)
			else
				s(`\t\tif not ({validExpr(vt, "x")}) then badValue({P} .. "[]", {label}, x) end`)
			end
			s(`\tend`)
			s(`\treturn v`)
			s(`end`)
			-- full
			local function writeKey(e)
				if isArr then
					return `wvar({e})`
				end
				return writeValue(kt, e)
			end
			s(`function {T}_full(p)`)
			if isArr then
				s(`\tlocal n = #p`)
				s(`\twvar(n)`)
				s(`\tfor i = 1, n do local v = p[i] {writeValue(vt, "v")} end`)
			else
				s(`\tlocal n = 0 for _ in p do n += 1 end`)
				s(`\twvar(n)`)
				s(`\tfor k, v in p do {writeValue(kt, "k")} {writeValue(vt, "v")} end`)
			end
			s(`end`)
			-- patch
			s(`function {T}_patch(M)`)
			s(`\tM.dirty = false`)
			if isArr then
				s(`\tif M.full then`)
				s(`\t\tM.full = nil`)
				s(`\t\ttable.clear(M.dk)`)
				if vTable then
					s(`\t\tfor k, c in M.V do cleanNode(getmetatable(c)) end`)
				end
				s(`\t\tif pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, 1) pos += 1`)
				s(`\t\t{T}_full(M.p)`)
				s(`\t\treturn`)
				s(`\tend`)
				s(`\tif pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, 0) pos += 1`)
			end
			do
				s(`\tlocal p, dk = M.p, M.dk`)
				s(`\tlocal n = 0 for _ in dk do n += 1 end`)
				s(`\twvar(n)`)
				if vTable then
					s(`\tlocal V = M.V`)
				end
				s(`\tfor k, kind in dk do`)
				s(`\t\t{writeKey("k")}`)
				s(`\t\tlocal v = p[k]`)
				s(`\t\tif v == nil then`)
				s(`\t\t\tif pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, 0) pos += 1`)
				if vTable then
					s(`\t\telse`)
					s(`\t\t\tlocal c = rawget(V, k)`)
					s(`\t\t\tlocal cm = if c ~= nil then getmetatable(c) else nil`)
					s(`\t\t\tif kind == 1 and cm ~= nil and cm.dirty then`)
					s(`\t\t\t\tif pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, 2) pos += 1`)
					s(`\t\t\t\t{D(vt)}_patch(cm)`)
					s(`\t\t\telse`)
					s(`\t\t\t\tif cm ~= nil then cleanNode(cm) end`)
					s(`\t\t\t\tif pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, 1) pos += 1`)
					s(`\t\t\t\t{writeValue(vt, "v")}`)
					s(`\t\t\tend`)
				else
					s(`\t\telse`)
					s(`\t\t\tif pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, 1) pos += 1`)
					s(`\t\t\t{writeValue(vt, "v")}`)
				end
				s(`\t\tend`)
				s(`\tend`)
				s(`\ttable.clear(dk)`)
			end
			s(`end`)
		elseif t.kind == "any" then
			s(`{T}.ni = anyNewIndex`)
			s(`{T}_check = anyCheck`)
			s(`{T}_full = wany`)
			s(`{T}_patch = anyPatch`)
		end
		s(`{T}.full, {T}.patch, {T}.check = {T}_full, {T}_patch, {T}_check`)
		s("")
	end

	-- States
	s("-- States")
	local stateLines = {}
	for i, st in schema.states do
		table.insert(stateLines, `\{ id = {i}, name = {quote(st.name)}, scope = {quote(st.scope)}, D = {D(st.data)} }`)
	end
	s(`local STATES = \{ {table.concat(stateLines, ", ")} }`)
	s(`local REMOTE_NAME = {quote(remoteName)}`)

	-- Types
	local types, ctypes = {}, {}
	for _, st in schema.states do
		table.insert(types, `export type {st.name} = {luauType(st.data)}`)
	end
	clientTypes = true
	for _, st in schema.states do
		table.insert(ctypes, `export type {st.name} = {luauType(st.data)}`)
	end
	clientTypes = false

	----------------------------------------------------------------------------
	-- CLIENT
	----------------------------------------------------------------------------
	local C = {}
	local function c(line: string)
		table.insert(C, line)
	end
	c("-- Enums")
	for i, e in enumList do
		local parts = {}
		for _, v in e.values do
			table.insert(parts, quote(v))
		end
		c(`local ENUMV{i} = \{ {table.concat(parts, ", ")} }`)
	end
	c("")
	for _, d in descs do
		c(`local T{d.id}_full, T{d.id}_patch`)
	end
	for _, d in descs do
		local t = d.type
		local T = "T" .. d.id
		if t.kind == "struct" then
			local n = #t.fields
			local nw = if n <= 32 then 0 else (n - 1) // 32 + 1
			-- full
			c(`function {T}_full()`)
			c(`\tlocal b, p = rb, rp`)
			for i, f in t.fields do
				if f.serverOnly then
					continue
				end
				c(`\tlocal f{i}`)
				c("\t" .. readMaybe(f.type, "f" .. i))
			end
			c(`\trp = p`)
			local ctor = {}
			for i, f in t.fields do
				if f.serverOnly then
					continue
				end
				local key = if isIdent(f.name) then f.name else `[{quote(f.name)}]`
				table.insert(ctor, `{key} = f{i}`)
			end
			c(`\treturn \{ {table.concat(ctor, ", ")} }`)
			c(`end`)
			-- patch
			c(`function {T}_patch(t)`)
			c(`\tlocal L = LISTEN[t]`)
			c(`\tlocal b, p = rb, rp`)
			if nw == 0 then
				if n <= 8 then
					c(`\tlocal w1 = buffer.readu8(b, p) p += 1`)
				elseif n <= 16 then
					c(`\tlocal w1 = buffer.readu16(b, p) p += 2`)
				else
					c(`\trp = p local w1 = rmask1({(n + 7) // 8}) p = rp`)
				end
			else
				local names = {}
				for w = 1, nw do
					table.insert(names, "w" .. w)
				end
				c(`\trp = p local {table.concat(names, ", ")} = table.unpack(rmaskN({nw}, {(n + 7) // 8})) p = rp`)
			end
			for i, f in t.fields do
				local ft = f.type
				local w, bit = fieldBit(i)
				local fe = idx("t", f.name)
				if f.serverOnly then
					continue
				end
				c(`\tif band(w{w}, {bit}) ~= 0 then`)
				if isTable(ft) then
					c(`\t\tlocal tag = buffer.readu8(b, p) p += 1`)
					c(`\t\tlocal o = {fe}`)
					c(`\t\tlocal v`)
					c(`\t\tif tag == 2 then v = o rp = p {D(ft)}_patch(o) p = rp elseif tag == 1 then {readValue(ft, "v")} end`)
					c(`\t\t{fe} = v`)
					c(`\t\tif L then ev(t, {quote(f.name)}, v, o) end`)
				else
					c(`\t\tlocal v`)
					c(`\t\t{readMaybe(ft, "v")}`)
					c(`\t\tif L then local o = {fe} {fe} = v if o ~= v then ev(t, {quote(f.name)}, v, o) end else {fe} = v end`)
				end
				c(`\tend`)
			end
			c(`\trp = p`)
			c(`end`)
		elseif t.kind == "map" or t.kind == "array" then
			local isArr = t.kind == "array"
			local vt = if isArr then t.element else t.value
			local kt = if isArr then { kind = "prim", prim = "uint" } else t.key
			local vTable = isTable(vt)
			c(`function {T}_full()`)
			c(`\tlocal b, p = rb, rp`)
			c(`\tlocal n {Codec.RL("uint", "n")}`)
			if isArr then
				c(`\tlocal t = table.create(n)`)
				c(`\tfor i = 1, n do local v {readValue(vt, "v")} t[i] = v end`)
			else
				c(`\tlocal t = \{}`)
				c(`\tfor _ = 1, n do local k, v {readValue(kt, "k")} {readValue(vt, "v")} t[k] = v end`)
			end
			c(`\trp = p`)
			c(`\treturn t`)
			c(`end`)
			c(`function {T}_patch(t)`)
			c(`\tlocal b, p = rb, rp`)
			if isArr then
				-- tag 1: whole array (after insert/remove in the middle), decoded in place to keep identity
				c(`\tif buffer.readu8(b, p) == 1 then`)
				c(`\t\tp += 1`)
				c(`\t\tlocal n {Codec.RL("uint", "n")}`)
				c(`\t\tlocal old = #t`)
				c(`\t\tfor i = 1, n do local v {readValue(vt, "v")} t[i] = v end`)
				c(`\t\tfor i = old, n + 1, -1 do t[i] = nil end`)
				c(`\t\trp = p`)
				c(`\t\tif LISTEN[t] then ev(t, nil, t, t) end`)
				c(`\t\treturn`)
				c(`\tend`)
				c(`\tp += 1`)
			end
			c(`\tlocal L = LISTEN[t]`)
			c(`\tlocal n {Codec.RL("uint", "n")}`)
			c(`\tfor _ = 1, n do`)
			c(`\t\tlocal k {readValue(kt, "k")}`)
			c(`\t\tlocal tag = buffer.readu8(b, p) p += 1`)
			c(`\t\tlocal o = t[k]`)
			c(`\t\tlocal v`)
			if vTable then
				c(`\t\tif tag == 2 then v = o rp = p {D(vt)}_patch(o) p = rp elseif tag == 1 then {readValue(vt, "v")} end`)
			else
				c(`\t\tif tag == 1 then {readValue(vt, "v")} end`)
			end
			c(`\t\tt[k] = v`)
			c(`\t\tif L then ev(t, k, v, o) end`)
			c(`\tend`)
			c(`\trp = p`)
			c(`end`)
		elseif t.kind == "any" then
			c(`{T}_full = rany`)
			c(`{T}_patch = anyPatch`)
		end
		c("")
	end
	local cstates = {}
	for i, st in schema.states do
		table.insert(cstates, `\{ id = {i}, name = {quote(st.name)}, scope = {quote(st.scope)}, full = {D(st.data)}_full, patch = {D(st.data)}_patch }`)
	end
	c(`local STATES = \{ {table.concat(cstates, ", ")} }`)
	c(`local REMOTE_NAME = {quote(remoteName)}`)

	return {
		server = table.concat(S, "\n"),
		client = table.concat(C, "\n"),
		types = table.concat(types, "\n"),
		clientTypes = table.concat(ctypes, "\n"),
		states = schema.states,
	}
end

return Generator
