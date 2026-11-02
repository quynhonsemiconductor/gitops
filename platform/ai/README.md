# platform/ai

The shared model services on the GPU agent node, ONPREM-PLAN §9.1.
Nothing here is rendered by the product chart: these are platform services with
their own Service names, not product releases (§11c does not apply).

```
apps/platform-ai.yaml          GPU plumbing — wave −3 (namespaces, PriorityClasses,
                               RuntimeClass nvidia, device plugin with time-slicing)
apps/platform-ai-tei.yaml      tei-e5 — wave 1
apps/platform-ai-rerank.yaml   tei-rerank — wave 1, replicas 0
```

## Contract for products

- `tei-e5.ai.svc:80` — `POST /embed` with `{"inputs": ["…"]}` → JSON array of
  vectors, 1024 dimensions, L2-normalised. `GET /health` is the readiness probe.
- The client sends the EXACT text to embed. TEI adds no instruction prefix,
  applies no task, and does not normalise text. KB's e5-instruct convention
  (`Instruct: …\nQuery: …` for queries, raw passages for documents) stays in KB.
- Model identity: `intfloat/multilingual-e5-large-instruct`
  revision `274baa43b0e13e37fafa6428dbc7938e62e5c439`, dtype **float32**,
  pooling **mean**. Changing any of these changes the vector space; the model
  name/revision/dimension/dtype are stored with the data (§9.1 rule 2).

## Request flow (first install)

```bash
# 1. GPU plumbing must be Healthy first (namespace ai, device plugin Ready).
kubectl -n kube-system get ds nvidia-device-plugin
kubectl get nodes -l qnsc.vn/pool=ai -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'  # expect 4

# 2. Seed the model cache once (Job is suspended until resumed).
kubectl -n ai patch job tei-e5-model-pull --type merge -p '{"spec":{"suspend":false}}'
kubectl -n ai wait --for=condition=complete job/tei-e5-model-pull --timeout=30m
kubectl -n ai patch job tei-e5-model-pull --type merge -p '{"spec":{"suspend":true}}'

# 3. tei-e5 starts offline from that cache.
kubectl -n ai get deploy tei-e5
# A debug pod must run in a namespace the egress policy admits (kb-dev), not
# in `ai` — the only `ai` pods allowed to call the Service carry the parity
# Job's label.
kubectl -n kb-dev run tei-probe --rm -it --restart=Never \
  --image=curlimages/curl:8.22.0 -- \
  curl -s http://tei-e5.ai.svc/embed -H 'content-type: application/json' \
  -d '{"inputs":["xin chào"]}' | head -c 200   # expect a JSON array of 1024 floats
```

## VRAM and memory budget

| Item | VRAM | Notes |
|---|---|---|
| `tei-e5` (fp32) | ~3.0 GB | 2.24 GB weights (560M × 4 B) + runtime/activations |
| `tei-rerank` (fp32) | ~2.8 GB | 2.3 GB weights; **replicas 0** until KB has a client |
| whisper (later) | ~2–3 GB | not built |
| one small LLM (later) | ~5–6 GB | not built; §9.1.1 trigger not met |

The plan's "e5 + reranker ≈ 2.5 GB" is the **FP16** figure. fp32 parity (see
below) doubles the weights: e5 + reranker together are ≈ 5.8 GB of the 16 GB,
still inside the card, and time-slicing gives no VRAM isolation — the budget is
enforced by pod sizing and monitoring, not by the device plugin. AI-node RAM: TEI
4 Gi + reranker 4 Gi of the node's 20 GB.

## Why fp32

KB's stored vectors are fp32 (ONNX fp32 export, ~2.3 GB). Its own gate rejected
int8 (cosine 0.972–0.987) and fp16-vs-fp32 is unproven, so serving fp32 is the
only dtype that does not require a re-embedding decision. Cost: weights double
versus the plan's FP16 estimate; documented above rather than hidden.

## Parity (the rule that decides re-embedding)

`tei-e5-parity.yaml` embeds a golden set through the Service and compares cosine
against reference vectors produced by **KB's own fp32 ONNX path**. Gate:
`≥ 0.999` per vector; the Job prints every cosine and fails otherwise.

TODO (reference vectors do not exist yet — Job is suspended and the reference
ConfigMap is intentionally absent):

```bash
# 1. Export the golden set from the cluster.
kubectl -n ai get configmap tei-e5-parity-golden -o jsonpath='{.data.golden\.json}' > golden.json

# 2. Produce reference.json with KB's ONNX path (same repo, same export the image bakes).
cd qnsc-kb-backend
poetry install --with onnx
EMBEDDING_MODEL=intfloat/multilingual-e5-large-instruct \
EMBEDDING_RUNTIME=onnx \
EMBEDDING_ONNX_DIR=/path/to/onnx-fp32 \
EMBEDDING_ONNX_POOLING=mean \
EMBEDDING_DIMENSION=1024 \
EMBEDDING_MAX_TOKENS=512 \
poetry run python - <<'PY'
import json, pathlib
from src.lib.embeddings import get_bge_embeddings
golden = json.loads(pathlib.Path("golden.json").read_text())
vectors = get_bge_embeddings([g["text"] for g in golden])
pathlib.Path("reference.json").write_text(json.dumps({
    "model": "intfloat/multilingual-e5-large-instruct",
    "revision": "274baa43b0e13e37fafa6428dbc7938e62e5c439",
    "dtype": "float32",
    "dimension": 1024,
    "vectors": {g["id"]: v for g, v in zip(golden, vectors)},
}))
PY

# 3. Install the reference and run the gate.
kubectl create configmap tei-e5-parity-reference -n ai --from-file=reference.json
kubectl -n ai patch job tei-e5-parity --type merge -p '{"spec":{"suspend":false}}'
kubectl -n ai logs -f job/tei-e5-parity
```

`get_bge_embeddings` is the RETRIEVAL_DOCUMENT path, so the golden entries are
embedded as passages; the `q-` entries already carry the query instruction
prefix in their text, which is exactly what KB will send to TEI.

## CPU fallback (phase A)

`tei-e5-cpu` is replicas 0, pinned off the AI pool, with its own cache PVC. To
switch: `kubectl -n ai scale deploy/tei-e5 --replicas=0` and
`scale deploy/tei-e5-cpu --replicas=1` — same Service, same DNS, no client
change. Seed `tei-e5-cpu-model-pull` the same way as the GPU job. Exactly ONE
variant may be up: the Service selects on the app name only.

## Egress

- `tei-e5`, `tei-e5-cpu`: NetworkPolicy egress = DNS only, and `HF_HUB_OFFLINE=1`.
  The model comes from the PVC.
- `tei-e5-model-pull`: DNS + TCP 443 anywhere, only while an operator resumes
  it. A NetworkPolicy cannot name `huggingface.co`; scoping the allowlist to a
  suspended Job is narrower than a permanent 443 rule on the service.
- `tei-e5-parity`: DNS + the Service only.

## Not here (deliberately)

LLM gateway (§9.1.1 trigger not met), vLLM/local LLM, whisper, the OCR service
(PaddleOCR has an open sm_120 detection bug).
