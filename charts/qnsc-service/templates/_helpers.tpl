{{/*
────────────────────────────────────────────────────────────────────────────────
NAMING — design §7c

Every name is DERIVED, never passed. `infra` computes the same strings from the
same three variables, so nothing crosses the repository boundary and nothing can
drift.

A name encodes exactly the dimensions the thing varies on:

  product only          ECR repository      rova-api
                        (NO environment — promotion is "the same image gets a
                        second tag", so a per-env repository would mean copying
                        bytes and the attestation would stop covering prod)
  product               namespace           rova        (the cluster IS the env)
  service               Deployment          api         (the namespace IS the product)
  product + env + svc   IRSA role           qnsc-prod-rova-api
  env + product + name  secret path         qnsc/prod/rova/database-url
────────────────────────────────────────────────────────────────────────────────
*/}}

{{/* Product slug. Short form: `kb`, not `qnsc-kb` (§7c decision 3). */}}
{{- define "qnsc.product" -}}
{{- required "values: `product` is required" .Values.product -}}
{{- end -}}

{{/* Environment. `dev` or `prod` — never `develop`/`production` (§7c decision 1). */}}
{{- define "qnsc.env" -}}
{{- $env := required "values: `env` is required" .Values.env -}}
{{- if not (has $env (list "dev" "prod")) -}}
{{- fail (printf "values: `env` must be dev or prod, got %q — see §7c" $env) -}}
{{- end -}}
{{- $env -}}
{{- end -}}

{{/* Service name inside the namespace: just `api`. The namespace says the product. */}}
{{- define "qnsc.svcName" -}}
{{- index . 1 -}}
{{- end -}}

{{/* IRSA role name: qnsc-prod-rova-api. Must be globally unique in the account. */}}
{{- define "qnsc.roleName" -}}
{{- $root := index . 0 -}}
{{- printf "qnsc-%s-%s-%s" (include "qnsc.env" $root) (include "qnsc.product" $root) (index . 1) -}}
{{- end -}}

{{/* Secrets Manager prefix: qnsc/prod/rova — a path, so one IAM wildcard scopes it (§8). */}}
{{- define "qnsc.secretPrefix" -}}
{{- printf "qnsc/%s/%s" (include "qnsc.env" .) (include "qnsc.product" .) -}}
{{- end -}}

{{/* ECR image reference. Deliberately NO env — see the header. */}}
{{- define "qnsc.image" -}}
{{- $root := index . 0 -}}
{{- $svc := index . 1 -}}
{{- $name := index . 2 -}}
{{- if $svc.image -}}
{{- if not $svc.image.tag -}}
{{- fail (printf "service %q: image.tag is required — the chart never defaults a tag, because `latest` is how a develop build reached production (§11)" $name) -}}
{{- end -}}
{{- printf "%s:%s" (required "image.repo is required" $svc.image.repo) $svc.image.tag -}}
{{- else -}}
{{- fail (printf "service %q: `image` is required" $name) -}}
{{- end -}}
{{- end -}}


