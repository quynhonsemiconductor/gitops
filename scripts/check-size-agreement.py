#!/usr/bin/env python3
"""Fail when `size` disagrees between gitops and infra.

§7c: "`size` is the one fact declared in two repositories, and nothing else does."

    gitops/values/rova/prod.yaml        size: l
    infra/live/rova/prod/main.tf        size = "l"

Everything else crossing the boundary is DERIVED — the IRSA role, the secret path,
the queue URL are all computed from product, env and service on both sides, so
they cannot drift. `size` genuinely cannot be: OpenTofu picks an RDS instance class
from it and the chart picks replica counts and PDBs from it, and neither can read
the other's file at plan time.

§7c is explicit about not over-engineering the fix:

    "Do not build a generator for this. A CI check is ten lines and catches the
     only drift that matters. Making one side authoritative would mean generating
     Terraform from YAML or the reverse, and the machinery would cost more than
     the problem."

So: ten lines of comparison, and a lot of comment explaining why it is only ten.

    ./scripts/check-size-agreement.py                    # from the gitops repo
    ./scripts/check-size-agreement.py --infra ../infra
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

import yaml

# `size = "l"`, tolerating any spacing. Deliberately a regex and not an HCL parser:
# a parser would need the module resolved, a provider configured and a working
# backend, which is a lot of machinery for one string.
SIZE_HCL = re.compile(r'^\s*size\s*=\s*"([a-z]+)"', re.M)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--infra", default="../infra", type=pathlib.Path)
    ap.add_argument("--values", default="values", type=pathlib.Path)
    args = ap.parse_args()

    checked, mismatches, unpaired = 0, [], []

    for base in sorted(args.values.glob("*/base.yaml")):
        product = base.parent.name
        merged_size = (yaml.safe_load(base.read_text()) or {}).get("size")

        for envfile in sorted(base.parent.glob("*.yaml")):
            env = envfile.stem
            if env == "base":
                continue

            gitops_size = (yaml.safe_load(envfile.read_text()) or {}).get("size", merged_size)

            # infra/live/<product>/<env>. A product that has not migrated yet has
            # no infra stack, which is not a failure — §17 migrates one at a time.
            stack = args.infra / "live" / product / env
            if not stack.is_dir():
                unpaired.append(f"{product}/{env}  gitops says {gitops_size!r}, no infra stack yet")
                continue

            hcl = "".join(f.read_text() for f in stack.glob("*.tf"))
            found = SIZE_HCL.findall(hcl)
            if not found:
                unpaired.append(f"{product}/{env}  gitops says {gitops_size!r}, infra declares no size")
                continue

            checked += 1
            if found[0] != gitops_size:
                mismatches.append(
                    f"{product}/{env}  gitops={gitops_size!r}  infra={found[0]!r}"
                )

    for u in unpaired:
        print(f"  unpaired  {u}")
    if checked:
        print(f"\n  {checked} pair(s) checked")

    if mismatches:
        print("\n  SIZE DISAGREES — one of these is wrong:\n")
        for m in mismatches:
            print(f"    {m}")
        print("""
  size decides the RDS instance class on the infra side and the replica floor,
  PodDisruptionBudget and topology spread on the chart side (§5). A disagreement
  means a product is being protected at one tier and provisioned at another, and
  neither file is obviously the wrong one — which is why this fails rather than
  picking a winner.""")
        return 1

    print("  size agrees everywhere it is declared on both sides")
    return 0


if __name__ == "__main__":
    sys.exit(main())
