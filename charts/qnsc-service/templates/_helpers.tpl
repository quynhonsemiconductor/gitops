{{/*
────────────────────────────────────────────────────────────────────────────────
NAMING — design §7c

Every name is DERIVED, never passed. `infra` computes the same strings from the
same three variables, so nothing crosses the repository boundary and nothing can
drift.

A name encodes exactly the dimensions the thing varies on:

  product only          image repository    rova-api
                        (NO environment — promotion is "the same image gets a
                        second tag", so a per-env repository would mean copying
                        bytes and the attestation would stop covering prod)
  product               namespace           rova        (the cluster IS the env)
  service               Deployment          api         (the namespace IS the product)
  env + product + name  Key Vault secret    rova-prod-db-app
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

{{/* Image reference. Deliberately NO env — see the header. */}}
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


{{/* Commit an image tag names, when it names one.

     The same generated values/<product>/tags.<env>.yaml that carries the tag is
     the only source: a dev build is tagged `sha-<commit>` (12 characters from the
     Kubernetes pipeline, 40 from the ECS one, per tags.dev.yaml's header), so the
     commit is the tag without its prefix. A release tag (`vX.Y.Z`) names no
     commit, and a digest pins bytes with no tag at all — both return empty, and
     APP_COMMIT / appCommit are simply absent rather than a lie. The API treats a
     missing APP_COMMIT as unknown (its own fallback), never as "dev".

     Returns "" or the hexadecimal commit, never the word "nil". */}}
{{- define "qnsc.appCommit" -}}
{{- $tag := . | default "" | toString -}}
{{- if or (regexMatch "^sha-[0-9a-f]{12}$" $tag) (regexMatch "^sha-[0-9a-f]{40}$" $tag) -}}
{{- trimPrefix "sha-" $tag -}}
{{- end -}}
{{- end }}

{{/* The SPA's rendered runtime config (/srv/config.json).

     `web.config` is product-shaped and the chart renders it verbatim, with ONE
     chart-owned exception: appVersion/appCommit. They come from the web image's
     tag in the same generated tags file, so a promotion cannot leave the UI
     reporting the previous version — there is no second place for a human to
     update. Chart values WIN over a same-named key in web.config, deliberately:
     the image tag is the fact, and a copied version string drifts.

     appCommit is omitted for a release tag or a digest-only pin (see
     qnsc.appCommit). A product config that already carries one keeps it only
     when the tag names no commit — the chart does not delete keys it did not
     set. The web Deployment hashes THIS output into the pod template, so the
     ConfigMap and the rollout can never disagree about what config is running. */}}
{{- define "qnsc.webConfig" -}}
{{- $w := .Values.web | default dict -}}
{{- $config := deepCopy ($w.config | default dict) -}}
{{- $tag := dig "image" "tag" "" $w | toString -}}
{{- if $tag -}}
{{- $_ := set $config "appVersion" $tag -}}
{{- $commit := include "qnsc.appCommit" $tag -}}
{{- if $commit -}}
{{- $_ := set $config "appCommit" $commit -}}
{{- end -}}
{{- end -}}
{{- toJson $config -}}
{{- end }}


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
True when the product is configured with a Redis/Valkey URL (REDIS_URL or
VALKEY_URL), as a plain defaults.env entry or a secrets.env mapping.

allow-egress-data needs data.cache.instance to draw the 6379 rule. A product
with a cache URL but no instance would render a policy that silently blocks its
own cache (the chart 0.19.2 split), so the policy fails the render instead.
*/}}
{{- define "qnsc.redisConfigured" -}}
{{- $found := false -}}
{{- range .Values.defaults.env -}}
{{- if has .name (list "REDIS_URL" "VALKEY_URL") -}}{{- $found = true -}}{{- end -}}
{{- end -}}
{{- $senv := .Values.secrets.env | default dict -}}
{{- if or (hasKey $senv "REDIS_URL") (hasKey $senv "VALKEY_URL") -}}{{- $found = true -}}{{- end -}}
{{- if $found -}}true{{- end -}}
{{- end -}}

{{/*
The product's non-web workloads (api, worker, migrator, Jobs and CronJobs).

The optional SPA (`web`) is a static file server: it gets DNS from allow-dns and
nothing else. Every other egress allow — platform, the internet, the data
namespace, networkPolicy.egressNamespaces — selects this instead of every pod in
the namespace, so a compromised web pod cannot reach Postgres, Valkey, clamd,
TEI or the internet. `NotIn [web]` rather than an explicit api/worker/migrator
list, so a future Job or CronJob is covered without another chart change.
*/}}
{{- define "qnsc.nonWebPodSelector" -}}
matchExpressions:
  - { key: app.kubernetes.io/name, operator: NotIn, values: [web] }
{{- end -}}

