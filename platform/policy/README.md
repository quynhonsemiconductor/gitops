# platform/policy

ValidatingAdmissionPolicies and their bindings (ONPREM-PLAN §10, no policy engine).

## Testing

`scripts/test-policy.sh <context>` runs allow/deny cases (`--dry-run=server`) against a real API
server and checks that every ExternalSecret the chart renders for an enabled product row is still
admitted. CI runs it as `policy-test`. Locally:

```bash
k3d cluster create policytest --no-lb --wait
helm template eso external-secrets --repo https://charts.external-secrets.io --version 2.11.0 \
  --set installCRDs=true --include-crds | python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "CustomResourceDefinition"
        and d["metadata"]["name"] == "externalsecrets.external-secrets.io"]
yaml.safe_dump_all(docs, sys.stdout)' | kubectl --context k3d-policytest apply --server-side -f -
scripts/test-policy.sh k3d-policytest
k3d cluster delete policytest
```
