# How it works

![Architecture](architecture.svg)

## Pieces

The repository is a Crossplane project (`crossplane-project.yaml`). `crossplane project build` turns it into a Configuration package plus one Function package per embedded function, and `crossplane project run` installs it on a local kind cluster with its own OCI registry.

- **The Cache API.** `apis/cache/definition.yaml` defines `Cache` (`cache.demo.example.org/v1alpha1`). Its schema requires `costCenter` to match `^CC-[0-9]{4}$`.
- **The composition** (`apis/cache/composition.yaml`) runs the embedded Python function `functions/compose-cache`, which looks the cost center up in the CostCenter registry.
  - **Found:** it composes a ConfigMap, a Valkey Deployment and a Service.
  - **Not found:** it composes nothing, sets the `CostCenterResolved=False` condition, emits a Warning event, and explicitly keeps the Cache not Ready. With zero composed resources, Crossplane would otherwise report the Cache as Ready.
  - It writes the known cost centers into `status.costCenter.known`, so the model can see them.
- **Two WatchOperations** (`ai/`) run the pipeline `gate → think → fence`. They are applied by `demo.sh`, not packaged: `reset` deletes and re-creates them around the Cache, and Crossplane's package manager would put packaged ones back.
  - `diagnose-caches` watches every Cache in `default`.
  - `remediate-caches` watches only Caches labelled `allow-auto-remediation=true`.
- **The model runs on the Mac, not in the cluster.** Ollama is bound to `127.0.0.1:11434`, so it isn't reachable from the venue network, and runs on the Mac's GPU. The kind node reaches the Mac's loopback through colima at `192.168.5.2`, and the in-cluster Service `llm/ollama` points there. `llm/Modelfile` sets the base model plus output-length and context limits, because function-openai sends neither.

## The gate and the fence

Both are the embedded Python function `functions/fence`; each pipeline step picks the role in its input (`step: gate|fence`, `operation: diagnose|remediate`). The logic is in `functions/fence/function/fence.py`.

- **The fence** throws away whatever the AI step produced and rebuilds a minimal server-side-apply patch from an allowlist:
  - **diagnose** may set the diagnosis annotation only.
  - **remediate** may set `spec.parameters.costCenter` only. The code must exist in the registry, the approval label must be present on the live object, and a diagnosis must already be recorded.
  - Anything else (another field, another resource, a different Cache) rejects the whole proposal, with a Warning event on the Cache.
  - The fence owns timestamps and de-duplication. It never fails the Operation: a failed Operation is retried and, under `Forbid`, blocks new runs.
- **The gate** decides whether the model needs to be asked at all. A WatchOperation starts an Operation on every change to the Cache, including Crossplane's own bookkeeping writes, about ten of them while a Cache converges. The model is called only for a settled state that hasn't been explained yet, or for a remediation that is approved, has a recorded diagnosis and has something to fix.
  - Crossplane 2.4 has no "nothing to do" result, so a gate that says no ends the run with a fatal result. Those Operations show as Failed ("failure limit of 1 reached"); nothing is applied, and the model is not called.
  - "State" means `costCenter/sku/CostCenterResolved/Ready`, not the resourceVersion.
- **Staleness.** Crossplane fetches the watched resource separately for each pipeline step, so the fence can see a newer Cache than the model saw. The gate records the state the model is about to see in the pipeline context, and the diagnose fence drops text about a state that has since changed.
- **One model call at a time.** Both WatchOperations use `concurrencyPolicy: Forbid`.
  - With `Replace`, superseded Operations are deleted but their model calls keep running; in testing, bursts of them queued for up to a minute.
  - With `Forbid`, a change that arrives while a run is active is dropped, not queued. The flow doesn't depend on such changes, but the "healthy" re-diagnosis after the fix can be missed. The old diagnosis then stays, stamped (`diagnosed-state`) with the state it describes.
  - The retry option in the guided flow re-triggers by adding a `nudge` annotation.
- **`reset` waits for the Cache to go quiet** (no change for 2 s) before re-applying the WatchOperations, so the first diagnosis isn't competing with Crossplane's bookkeeping writes.
- **RBAC.** Crossplane already has access to ConfigMaps, Deployments, Services, Events and the XRs it defines. The only addition is `registry/rbac.yaml` (read and watch CostCenters), aggregated into Crossplane's role. Both WatchOperations act as Crossplane's service account, so RBAC can't tell them apart: the per-operation scope comes from the fence and the schema.

## Limitations of function-openai v0.3.10, and how the demo handles them