{{/*
────────────────────────────────────────────────────────────────────────────────
LABELS — one definition, used by every resource.

`app.kubernetes.io/*` are the standard set. `qnsc.vn/tenant=product` is what the
`expose: cluster` NetworkPolicy selects on (§4b), so it is not decorative.
────────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "qnsc.labels" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
app.kubernetes.io/name: {{ $name }}
app.kubernetes.io/instance: {{ include "qnsc.product" $root }}
app.kubernetes.io/part-of: {{ include "qnsc.product" $root }}
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
qnsc.vn/product: {{ include "qnsc.product" $root }}
qnsc.vn/env: {{ include "qnsc.env" $root }}
qnsc.vn/tenant: product
{{- end -}}

{{- define "qnsc.selectorLabels" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
app.kubernetes.io/name: {{ $name }}
app.kubernetes.io/instance: {{ include "qnsc.product" $root }}
{{- end -}}


{{/*
────────────────────────────────────────────────────────────────────────────────
SERVICE RESOLUTION

Returns one service's EFFECTIVE configuration: the size preset with the service's
own values merged over it.

Environment overlay is NOT handled here and must not be. ArgoCD loads
`base.yaml` then `dev.yaml`/`prod.yaml`, and Helm deep-merges them before the
chart sees anything — so the chart only ever renders one environment and needs no
branch for it. Putting `if eq .env "prod"` in a template would duplicate a merge
Helm already did.

  {{- $svc := include "qnsc.svc" (list $ $name) | fromYaml }}
────────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "qnsc.svc" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $svc := index $root.Values.services $name -}}
{{- if not $svc -}}
{{- fail (printf "no service named %q in values.services" $name) -}}
{{- end -}}
{{- $size := $svc.size | default $root.Values.size | default "s" -}}
{{- $preset := index $root.Values.presets $size -}}
{{- if not $preset -}}
{{- fail (printf "service %q: unknown size %q — valid: %s" $name $size (keys $root.Values.presets | sortAlpha | join ", ")) -}}
{{- end -}}
{{- $caps := include "qnsc.caps" (required (printf "service %q: `kind` is required" $name) $svc.kind) | fromYaml -}}
{{- /* Seed every nested structure a template may reach into, so `$svc.drain.x`
       is nil rather than a nil-pointer panic. Templates then use
       `| default $d.x` for the actual value. Guarding at the resolver means no
       template needs `(($svc.drain)).x` noise. */ -}}
{{- $base := dict "capacity" $caps.capacity "drain" dict "resources" dict "image" dict "scaling" dict "sidecars" list -}}
{{- $out := mergeOverwrite $base (deepCopy $preset) (deepCopy $svc) -}}
{{- /* ── singleton ────────────────────────────────────────────────────────────
       Some workloads must never have two replicas — not even for the few seconds
       a RollingUpdate overlaps them. qnsc-kb's Celery beat is the live example:
       "max_count stays 1 while Celery beat rides in this task — two replicas
       would double every scheduled job" (qnsc-kb-backend/infra/live/prod/main.tf).

       This is NOT the same as "runs scheduled work". rova's worker runs seven
       @Cron relays and scales to six safely, because AbstractOutboxRelay uses
       SELECT … FOR UPDATE SKIP LOCKED and ExclusiveJob holds a cross-pod lock.
       Singleton is for schedulers that hold no lock and cannot take one.

       Fail rather than silently winning, because the failure mode of getting this
       wrong is every scheduled job running twice — which looks like a data bug,
       not a deployment bug. */ -}}
{{- if $out.singleton -}}
{{- if and $out.scaling $out.scaling.max (gt (int $out.scaling.max) 1) -}}
{{- fail (printf "service %q: singleton and scaling.max=%v are contradictory. A singleton must never have two replicas — see qnsc-kb's beat" $name $out.scaling.max) -}}
{{- end -}}
{{- $_ := set $out "replicas" 1 -}}
{{- $_ := unset $out "scaling" -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}


{{/*
Public hostname — derived (§7c).

  prod   rova.qnsc.vn
  dev    rova.dev.qnsc.vn     one subdomain for the whole environment, so the
                              tunnel and any wildcard cert cover it at once
                              (§11 uses *.preview.qnsc.vn the same way)

A service may override with `host:` when a product exposes more than one.
*/}}
{{- define "qnsc.host" -}}
{{- $root := index . 0 -}}
{{- $svc := index . 1 -}}
{{- if $svc.host -}}
{{- $svc.host -}}
{{- else if eq (include "qnsc.env" $root) "prod" -}}
{{- printf "%s.qnsc.vn" (include "qnsc.product" $root) -}}
{{- else -}}
{{- printf "%s.dev.qnsc.vn" (include "qnsc.product" $root) -}}
{{- end -}}
{{- end -}}


{{/*
SQS queue URL — derived, never passed (§7c).

A values file names the queue's PURPOSE (`email-bounce`); the account id, region
and `qnsc-<env>-<product>-` prefix are computed. `infra` builds the same string
from the same three variables, so the URL never crosses the repository boundary
and the two cannot drift.

Pasting a full URL into values would be the exact mistake §7c exists to prevent.
*/}}
{{- define "qnsc.queueUrl" -}}
{{- $root := index . 0 -}}
{{- $queue := index . 1 -}}
{{- printf "https://sqs.%s.amazonaws.com/%s/qnsc-%s-%s-%s"
     $root.Values.region $root.Values.accountId
     (include "qnsc.env" $root) (include "qnsc.product" $root) $queue -}}
{{- end -}}


{{/*
Does this service get a PodDisruptionBudget?

`always` ignores the size preset. §4e: a `realtime` pod without a PDB loses every
connected client on an unguarded node drain, and Karpenter drains eagerly.
*/}}
{{- define "qnsc.wantsPDB" -}}
{{- $svc := index . 0 -}}
{{- $caps := index . 1 -}}
{{- if eq $caps.pdb "always" -}}true
{{- else if eq $caps.pdb "never" -}}
{{- else if $svc.pdb -}}true
{{- end -}}
{{- end -}}


{{/*
Node scheduling for a capacity class (§4b Axis 6).

`mixed` renders no constraint: the on-demand floor is a node-pool concern, not a
pod concern, so a `mixed` pod is schedulable anywhere and Karpenter decides.
*/}}
{{- define "qnsc.capacitySelector" -}}
{{- if eq . "spot" -}}
karpenter.sh/capacity-type: spot
{{- else if eq . "ondemand" -}}
karpenter.sh/capacity-type: on-demand
{{- end -}}
{{- end -}}
