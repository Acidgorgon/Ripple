--!strict
-- Primitive codecs as code snippets. `W(prim, expr)` returns statements that write `expr`;
-- `R(prim, var)` returns statements that read into the local `var` (declared by the caller).
-- Server code writes through the module-level writer (buf/pos/cap, grow); client code reads through
-- the module-level reader (rb/rp).

local Codec = {}

local SIZE = { u8 = 1, i8 = 1, boolean = 1, u16 = 2, i16 = 2, u32 = 4, i32 = 4, f32 = 4, f64 = 8, vector = 12 }
Codec.SIZE = SIZE

local WRITE = {
	u8 = "buffer.writeu8", i8 = "buffer.writei8", u16 = "buffer.writeu16", i16 = "buffer.writei16",
	u32 = "buffer.writeu32", i32 = "buffer.writei32", f32 = "buffer.writef32", f64 = "buffer.writef64",
}
local READ = {
	u8 = "buffer.readu8", i8 = "buffer.readi8", u16 = "buffer.readu16", i16 = "buffer.readi16",
	u32 = "buffer.readu32", i32 = "buffer.readi32", f32 = "buffer.readf32", f64 = "buffer.readf64",
}

-- Value checks used by setters (server). Returns a Luau boolean expression that is TRUE when `v` is valid.
local INT_RANGE = {
	u8 = { 0, 255 }, u16 = { 0, 65535 }, u32 = { 0, 4294967295 },
	i8 = { -128, 127 }, i16 = { -32768, 32767 }, i32 = { -2147483648, 2147483647 },
}
function Codec.validExpr(prim: string, v: string): string
	local r = INT_RANGE[prim]
	if r then
		return `type({v}) == "number" and {v} >= {r[1]} and {v} <= {r[2]} and {v} // 1 == {v}`
	elseif prim == "f32" or prim == "f64" then
		-- NaN is rejected: it compares unequal to everything, so it breaks balance checks and saves
		return `type({v}) == "number" and {v} == {v}`
	elseif prim == "uint" then
		return `type({v}) == "number" and {v} >= 0 and {v} <= 9007199254740991 and {v} // 1 == {v}`
	elseif prim == "int" then
		return `type({v}) == "number" and {v} >= -9007199254740991 and {v} <= 9007199254740991 and {v} // 1 == {v}`
	elseif prim == "boolean" then
		return `type({v}) == "boolean"`
	elseif prim == "string" then
		return `type({v}) == "string"`
	elseif prim == "vector" then
		return `typeof({v}) == "Vector3" and {v} == {v}`
	elseif prim == "buffer" then
		return `type({v}) == "buffer"`
	end
	error("unknown primitive " .. prim)
end

function Codec.typeName(prim: string): string
	if INT_RANGE[prim] then
		local r = INT_RANGE[prim]
		return `{prim} (integer {r[1]}..{r[2]})`
	end
	return prim
end

function Codec.W(prim: string, e: string): string
	local size = SIZE[prim]
	if prim == "boolean" then
		return `if pos + 1 > cap then grow(1) end buffer.writeu8(buf, pos, if {e} then 1 else 0) pos += 1`
	elseif prim == "vector" then
		return `do local v = {e} if pos + 12 > cap then grow(12) end buffer.writef32(buf, pos, v.X) buffer.writef32(buf, pos + 4, v.Y) buffer.writef32(buf, pos + 8, v.Z) pos += 12 end`
	elseif size then
		return `if pos + {size} > cap then grow({size}) end {WRITE[prim]}(buf, pos, {e}) pos += {size}`
	elseif prim == "string" then
		return `wstr({e})`
	elseif prim == "uint" then
		return `wvar({e})`
	elseif prim == "int" then
		return `wzig({e})`
	elseif prim == "buffer" then
		return `wbuf({e})`
	end
	error("unknown primitive " .. prim)
end

function Codec.R(prim: string, var: string): string
	local size = SIZE[prim]
	if prim == "boolean" then
		return `{var} = buffer.readu8(rb, rp) ~= 0 rp += 1`
	elseif prim == "vector" then
		return `{var} = Vector3.new(buffer.readf32(rb, rp), buffer.readf32(rb, rp + 4), buffer.readf32(rb, rp + 8)) rp += 12`
	elseif size then
		return `{var} = {READ[prim]}(rb, rp) rp += {size}`
	elseif prim == "string" then
		return `{var} = rstr()`
	elseif prim == "uint" then
		return `{var} = rvar()`
	elseif prim == "int" then
		return `{var} = rzig()`
	elseif prim == "buffer" then
		return `{var} = rbuf()`
	end
	error("unknown primitive " .. prim)
end

-- Local-mode reads: the decoder function holds `local b, p = rb, rp` and must sync `rp = p` before calling
-- anything that reads (and `p = rp` after). These snippets do that themselves.
function Codec.RL(prim: string, var: string): string
	local size = SIZE[prim]
	if prim == "boolean" then
		return `{var} = buffer.readu8(b, p) ~= 0 p += 1`
	elseif prim == "vector" then
		return `{var} = Vector3.new(buffer.readf32(b, p), buffer.readf32(b, p + 4), buffer.readf32(b, p + 8)) p += 12`
	elseif size then
		return `{var} = {READ[prim]}(b, p) p += {size}`
	elseif prim == "string" then
		return `do local len_ = buffer.readu8(b, p) if len_ < 128 then p += 1 else rp = p len_ = rvar() p = rp end {var} = buffer.readstring(b, p, len_) p += len_ end`
	elseif prim == "uint" then
		return `do local u_ = buffer.readu8(b, p) if u_ < 128 then p += 1 {var} = u_ else rp = p {var} = rvar() p = rp end end`
	elseif prim == "int" then
		return `rp = p {var} = rzig() p = rp`
	elseif prim == "buffer" then
		return `rp = p {var} = rbuf() p = rp`
	end
	error("unknown primitive " .. prim)
end

-- Fixed-size write at `pos + off` (no bounds check, no pos update): used by inlined flat structs.
function Codec.WAt(prim: string, e: string, off: number): string
	local at = if off == 0 then "pos" else `pos + {off}`
	if prim == "boolean" then
		return `buffer.writeu8(buf, {at}, if {e} then 1 else 0)`
	elseif prim == "vector" then
		return `do local v_ = {e} buffer.writef32(buf, {at}, v_.X) buffer.writef32(buf, pos + {off + 4}, v_.Y) buffer.writef32(buf, pos + {off + 8}, v_.Z) end`
	end
	return `{WRITE[prim]}(buf, {at}, {e})`
end
-- Fixed-size read expression at `p + off` (local mode).
function Codec.RAt(prim: string, off: number): string
	local at = if off == 0 then "p" else `p + {off}`
	if prim == "boolean" then
		return `buffer.readu8(b, {at}) ~= 0`
	elseif prim == "vector" then
		return `Vector3.new(buffer.readf32(b, {at}), buffer.readf32(b, p + {off + 4}), buffer.readf32(b, p + {off + 8}))`
	end
	return `{READ[prim]}(b, {at})`
end

return Codec