| Limitation | Handled by |
|---|---|
| Only the watched resource reaches the prompt; other required resources are ignored | The composition writes the known cost centers into `status.costCenter.known`, so the controller reports what it observed |
| `html/template` escapes the resource JSON (`"` becomes `&#34;`) | The prompt says so; the prompt text avoids `<`, `>` and `&`; the context is raised to 16k |
| An unparseable reply is silently "success, nothing applied" | The fence reports "no usable proposal" |
| No `max_tokens`, no timeout, no way to switch off thinking | `llm/Modelfile` limits output. The model must not think by default: qwen3.5 does, and burned 2048 tokens on thinking without answering |
| The whole watched object goes into the prompt, `metadata.managedFields` included (57% of it) | About 5,000 tokens per call; the gate keeps calls to two per run |
| The model's output is applied to whatever object it names | The fence checks identity and rejects other objects |

The unreleased branch `fix-selfhosted-issues` of function-openai fixes most of these.

## Tests

`./demo.sh test` runs both suites.

- **Gate and fence unit tests** (`tests/fence/`, 41 tests, run in a Python 3.13 container with the same SDK as the embedded functions):
  - good diagnosis and remediation patches, and a full-object echo
  - a diagnosis that also patches `costCenter`
  - the AI granting itself approval
  - a `sku` change, an unknown cost center, a malformed cost center
  - a proposal touching a Secret, and one touching another Cache
  - no approval, no diagnosis yet, already fixed
  - a deleted Cache, empty model output
  - a fence bug (applies nothing, never fails the Operation)
  - stale snapshots
  - the gate: already diagnosed, converging, bookkeeping-only changes, no approval, no diagnosis, nothing to fix
  - the function's input: gate, fence, and an unknown role (fatal, nothing applied)
- **Composition render tests** (`tests/composition/run.sh`, `crossplane composition render` against the compose-cache image from `crossplane project build`): with and without a matching CostCenter.

## Layout

```
crossplane-project.yaml     the project: repository, architectures, function-openai dependency
apis/cache/                 XRD (schema guardrail) and Composition
functions/compose-cache/    embedded Python function: the composition logic
functions/fence/            embedded Python function: the gate and the fence
functions/fake-ai/          embedded Python function: canned bad proposals for the Q&A demo
ai/                         diagnose-caches and remediate-caches WatchOperations (prompts), applied by demo.sh
registry/                   CostCenter CRD, three cost centers, RBAC aggregated to Crossplane
llm/                        Modelfile, Ollama Service/EndpointSlice, function-openai Secret
crossplane/                 Helm values that add Operations and a persistent package cache
tests/                      gate and fence unit tests, composition render tests, Q&A fence-demo Operations
examples/demo-stuck.yaml    the stuck Cache
demo.sh                     everything: up, reset, beats, fence, test, rehearse, airplane, build, down
docs/                       this page, the stage runbook, the architecture diagram
```

Generated and git-ignored: `.tools/` (ollama, asciinema), `.models/` (model weights), `.registry/` (the local OCI registry's data), `schemas/` and `_output/` (written by the CLI), `.run/` (logs, timings) and `.kubeconfig`.

## Crossplane CLI v2.5.0 project workflow: rough edges and workarounds

| What happens | Workaround in this repo |
|---|---|
| `crossplane project run` doesn't enable Operations (alpha in Crossplane 2.4) | `demo.sh up` adds `--enable-operations` and a persistent package cache with `helm upgrade --reuse-values`; later `project run` calls keep an existing install |
| `--crossplane-version v2.4.2` fails: the chart is cached as `crossplane-2.4.2.tgz` but looked up as `crossplane-v2.4.2.tgz` | pass `2.4.2` |
| `project run` merges its kubeconfig into `~/.kube/config` and switches the current context, ignoring `$KUBECONFIG` | `demo.sh` remembers your context and switches back, and keeps its own copy in `.kubeconfig` |
| Packages built for `arm64` only can't be installed: Crossplane fetches the `linux/amd64` entry of a package, even on an arm64 cluster | `spec.architectures: [amd64, arm64]`; the amd64 build is emulated (about 3 minutes for all three functions) |
| Embedded function names drop the underscore: `<repository>_<function>` becomes `devopsdays-democompose-cache` | the Composition and WatchOperations use those names |
| `function-openai:v0.3.10` exists on xpkg.upbound.io but is missing from its tag list, so `crossplane dependency add` can't resolve the version | the dependency is pinned by digest |
| `project run` rebuilds every function on every run (minutes, and needs the network for apt, PyPI and `gcr.io`) | `demo.sh up` skips it when nothing under `apis/`, `functions/` or `crossplane-project.yaml` changed |
| `crossplane composition render` in project mode rebuilds every embedded function and gives each Python build 60 s, which times out | `tests/composition/run.sh` builds once with `crossplane project build`, loads `_output/devopsdays.xpkg` into Docker, and renders against that image |

The WatchOperations stay outside the package on purpose. Packaged objects are owned by Crossplane's package manager, which re-applies them, and that would fight `reset`.

## Versions

Crossplane 2.4.2 (installed by `crossplane project run`), crossplane CLI 2.5.0, crossplane-function-sdk-python 0.15.1, function-openai v0.3.10 (pinned by digest), Ollama v0.35.1, Valkey 9.1.2, asciinema 3.2.1.
