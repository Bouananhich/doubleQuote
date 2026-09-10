#!/usr/bin/env bash
#
# The repo is GPL-2.0-or-later, because it forks Morpho's GPL-2.0-or-later buy-callback periphery.
# Two of its dependencies ship BUSL-1.1 source in the same tree as permissively-licensed source:
# Midnight's core sits beside its GPL periphery, and Uniswap v4's `PoolManager` sits beside its MIT
# libraries. Binding those through interfaces is the whole reason this project compiles as one
# profile — and it is also what keeps it distributable.
#
# So this is a compliance check, not a style check: it fails if any file under `src/` or `test/`
# imports a dependency file whose own SPDX header is not GPL-2.0-or-later-compatible.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0

resolve() {
  case "$1" in
    v4-core/*) echo "lib/v4-core/src/${1#v4-core/}" ;;
    forge-std/*) echo "lib/forge-std/src/${1#forge-std/}" ;;
    *) echo "lib/$1" ;;
  esac
}

for import in $(grep -rhoE '(v4-core|midnight|forge-std)/[A-Za-z0-9/_.-]+\.sol' src test | sort -u); do
  path="$(resolve "$import")"
  if [[ ! -f "$path" ]]; then
    echo "unresolved import: $import (looked in $path)"
    status=1
    continue
  fi

  spdx="$(grep -m1 -oE 'SPDX-License-Identifier:[[:space:]]*[^[:space:]*]+' "$path" | awk '{print $2}')"
  case "$spdx" in
    MIT|GPL-2.0-or-later|Apache-2.0|"MIT OR Apache-2.0") ;;
    *)
      echo "incompatible license '$spdx' imported: $import"
      status=1
      ;;
  esac
done

if [[ $status -eq 0 ]]; then
  echo "all imported dependency sources are GPL-2.0-or-later compatible"
fi
exit $status
