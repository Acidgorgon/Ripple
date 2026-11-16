`luau-0.700-src/` holds the Ast, Common, Compiler, VM and CodeGen sources of the
Luau 0.700 release (MIT, see `luau-0.700-src/LICENSE`), as packaged by the
`luau0-src` crate 0.16.0+luau700. `host/CMakeLists.txt` builds the benchmark
host from them, so every run uses the same VM.
