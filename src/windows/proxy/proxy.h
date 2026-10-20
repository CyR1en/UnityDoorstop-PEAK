#ifndef PROXY_H
#define PROXY_H

#include "../../crt.h"
#include "../../util/logging.h"
#include "../../util/util.h"
#include <windows.h>

#define ALT_POSTFIX TEXT("_alt.dll")
#define DLL_POSTFIX TEXT(".dll")

extern void load_functions(void *dll, void *version_dll);

/**
 * @brief The stub that is called when an export could not be resolved.
 *
 * It returns zero, which is the failure value of most of the functions that
 * are forwarded here. Jumping to a null pointer instead would be an access
 * violation inside the calling module, which is a lot harder to diagnose.
 */
#if defined(__GNUC__) || defined(__clang__)
#define PROXY_NAKED __attribute__((naked))
#else
#define PROXY_NAKED __declspec(naked)
#endif

PROXY_NAKED static void proxy_unresolved(void) {
    __asm__("xorl %eax, %eax\n\t"
            "ret");
}

/**
 * @brief The module that the proxy itself lives in.
 */
static inline HMODULE proxy_self(void) {
    HMODULE self = NULL;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                             (LPCWSTR)&proxy_self, &self))
        return NULL;
    return self;
}

/**
 * @brief Resolves one exported function.
 *
 * The resolution is checked: a name that cannot be resolved points at the
 * stub instead of at a null pointer, and a name that would resolve to the
 * proxy itself is refused, because forwarding to yourself is an endless
 * loop.
 *
 * @param module The module to resolve the name in
 * @param name The name of the exported function
 * @param self The module of the proxy, used to detect a self reference
 * @return The resolved function, or the stub
 */
static inline FARPROC proxy_resolve(HMODULE module, const char *name,
                                     HMODULE self) {
    if (module == NULL) {
        LOG("Could not resolve %s: the module is not loaded.", name);
        return (FARPROC)proxy_unresolved;
    }

    FARPROC proc = (FARPROC)GetProcAddress(module, name);
    if (proc == NULL) {
        LOG("Could not resolve %s. The export returns a failure instead of "
            "jumping to a null pointer.",
            name);
        return (FARPROC)proxy_unresolved;
    }

    HMODULE owner = NULL;
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                            (LPCWSTR)proc, &owner) &&
        owner == self) {
        LOG("Refusing to forward %s to the proxy itself.", name);
        return (FARPROC)proxy_unresolved;
    }

    return proc;
}

/**
 * @brief Loads the original DLL that the proxy forwards to.
 *
 * The system directory is searched first, so that the copy next to the game
 * is never picked up. Forwarding to the proxy itself would be an endless
 * loop, and the caller checks for that as well.
 *
 * @param module_name The name of the module, without the extension
 * @param self The module of the proxy
 * @return The handle of the original module, or NULL
 */
static inline HMODULE load_original(char_t *module_name, HMODULE self) {
    UINT sys_len = GetSystemDirectory(NULL, 0);
    char_t *sys_full_path = (char_t *)malloc(
        (sys_len + strlen(module_name) + STR_LEN(DLL_POSTFIX)) *
        sizeof(char_t));
    GetSystemDirectory(sys_full_path, sys_len);
    sys_full_path[sys_len - 1] = TEXT('\\');
    strcpy(strcpy(sys_full_path + sys_len, module_name) + strlen(module_name),
           DLL_POSTFIX);

    LOG("Looking for original DLL from %s", sys_full_path);

    HMODULE handle = (HMODULE)dlopen(sys_full_path, RTLD_LAZY);
    free(sys_full_path);

    if (handle != NULL && handle == self) {
        LOG("The original %s.dll is the proxy itself. Refusing to forward to "
            "it.",
            module_name);
        FreeLibrary(handle);
        return NULL;
    }

    return handle;
}

/**
 * @brief Loads the original DLLs and forwards the exports to them.
 *
 * @param module_name The name of the module the proxy stands in for
 */
static inline void load_proxy(char_t *module_name) {
    HMODULE self = proxy_self();

    HMODULE handle = load_original(module_name, self);
    if (handle == NULL) {
        UINT sys_len = GetSystemDirectory(NULL, 0);
        char_t *alt_name = (char_t *)malloc(
            (strlen(module_name) + STR_LEN(ALT_POSTFIX)) * sizeof(char_t));
        strcat(strcpy(alt_name, module_name), ALT_POSTFIX);

        char_t *alt_full_path = get_full_path(alt_name);
        free(alt_name);

        LOG("Looking for original DLL from %s", alt_full_path);
        handle = (HMODULE)dlopen(alt_full_path, RTLD_LAZY);
        free(alt_full_path);

        if (handle != NULL && handle == self) {
            LOG("The alternative %s.dll is the proxy itself. Refusing to "
                "forward to it.",
                module_name);
            FreeLibrary(handle);
            handle = NULL;
        }
    }

    /* The version functions are forwarded to version.dll. They are in the
     * export list because some games import them, and they used to be
     * resolved against the wrong module, which left them unresolved. */
    HMODULE version = load_original(TEXT("version"), self);

    load_functions(handle, version);
}

#endif
