# gitops

The desired state of every QNSC cluster. One Helm chart, one values file per
(product, environment), and the ArgoCD Applications that reconcile them.

Design reference: `infra/docs/kubernetes-platform-design.md`.
Task breakdown: `infra/docs/implementation-plan.md`.

> Branch protection on this repository is a **production access control**, not a
> code-quality convention (§10b). Whoever can push here can deploy anything.

```
charts/qnsc-service/     the chart. ONE chart for all ~15 services (§4b)
values/<product>/        base.yaml + dev.yaml + prod.yaml
apps/                    ArgoCD Applications, one per (product, env)
appsets/                 ApplicationSet with the PR generator — preview envs (§11)
rendered/                committed `helm template` output. The review artefact (§11c)
versions.yaml            every component version, pinned in one place (§2b)
```

## The three rules that keep this maintainable

### 1. Ask the kind table. Never test the kind.

`templates/_kinds.tpl` declares what each service kind needs — workload, service
type, route type, whether it scales, whether it gets a PDB, its default capacity.
Templates read that table.

```gotemplate
{{- $svc  := include "qnsc.svc"  (list $ $name) | fromYaml }}
{{- $caps := include "qnsc.caps" $svc.kind      | fromYaml }}
{{- if eq $caps.workload "Deployment" }}
```

**No template may contain `if eq $svc.kind "http"`.** If you need one, the table is
missing a column — add the column.

This is what keeps a new kind cheap. Adding `batch` should be one row in
`_kinds.tpl` plus at most one new template file. It must never mean auditing every
existing template for a condition that needs a new branch.

### 2. The chart has no dev/prod branch

ArgoCD loads `base.yaml` then `dev.yaml` or `prod.yaml`, and Helm deep-merges them
before the chart sees anything. The chart renders one environment and does not know
there is another.

```
base.yaml        what the product is — and WHY, transcribed from the live OpenTofu
dev.yaml         what dev turns OFF — autoscaling, PDBs, realistic requests (§5b)
prod.yaml        anything genuinely prod-only
tags.<env>.yaml  GENERATED. Image tags. CI owns this file; humans own the others
```

**The split is not cosmetic.** `yq -i` rewrites whatever file it touches, and CI
runs it on every merge to main. `values/kb/base.yaml` carries 55 lines of reasoning
copied out of the live OpenTofu — why the api stays off Spot, why clamav needs
2 GB, why the worker is pinned at one replica. A tag bump must not be able to
reflow or drop any of it.

It also makes a promotion pull request a three-line diff instead of a diff against
a file full of prose (§11).

One trap worth knowing if you edit an overlay: a service key with nothing under it
is `null`, not "no overrides" — and **null REPLACES the merged map** rather than
merging into it, taking `kind` with it. A service that overrides nothing in an
environment should not appear in that file at all.

An `if eq .Values.env "prod"` in a template duplicates a merge Helm already did.

### 3. Names are derived, never passed

`infra` computes the same strings from the same three variables (§7c). Nothing
crosses the repository boundary, so nothing can drift.

```
ECR repository    rova-api                      product + service. NO environment —
                                                promotion is "the same image gets a
                                                second tag", and a per-env repository
                                                would mean copying bytes
namespace         rova                          the cluster IS the environment
Deployment        api                           the namespace IS the product
IRSA role         qnsc-prod-rova-api
secret path       qnsc/prod/rova/database-url   a path, so one IAM wildcard scopes it
```

Exactly one fact is declared in both repositories — `size` — and CI fails if the two
disagree. Do not build a generator for it.

## How a change reaches a cluster

```
apps/root.yaml          the ONE thing installed by hand (§13's bootstrap answer)
  → apps/project.yaml   what a product Application may create — an allow-list,
                        not "*", so an unexpected kind fails at sync
  → appsets/products.yaml   one Application per (product, env), chart PINNED per row
  → appsets/preview.yaml    one full environment per labelled pull request
```

Three kinds of change, three blast radii — worth knowing which one you are making:

```
a values file         one product, one environment      §11's promotion
a chartVersion row    one product, one environment      §11c's pinned bump
the appset TEMPLATE   EVERY Application at once         rare, and reviewed as such
```

