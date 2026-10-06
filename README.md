# Let AI Think. Let Controllers Reconcile.

The demo from the DevOpsDays Prague 2026 keynote. An AI explains why a Kubernetes resource is stuck and proposes a fix, a human approves the fix with a label, and a Crossplane controller converges. The AI never touches infrastructure: it reads and writes one API object, and deterministic code decides what it may change.

Everything runs on a laptop. The repository is a [Crossplane project](https://blog.crossplane.io/introducing-the-new-crossplane-cli-developer-experience/): the Cache API plus embedded Python functions, which `crossplane project run` builds and installs on a local kind cluster. The model runs in Ollama on the same machine. No cloud account, and no internet during the demo.

![One Cache, three writers: you with kubectl, the AI only through a deterministic fence, and the Crossplane controller](docs/architecture.svg)

## Run it

You need macOS on Apple silicon, Docker (colima or Docker Desktop), `kubectl`, `helm`, `yq`, `jq` and the `crossplane` CLI v2.5 or later, plus about 25 GB of disk for the model.

```sh
./demo.sh up      # once, with network: the model, then `crossplane project run`
./demo.sh         # the guided demo: press ENTER to move through the beats
./demo.sh reset   # back to the start state, in seconds
./demo.sh down    # delete the cluster and stop Ollama
```

## What happens

| Beat | |
|---|---|
| 1 · Stuck | `demo-stuck` is billed to cost center `CC-4171`, which doesn't exist. No valid cost center, no infrastructure: the composition creates nothing and the Cache stays not Ready. |
| 2 · Explain | `diagnose-caches` asks the model what's wrong and writes the answer into an annotation. Nothing else changes. |
| 3 · Approve | `remediate-caches` only watches Caches labelled `allow-auto-remediation=true`. One `kubectl label` opens the gate. |
| 4 · Patch | The model proposes `costCenter: CC-4711`. The fence checks the label, the diagnosis and the registry, then applies that one field. |
| 5 · Reconcile | The composition finds the cost center and starts a real Valkey. The Cache goes Ready, and `valkey-cli ping` answers `PONG`. |

For Q&A, `./demo.sh fence` shows the API server rejecting a malformed cost center, and the fence rejecting three bad proposals: a `sku` change, an unknown cost center, and a rewrite of the model's Secret.

## Guardrails live in the API, not in the prompt

- **Schema:** `costCenter` must match `^CC-[0-9]{4}$`; the API server enforces it.
- **Selector:** `remediate-caches` only ever runs on Caches that carry the approval label.
- **Gate:** deterministic code decides whether the model is asked at all.
- **Fence:** deterministic code rebuilds every change from an allowlist. Diagnosis may write one annotation; remediation may change `spec.parameters.costCenter`, only to a cost center that exists, and only when approved.

## Tests

```sh
./demo.sh test    # gate and fence unit tests, composition render tests
./demo.sh build   # crossplane project build
```

## More

- [docs/stage.md](docs/stage.md): runbook, speaker lines, timings, and what to do if a step hangs
- [docs/design.md](docs/design.md): how it works, the function-openai limitations it works around, and the rough edges of the CLI's project workflow
