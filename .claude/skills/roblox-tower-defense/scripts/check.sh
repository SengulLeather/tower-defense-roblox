#!/usr/bin/env bash
# check.sh — run every available static check for a Roblox/Luau project and
# this skill's template tests. Missing tools are reported, not fatal.
#
# Usage:  check.sh [project_dir]            (default: git root or cwd)
# Env overrides for tool paths: STYLUA, SELENE, LUNE, ROJO, LUAU_LSP
#   LUAU_LSP_DEFS=/path/globalTypes.d.luau  enables `luau-lsp analyze`
#   SRC_DIRS="src tests"                    directories to check (default: src)
#
# Exit status: 0 if every check that ran passed, 1 otherwise.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$PROJECT_DIR" || exit 1

read -r -a SRC <<<"${SRC_DIRS:-src}"
EXISTING_SRC=()
for d in "${SRC[@]}"; do [[ -e "$d" ]] && EXISTING_SRC+=("$d"); done

failed=0
ran=()
skipped=()

tool() { # tool <ENV_VAR> <binary>  -> prints path or nothing
	local override="${!1:-}"
	if [[ -n "$override" ]]; then echo "$override"; return; fi
	command -v "$2" 2>/dev/null || true
}

step() { # step <name> <cmd...>
	local name="$1"; shift
	echo "==> $name"
	if "$@"; then
		ran+=("$name: ok")
	else
		ran+=("$name: FAILED")
		failed=1
	fi
	echo
}

STYLUA_BIN="$(tool STYLUA stylua)"
SELENE_BIN="$(tool SELENE selene)"
LUNE_BIN="$(tool LUNE lune)"
ROJO_BIN="$(tool ROJO rojo)"
LSP_BIN="$(tool LUAU_LSP luau-lsp)"

if [[ ${#EXISTING_SRC[@]} -eq 0 ]]; then
	skipped+=("project checks: no source dirs found (${SRC[*]}) in $PROJECT_DIR")
else
	if [[ -n "$STYLUA_BIN" ]]; then
		step "stylua --check ${EXISTING_SRC[*]}" "$STYLUA_BIN" --check "${EXISTING_SRC[@]}"
	else
		skipped+=("stylua (rokit install, or: npm i @johnnymorganz/stylua-bin)")
	fi

	if [[ -n "$SELENE_BIN" ]]; then
		step "selene ${EXISTING_SRC[*]}" "$SELENE_BIN" "${EXISTING_SRC[@]}"
	else
		skipped+=("selene (rokit install, or: cargo install selene)")
	fi

	if [[ -n "$ROJO_BIN" && -f default.project.json ]]; then
		out="$(mktemp -d)/check.rbxl"
		step "rojo build" "$ROJO_BIN" build default.project.json -o "$out"
	elif [[ -f default.project.json ]]; then
		skipped+=("rojo build (rokit install)")
	fi

	if [[ -n "$LSP_BIN" && -n "${LUAU_LSP_DEFS:-}" ]]; then
		args=(analyze --platform=roblox "--definitions=@roblox=$LUAU_LSP_DEFS")
		if [[ -n "$ROJO_BIN" && -f default.project.json ]]; then
			"$ROJO_BIN" sourcemap default.project.json -o sourcemap.json >/dev/null 2>&1 &&
				args+=(--sourcemap=sourcemap.json)
		fi
		step "luau-lsp analyze ${EXISTING_SRC[*]}" "$LSP_BIN" "${args[@]}" "${EXISTING_SRC[@]}"
	else
		skipped+=("luau-lsp analyze (needs luau-lsp + LUAU_LSP_DEFS=<globalTypes.d.luau>)")
	fi

	if [[ -n "$LUNE_BIN" && -f tests/run.luau ]]; then
		step "project tests (lune run tests/run.luau)" "$LUNE_BIN" run tests/run.luau
	fi
fi

if [[ -n "$LUNE_BIN" ]]; then
	step "skill template tests" "$LUNE_BIN" run "$SKILL_DIR/templates/tests/run.luau" "$SKILL_DIR/templates"
else
	skipped+=("lune tests (rokit add lune-org/lune, or: cargo install lune)")
fi

echo "==> Summary ($PROJECT_DIR)"
for r in "${ran[@]}"; do echo "  $r"; done
for s in "${skipped[@]}"; do echo "  skipped: $s"; done
exit "$failed"