## Adding a product

```
1  values/<product>/base.yaml      product, size, services
2  values/<product>/{dev,prod}.yaml
3  apps/<product>-{dev,prod}.yaml  Application with a PINNED chart version (§11c)
4  infra/live/<product>/<env>      the product-profile module call
5  commit rendered/ output — the diff IS the review
```

If the eight axes cannot express the product, **the chart gains a field**. A product
that hand-writes a manifest is the seven-copies problem returning (§5).

## Working on the chart

```bash
# lint is PER VALUES FILE — a bare `helm lint` fails by design, because the chart
# is not renderable without a product (values.schema.json requires product, env
# and services, and there are no empty placeholders for them)
helm lint charts/qnsc-service -f values/rova/base.yaml -f values/rova/prod.yaml

helm unittest charts/qnsc-service       # the platform invariants
./scripts/render.sh                     # regenerate rendered/ — COMMIT THE RESULT
```

**A chart change is reviewed on its rendered diff, not its template diff.** Unit
tests pass while "this silently removes the PDB from every size-M service" ships;
the golden render does not (§11c). CI fails if `rendered/` is stale, and prints the
diff — which is what the change does to production.

The invariants under `charts/qnsc-service/tests/` each guard a decision that was
expensive to reach and would be cheap to undo by accident: no CPU limits, memory
limit equal to request, liveness pointing at nothing with a dependency, PSS
`restricted`, `trafficDistribution` on every Service, and no `replicas` when a
ScaledObject owns it.

## Things that look wrong and are not

```
no CPU limits anywhere        CFS quota throttles on 100 ms bursts, not averages, so
                              an IO-bound service is throttled at 20% average CPU —
                              and it presents as latency with no OOMKill and no
                              alarm. Every service here is that shape (§15d)

memory limit == request       memory is not compressible. Bursting only defers an
                              OOMKill to a worse moment, and it breaks bin-packing.
                              Equal values also give Guaranteed QoS (§15d)

liveness never checks a dep   if liveness touches the database and the database
                              slows down, Kubernetes kills every replica of every
                              service at once (§9j). The chart exposes
                              `readinessPath` only; liveness is hardcoded

grpc gets a HEADLESS Service  gRPC multiplexes over one HTTP/2 connection and a
                              ClusterIP balances per CONNECTION, so one client pins
                              to one pod forever. This is also why no service mesh
                              is needed (§4d)

realtime ignores the preset   PDB at every size including XS. An unguarded drain
                              drops every connected client, and Karpenter drains
                              eagerly (§4e)

no replicas when scaling set  a ScaledObject and a Deployment fight over the field
                              on every reconcile
```

## What checks what

Three layers, and the third exists because the first two cannot see the bugs it
catches.

```
helm lint · unittest      this chart, in isolation
golden render             what this chart produces, as a reviewable diff
platform conformance      contracts that CROSS repositories — ci/scripts/
```

A review on 2026-09-16 found five bugs in one day, every one the same shape: **a
reference and its definition in different files, each individually valid.**
`terraform validate`, `helm lint` and `helm unittest` all passed on all five.

```
api and worker had NO envFrom       they would have crashed on the first
                                    DATABASE_URL read, with the ExternalSecret
                                    beside them looking healthy
KEDA queried a Prometheus           that nothing installs and nothing will
platform/ referenced three secrets  nothing created
five stacks read kms_key_arn        from the wrong remote state
and private_route_table_ids         which no stack exports
```

Per-concern directories are the right structure and are exactly what lets this
hide. The answer is not reorganising folders — it is `ci/scripts/platform_conformance.py`,
which is the only tool that reads more than one repository.

**Repo-local tooling stays local** (`scripts/render.sh` renders this chart).
**Cross-repo contracts live in `ci`**, because no single repo can host a check
that spans several.

## Versions

Everything is pinned in `versions.yaml` — one file, so §2b's quarterly
compatibility check is one diff. Bump one component per PR with the upstream
changelog linked, dev first, then prod.

**Verify every version before the first install.** They were written 2026-09-15 and
releases move.