{{/*
The port a POD listens on — the Service `targetPort`.

kube-proxy DNATs Service traffic to the pod BEFORE a NetworkPolicy is evaluated,
so a policy `port` matches the pod's container port, never the Service `port`.
The kubelet probes the pod directly, so probes use the same number.

`services.<name>.port` is the Service port and the default pod port;
`services.<name>.targetPort` overrides the pod port (an image that listens on a
fixed port behind a differently numbered Service).
*/}}
{{- define "qnsc.podPort" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- $svc := index $root.Values.services $name -}}
{{- if not $svc -}}
{{- fail (printf "no service named %q in values.services" $name) -}}
{{- end -}}
{{- $port := required (printf "service %q: `port` is required (NetworkPolicies name the pod port)" $name) $svc.port -}}
{{- $svc.targetPort | default $port -}}
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
ServiceAccounts (new UID -> bound tokens invalidated) and the shared
<product>-db-ca (its Secret is mounted by running Deployments). The chart renders
no SecretStore: every ExternalSecret reads the platform's ClusterSecretStore.
*/}}
{{- define "qnsc.presyncPrereq" -}}
argocd.argoproj.io/hook: PreSync
argocd.argoproj.io/sync-wave: "-1"
argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
{{- end }}

{{/*
Every ExternalSecret reads the platform-owned ClusterSecretStore (kv-qnsc-<env>); the chart renders no
SecretStore of its own. `secrets.clusterSecretStore` is required (the schema says so too).
*/}}
{{- define "qnsc.storeRef" -}}
name: {{ required "secrets.clusterSecretStore is required (the platform ClusterSecretStore, e.g. kv-qnsc-dev)" (.Values.secrets).clusterSecretStore }}
kind: ClusterSecretStore
{{- end }}

{{/* Remote key per role (ONPREM-PLAN §6.3, §7.1). "app" -> secrets.bundle
     (<product>-<env>-app, a JSON bundle). The DB roles are one PLAIN-STRING password
     each, so a CNPG managed role and the app that logs in as it read the same value:
       "db"       -> secrets.db         (<product>-<env>-db-app,      api + default worker)
       "dbWorker" -> secrets.dbWorker   (<product>-<env>-db-worker,   optional)
       "migrator" -> secrets.dbMigrator (<product>-<env>-db-migrator, the PreSync Job only) */}}
{{- define "qnsc.remoteKey" -}}
{{- $root := index . 0 -}}{{- $role := index . 1 -}}
{{- $sec := $root.Values.secrets | default dict -}}
{{- $p := include "qnsc.product" $root -}}{{- $e := include "qnsc.env" $root -}}
{{- if eq $role "app" -}}
{{- $sec.bundle | default (printf "%s-%s-app" $p $e) -}}
{{- else if eq $role "migrator" -}}
{{- $sec.dbMigrator | default (printf "%s-%s-db-migrator" $p $e) -}}
{{- else if eq $role "dbWorker" -}}
{{- $sec.dbWorker | default (printf "%s-%s-db-worker" $p $e) -}}
{{- else -}}
{{- $sec.db | default (printf "%s-%s-db-app" $p $e) -}}
{{- end -}}
{{- end }}

{{/*
PER-VALUE APP SECRETS (chart 0.14.0). `secrets.env` and `secrets.envApiOnly` are maps
ENV_VAR_NAME: <Key Vault secret name>, one Key Vault secret per VALUE (the JSON `secrets.bundle`
is deprecated). Returns "true" when either map is non-empty, and fails the render on the
combinations that cannot work:
  - secrets.bundle set at the same time: a bundle's keys are opaque to the chart, so it cannot tell
    whether the two overlap; a product uses ONE mechanism
  - the same variable in secrets.env and secrets.envApiOnly
*/}}
{{- define "qnsc.perValueEnv" -}}
{{- $sec := .Values.secrets | default dict -}}
{{- $env := $sec.env | default dict -}}
{{- $api := $sec.envApiOnly | default dict -}}
{{- if or $env $api -}}
{{- if $sec.bundle -}}{{- fail "secrets.bundle is deprecated and cannot be combined with secrets.env / secrets.envApiOnly: move every key of the bundle to secrets.env (one Key Vault secret per value) and remove secrets.bundle" -}}{{- end -}}
{{- range $k, $_ := $api -}}{{- if hasKey $env $k -}}{{- fail (printf "%s is set in both secrets.env and secrets.envApiOnly" $k) -}}{{- end -}}{{- end -}}
true
{{- end -}}
{{- end }}
