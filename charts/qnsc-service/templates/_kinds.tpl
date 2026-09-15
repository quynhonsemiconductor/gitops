{{/*
────────────────────────────────────────────────────────────────────────────────
THE KIND CAPABILITY TABLE

This is the most important file in the chart. Every template asks it what a kind
needs instead of testing the kind itself.

The rule: NO TEMPLATE MAY CONTAIN `if eq $svc.kind "http"`. If you find yourself
writing one, the table is missing a column — add the column.

That rule is what keeps a new kind cheap. Adding `batch` should be one row here
plus, at most, one new template file. It should never mean auditing every
existing template for a condition that needs a new branch.

Columns
  workload   Deployment | Job | CronJob        which controller renders
  service    none | ClusterIP | Headless       Headless is required for gRPC:
                                               a normal Service load-balances per
                                               CONNECTION, so one client pins to
                                               one pod forever (design §4d)
  route      none | HTTPRoute | GRPCRoute      only rendered when exposed
  scalable   true | false                      whether a KEDA ScaledObject renders
  pdb        never | bySize | always           `always` means every size, XS
                                               included — long-lived connections
                                               die on an unguarded drain (§4e)
  capacity   default node capacity for the kind, overridable per service
────────────────────────────────────────────────────────────────────────────────
*/}}
{{- define "qnsc.kinds" -}}
http:
  workload: Deployment
  service: ClusterIP
  route: HTTPRoute
  scalable: true
  pdb: bySize
  capacity: mixed
grpc:
  workload: Deployment
  service: Headless
  route: GRPCRoute
  scalable: true
  pdb: bySize
  capacity: mixed
realtime:
  workload: Deployment
  service: ClusterIP
  route: HTTPRoute
  scalable: true
  pdb: always
  capacity: ondemand
worker:
  workload: Deployment
  service: none
  route: none
  scalable: true
  pdb: bySize
  capacity: spot
job:
  workload: Job
  service: none
  route: none
  scalable: false
  pdb: never
  capacity: spot
cron:
  workload: CronJob
  service: none
  route: none
  scalable: false
  pdb: never
  capacity: spot
{{- end -}}


{{/*
Capabilities of one kind. Fails loudly on an unknown kind rather than rendering
nothing — a silently absent Deployment is the worst possible failure mode here.

  {{- $caps := include "qnsc.caps" $svc.kind | fromYaml }}
*/}}
{{- define "qnsc.caps" -}}
{{- $table := include "qnsc.kinds" . | fromYaml -}}
{{- $caps := index $table . -}}
{{- if not $caps -}}
{{- fail (printf "unknown service kind %q — valid kinds: %s" . (keys $table | sortAlpha | join ", ")) -}}
{{- end -}}
{{- toYaml $caps -}}
{{- end -}}
