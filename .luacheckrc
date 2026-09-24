std = "lua51"
-- The WoW client supplies globals not available to standalone Luacheck.
-- Keep local-variable and flow checks; LuaLS/game tests cover the API surface.
global = false
unused_args = false
max_line_length = false
