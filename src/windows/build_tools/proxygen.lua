function add_proxydef(load_events)
    filename = "src/windows/proxy/proxylist.txt"

    table.insert(load_events, function(target, import, io)
        import("util", {rootdir="src/windows/build_tools"})

        local tmpl_dir = path.join(path.directory(path.directory(filename)), "build_tools")

        local proxy_defs = ""
        local proxy_adds = ""
        local proxy_funcs = ""
        local exports_funcs = ""

        local funcs = io.readfile(filename):split("\n")
        for i, name in ipairs(funcs) do
            local func = string.trim(name)
            if func ~= "" then
                -- The version functions live in version.dll, everything else
                -- in the module the proxy stands in for. Resolving them all
                -- against the same module left the version functions
                -- unresolved.
                local module = "dll"
                if func:match("^GetFileVersionInfo") or func:match("^Ver") then
                    module = "version_dll"
                end

                proxy_defs = proxy_defs ..
                                 format("static FARPROC __%s__;\r\n", func)
                proxy_adds = proxy_adds ..
                                 format(
                                     "__%s__ = proxy_resolve((HMODULE)%s, \"%s\", proxy_self());\r\n",
                                     func, module, func)

                -- The export is a jump, not a call. A call would need the
                -- exact prototype of the forwarded function, and the
                -- prototypes of the WinHTTP and the version functions are
                -- not the same. A jump keeps the argument registers and the
                -- stack exactly as the caller left them, so it is correct
                -- for every signature, including the ones with more than
                -- four arguments and the ones that return a structure.
                proxy_funcs = proxy_funcs ..
                                  format(
                                      "PROXY_NAKED void exp_%s(void) { __asm__(\"jmp *%s\"); }",
                                      func, "__" .. func .. "__") .. "\n"
                exports_funcs =
                    exports_funcs .. format("%s = exp_%s", func, func) .. "\n"
            end
        end

        util.write_template(
            path.join(tmpl_dir, "proxy.c.in"),
            path.join("build", "proxy.c"),
            {
                PROXY_DEFS = proxy_defs,
                PROXY_ADDS = proxy_adds,
                PROXY_FUNCS = proxy_funcs
            }
        )

        util.write_template(
            path.join(tmpl_dir, "dll.def.in"),
            path.join("build", "dll.def"),
            {
                EXPORT_FUNCS = exports_funcs
            }
        )
    end)

    add_files("build/proxy.c")

    if is_plat("windows") then add_files("build/dll.def") end
    if is_plat("mingw") then add_shflags("build/dll.def", {force = true}) end
end
