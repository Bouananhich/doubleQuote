#!/usr/bin/env python3
"""Licence inventory of everything that actually reaches the build.

The repo is GPL-2.0-or-later, because it forks Morpho's GPL-2.0-or-later buy-callback periphery.
Both the Uniswap and Midnight dependencies ship BUSL-1.1 core beside permissively-licensed
interfaces and libraries *in the same tree*, so which files end up in a compilation unit is a
property worth watching rather than assuming.

**This reads Foundry's build-info rather than parsing imports**, and the difference is not
academic. The first version of this check walked only the imports written in `src/` and `test/` —
one hop — and concluded that nothing BUSL-1.1 reached the build. It does: `StateLibrary` and
`TransientStateLibrary` are both MIT and both pull BUSL-1.1 files in behind them. One hop sees 29
files; the compiler sees 64.

BUSL-1.1 is not a violation here and is not treated as one. Its terms grant copying,
redistribution and **non-production use** outright; only production use needs the Additional Use
Grant at `v4-core-license-grants.uniswap.eth`. What matters is that the BUSL surface stays *known*,
so it is enumerated below and the check fails when it changes — which is the moment somebody should
think about it again, in particular before anything is deployed for real.
"""

import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD_INFO = ROOT / "out" / "build-info"

# Compatible with GPL-2.0-or-later distribution, no questions asked.
PERMISSIVE = {"MIT", "MIT OR Apache-2.0", "Apache-2.0", "GPL-2.0-or-later"}

# BUSL-1.1 files known to reach the build, and how. Adding to this list is a deliberate act.
EXPECTED_BUSL = {
    "lib/v4-core/src/libraries/Position.sol": "via StateLibrary (MIT)",
    "lib/v4-core/src/libraries/CurrencyReserves.sol": "via TransientStateLibrary (MIT)",
    "lib/v4-core/src/libraries/Lock.sol": "via TransientStateLibrary (MIT)",
    "lib/v4-core/src/libraries/NonzeroDeltaCount.sol": "via TransientStateLibrary (MIT)",
}


def compiled_sources():
    """Every source in the build closure, from a freshly written build-info.

    Cleared first: `out/build-info` accumulates a file per compilation unit and never prunes, so a
    stale unit from a deleted contract would report imports nothing has any more.
    """
    shutil.rmtree(BUILD_INFO, ignore_errors=True)

    # Captured rather than discarded: `forge build` writes its lint notes to stderr on a *successful*
    # build, which is noise here, but it writes the compiler errors there too. Suppressing the
    # stream outright would turn a broken build into a bare traceback with the diagnosis thrown
    # away — so it is held and only printed when it is the thing you need.
    build = subprocess.run(["forge", "build", "--build-info"], cwd=ROOT, capture_output=True, text=True)
    if build.returncode != 0:
        sys.stderr.write(build.stdout)
        sys.stderr.write(build.stderr)
        raise SystemExit(f"forge build failed ({build.returncode}); nothing to inventory")

    paths = set()
    for unit in BUILD_INFO.glob("*.json"):
        paths.update(json.loads(unit.read_text()).get("source_id_to_path", {}).values())
    return paths


def spdx(path):
    """The file's declared licence. Not always line one — forge-std's generated `Vm.sol` carries a
    `@generated` banner above its header."""
    for line in path.read_text(errors="replace").splitlines()[:10]:
        if "SPDX-License-Identifier:" in line:
            return line.split("SPDX-License-Identifier:", 1)[1].strip()
    return None


def main():
    dependencies = sorted(p for p in compiled_sources() if p.startswith("lib/"))
    if not dependencies:
        print("no dependency sources in the build closure — is build-info being written?")
        return 1

    failures = []
    seen_busl = set()
    counts = {}

    for rel in dependencies:
        licence = spdx(ROOT / rel)
        key = licence or "(none declared)"
        counts[key] = counts.get(key, 0) + 1

        if licence in PERMISSIVE:
            continue
        if licence == "BUSL-1.1":
            seen_busl.add(rel)
            if rel not in EXPECTED_BUSL:
                failures.append(f"unexpected BUSL-1.1 source in the build: {rel}")
            continue
        failures.append(f"undeclared or unrecognised licence {licence!r}: {rel}")

    print(f"{len(dependencies)} dependency sources in the build closure:")
    for licence, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {n:4d}  {licence}")

    for rel, why in sorted(EXPECTED_BUSL.items()):
        if rel in seen_busl:
            print(f"  BUSL-1.1, expected: {rel} — {why}")
        else:
            print(f"  note: {rel} is listed as expected BUSL but no longer reaches the build")

    for failure in failures:
        print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
