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
{{- if $svc.image.digest -}}
{{- /* digest mode: repo@sha256:<64 hex> — what `k8s-deploy` writes going
         forward. A digest pins the exact bytes; a tag is rewritable. Digest
         WINS when both are set, and the tag is then ignored. */}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" ($svc.image.digest | toString)) -}}
{{- fail (printf "service %q: image.digest must match ^sha256:[a-f0-9]{64}$, got %q" $name ($svc.image.digest | toString)) -}}
{{- end -}}
{{- printf "%s@%s" (required "image.repo is required" $svc.image.repo) $svc.image.digest -}}
{{- else if not $svc.image.tag -}}
{{- fail (printf "service %q: image.tag (or image.digest) is required — the chart never defaults a tag, because `latest` is how a develop build reached production (§11)" $name) -}}
{{- else -}}
{{- printf "%s:%s" (required "image.repo is required" $svc.image.repo) $svc.image.tag -}}
{{- end -}}
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
{{- $base := dict "drain" dict "resources" dict "image" dict "sidecars" list -}}
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
{{- if and $out.replicas (gt (int $out.replicas) 1) -}}
{{- fail (printf "service %q: singleton and replicas=%v are contradictory. A singleton must never have two replicas — see qnsc-kb's beat" $name $out.replicas) -}}
{{- end -}}
{{- $_ := set $out "replicas" 1 -}}
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
{{- /* ── THE ESTATE'S ACTUAL HOSTNAME CONVENTION ──────────────────────────────
       Read off the live zone, because the previous two attempts here were both
       wrong in ways nothing would have caught until traffic moved:

         rova-dev.qnsc.vn      -> rova-develop-web.pages.dev    the FRONTEND
         rova-api-dev.qnsc.vn  -> <tunnel>.cfargotunnel.com     the API
         rova-api.qnsc.vn      -> <tunnel>.cfargotunnel.com     prod API

       This chart serves the API. It first emitted `<product>.dev.qnsc.vn`, which
       no certificate covers (Universal SSL stops at one wildcard level, so the
       TLS handshake fails at the edge with SSL alert 40). The fix for that then
       emitted `<product>-dev.qnsc.vn` — which RESOLVES, and belongs to the
       Cloudflare Pages frontend. Taking it would have replaced the web app with
       an API.

       So the name carries the SERVICE, which is what makes it an API hostname
       and not a product hostname. One level deep, so Cloudflare issues the
       certificate automatically and for free. */}}
{{- if $svc.host -}}
{{- $svc.host -}}
{{- else if eq (include "qnsc.env" $root) "prod" -}}
{{- printf "%s-%s.qnsc.vn" (include "qnsc.product" $root) (index . 2 | default "api") -}}
{{- else -}}
{{- printf "%s-%s-dev.qnsc.vn" (include "qnsc.product" $root) (index . 2 | default "api") -}}
{{- end -}}
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
PreSync prerequisites of the migrator Job (job.yaml). ArgoCD runs ALL hooks before
ANY normal resource, so what the PreSync Job needs must be a hook, one wave before
the Job (wave 0). A hook is DELETED and recreated every sync, so ONLY resources
used exclusively by the Job may be hooks:

  ServiceAccount `migrator`            serviceaccount.yaml
  ExternalSecret <product>-migrator    -> Secret envFrom'd by the Job
  ExternalSecret <product>-migrator-db-ca -> the Job's own copy of the CNPG CA
                                      (a missing volume Secret keeps the pod in
                                      ContainerCreating until the deadline)

Argo's built-in health check holds wave 0 until each ExternalSecret is Ready.
Deliberately NOT hooked (shared with running workloads): the api/worker
ServiceAccounts (new UID -> bound tokens invalidated), the SecretStore (the
<product>-app ExternalSecret would go NotReady each sync), the shared
<product>-db-ca (its Secret is mounted by running Deployments). AWS-era gap: the
SecretStore is a normal resource, so a never-synced AWS namespace has no store at
PreSync; on-prem uses a platform ClusterSecretStore and is unaffected.
*/}}
{{- define "qnsc.presyncPrereq" -}}
argocd.argoproj.io/hook: PreSync
argocd.argoproj.io/sync-wave: "-1"
argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
{{- end }}

{{/*
ON-PREM SECRET SHAPE (ONPREM-PLAN §5.6). `secrets.clusterSecretStore` set -> the
ExternalSecrets read that platform-owned ClusterSecretStore (kv-qnsc-<env>) and the
chart renders NO SecretStore of its own; unset -> the AWS shape (per-namespace
SecretStore on IRSA, find+rewrite). Returns "true" or "" for use as a condition.
*/}}
{{- define "qnsc.onpremStore" -}}
{{- if and .Values.secrets .Values.secrets.clusterSecretStore -}}true{{- end -}}
{{- end }}

{{- define "qnsc.storeRef" -}}
{{- if include "qnsc.onpremStore" . -}}
name: {{ .Values.secrets.clusterSecretStore }}
kind: ClusterSecretStore
{{- else -}}
name: {{ include "qnsc.product" . }}
kind: SecretStore
{{- end -}}
{{- end }}

{{/* Remote key: role "app" -> secrets.bundle (<product>-<env>-app); role "migrator" ->
     secrets.db (<product>-<env>-db-app), the credential the plan gives the DB role. */}}
{{- define "qnsc.remoteKey" -}}
{{- $root := index . 0 -}}{{- $role := index . 1 -}}
{{- $sec := $root.Values.secrets | default dict -}}
{{- if eq $role "app" -}}
{{- $sec.bundle | default (printf "%s-%s-app" (include "qnsc.product" $root) (include "qnsc.env" $root)) -}}
{{- else -}}
{{- $sec.db | default (printf "%s-%s-db-app" (include "qnsc.product" $root) (include "qnsc.env" $root)) -}}
{{- end -}}
{{- end }}
