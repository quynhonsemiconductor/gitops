# qnsc-service

One chart per product (api, worker, migrator, optional web). Values live in
`gitops/values/<product>/`; ArgoCD deep-merges `base.yaml`, `<env>.yaml` and
`tags.<env>.yaml` before Helm sees them.

## Optional `web` component

`web.enabled: true` renders a static-file server for an SPA:

- Deployment (replicas `web.replicas`, default 1), Service on `web.port` (8080),
  ConfigMap `<product>-web-config`, PDB only when `web.pdb: true`
- both probes `GET /healthz`
- pod/container securityContext: restricted (non-root uid 1001, read-only root
  filesystem, all capabilities dropped, RuntimeDefault seccomp)
- `web.config` is rendered as JSON and mounted at `/srv/config.json` through
  `subPath`. The chart adds two keys of its own from the web image tag —
  `appVersion`, and `appCommit` when the tag is `sha-<commit>` — so the UI
  reports the build it was served from without a hand-copied version string.
  A pod annotation `checksum/config` hashes the rendered config, so changing the
  config or the image tag rolls the pod — a subPath mount never updates in place.
- every service container also gets `APP_VERSION` (the image tag) and, for a
  `sha-<commit>` tag, `APP_COMMIT`. A release tag (`vX.Y.Z`) and a digest-only
  pin carry no commit, so `APP_COMMIT` is absent rather than guessed.
- the image repo/tag/digest follows the other services: repo in `base.yaml`,
  tag/digest in `tags.<env>.yaml`.

### Image contract

The image must work inside the pod the chart creates:

| | |
|---|---|
| filesystem | `readOnlyRootFilesystem: true`; **the only writable path is `/tmp`** (emptyDir). No other directory may be written or created. |
| port | 8080 (`web.port`), plain HTTP |
| doc root | `/srv` (`index.html` at the root; client-side routes fall back to it) |
| health | `GET /healthz` → 200 while serving |
| config | read `/srv/config.json` before bootstrapping; invalid/missing is a boot error |
| uid | any non-root uid; the chart pins 1001 |
| egress | DNS (`kube-system`, 53/UDP+TCP) only. The SPA is a static file server and makes no server-side calls (the Caddyfile has no `reverse_proxy`/`forward_auth`), so chart 0.19.2 dropped `WEB_API_UPSTREAM` and the `allow-egress-web` policy; every other egress allow is scoped to the product's non-web workloads. |

Default: disabled. Prod stays disabled until the edge/tunnel cutover.
