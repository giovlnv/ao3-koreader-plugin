-- KOReader itself targets LuaJIT; match that here so lint reflects the
-- runtime this code actually runs on.
std = "luajit"
unused_args = false

globals = {
    "G_reader_settings",
}

-- spec/ files use busted's DSL (describe/it/assert/...), which luacheck
-- doesn't know about by default.
files["spec/"] = {
    std = "+busted",
}
