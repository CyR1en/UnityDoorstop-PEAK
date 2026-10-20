#!/usr/bin/env bash
#
# ABI regression test for the doorstop proxy.
#
# The proxy forwards the exports of a DLL. The forwarding has to be
# transparent for every calling convention: the argument registers, the stack
# arguments and the return value have to reach the forwarded function
# unchanged.
#
# The test generates the proxy the same way the build does, compiles it with a
# Windows toolchain and checks the machine code of every export:
#
#   * every export is a single jump,
#   * no export adjusts the stack, so the stack arguments of the caller stay
#     where they are,
#   * no export calls, because a call would need the exact prototype of the
#     forwarded function.
#
# The check runs with and without optimisation, because the old generator was
# only correct when the compiler turned the wrapper into a jump, which it only
# did when it optimised.
#
# Usage: tests/proxy_abi_test.sh [--list path/to/proxylist.txt]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

LIST="${1:-$REPO_ROOT/src/windows/proxy/proxylist.txt}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/doorstop-abi-XXXXXX")"

CC="${CC:-x86_64-w64-mingw32-gcc}"
OBJDUMP="${OBJDUMP:-llvm-objdump}"
if ! command -v "$CC" >/dev/null 2>&1; then
    echo "skip: $CC is not installed" >&2
    exit 0
fi
if ! command -v "$OBJDUMP" >/dev/null 2>&1 && ! command -v "x86_64-w64-mingw32-objdump" >/dev/null 2>&1; then
    echo "skip: no objdump is installed" >&2
    exit 0
fi

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAILED=0

fail() {
    FAILED=1
    echo "  FAIL $1" >&2
}

# The generator of the build, reduced to what the test needs.
generate() {
    local out="$1"
    local defs="" adds="" funcs="" exports=""

    while IFS= read -r name; do
        name="$(printf '%s' "$name" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$name" ] || continue

        local module="dll"
        case "$name" in
            GetFileVersionInfo* | Ver*) module="version_dll" ;;
        esac

        defs="$defs
static FARPROC __${name}__;"
        adds="$adds
__${name}__ = proxy_resolve((HMODULE)$module, \"$name\", proxy_self());"
        funcs="$funcs
PROXY_NAKED void exp_${name}(void) { __asm__(\"jmp *__${name}__\"); }"
        exports="$exports
$name = exp_$name"
    done <"$LIST"

    cat >"$out/proxy.c" <<EOF
#include <windows.h>
#include "$REPO_ROOT/src/windows/proxy/proxy.h"
$defs

void load_functions(void *dll, void *version_dll)
{
$adds
}
$funcs
EOF

    printf 'EXPORTS\n%s\n' "$exports" >"$out/dll.def"
}

check() {
    local opt="$1"
    local dir="$WORK/$opt"
    mkdir -p "$dir"
    generate "$dir"

    echo "== $opt"

    if ! "$CC" -c "$opt" -Wno-int-conversion -Wno-incompatible-pointer-types \
        -o "$dir/proxy.o" "$dir/proxy.c" 2>"$dir/build.log"; then
        fail "$opt: the proxy does not compile"
        sed 's/^/    /' "$dir/build.log" >&2
        return
    fi

    local dump
    if command -v "$OBJDUMP" >/dev/null 2>&1; then
        dump="$("$OBJDUMP" -d --section=.text "$dir/proxy.o")"
    else
        dump="$(x86_64-w64-mingw32-objdump -d "$dir/proxy.o")"
    fi
    printf '%s\n' "$dump" >"$dir/proxy.asm"

    # Every export has to be a jump and nothing else.
    local name body
    while IFS= read -r name; do
        name="$(printf '%s' "$name" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$name" ] || continue

        body="$(printf '%s\n' "$dump" \
            | sed -n "/<exp_$name>:/,/^$/p" \
            | sed '1d' \
            | grep -vE '^\s*$')"

        if [ -z "$body" ]; then
            fail "$opt: $name is not in the object file"
            continue
        fi

        if printf '%s\n' "$body" | grep -qE '\bcall'; then
            fail "$opt: $name calls instead of jumping"
        fi
        if printf '%s\n' "$body" | grep -qE '\b(push|pop)\b|\brsp\b'; then
            fail "$opt: $name touches the stack"
        fi
        if ! printf '%s\n' "$body" | grep -qE '\bjmpq?\b'; then
            fail "$opt: $name is not a jump"
        fi
    done <"$LIST"

    if [ "$FAILED" -eq 0 ]; then
        echo "  ok: every export is a jump that leaves the stack alone"
    fi
}

check -O0
check -O2

# Every name in the list has to be unique, and the list must not be empty.
if [ -z "$(grep -cve '^[[:space:]]*$' "$LIST")" ]; then
    fail "the proxy list is empty"
fi

duplicates="$(grep -vE '^[[:space:]]*$' "$LIST" | tr -d '\r' | sort | uniq -d)"
if [ -n "$duplicates" ]; then
    fail "the proxy list has duplicates: $duplicates"
fi

if [ "$FAILED" -ne 0 ]; then
    echo "the ABI regression test failed" >&2
    exit 1
fi

echo "the ABI regression test passed"
