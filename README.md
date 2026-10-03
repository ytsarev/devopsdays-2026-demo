# Let AI Think. Let Controllers Reconcile.

Demo for the DevOpsDays Prague 2026 keynote (Monday 5 October, 09:20). It runs fully locally: a kind cluster, open-source Crossplane v2.4.2, and a local model served by Ollama on this Mac. It needs no cloud provider, no Upbound account and no internet during the demo.

The AI diagnoses, a human grants consent with a label, the AI patches desired state, and a controller converges. The AI never talks to infrastructure; it only reads and writes API objects, through a deterministic fence.

## Runbook

**Night before (needs network, about 10 minutes, mostly downloads):**

```sh
./demo.sh up            # tools, model, kind, Crossplane, functions, APIs, start state
./demo.sh rehearse 3    # three unattended full runs with timings
./demo.sh airplane on   # optional: cut the cluster off the internet...
./demo.sh rehearse 1    # ...and prove it still works
./demo.sh airplane off
```

Then turn Wi-Fi off and run `./demo.sh` once more. Leave colima and the cluster running and don't run `down`. If the laptop restarts, run `./demo.sh status`; Crossplane's package cache is on a persistent volume, so it comes back without network.

**On stage:**

```sh
./demo.sh               # preflight checklist, offers a reset if needed, then ENTER through the beats
```

| Beat | What you see | What happens |
|---|---|---|
| 1 · Stuck | `READY False`, the condition, the raw Warning event, the resource groups | `demo-stuck` has `ardId: ARD-010`, a digit swap of `ARD-001`. The composition finds no ResourceGroup, composes nothing and keeps the Cache not Ready. |
| 2 · Explain | the AI's diagnosis, the fence verdict, unchanged spec | `diagnose-caches` (WatchOperation): gate → function-openai → fence. The fence lets only the diagnosis annotation through. |
| 3 · Consent | `kubectl label … allow-auto-remediation=true`; `remediate-caches` now watches 1 Cache | The gate is a label selector on the WatchOperation. |
| 4 · Patch | the fence's approval, `ardId ARD-010 → ARD-001`, who wrote which fields | `remediate-caches`: the AI proposes `ardId`; the fence checks consent, the diagnosis and the registry, then applies one field. The writers view is read from `metadata.managedFields`. |
| 5 · Reconcile | `READY True`, the conditions, `valkey-cli ping` → `PONG` | The composition resolves ARD-001 and renders ConfigMap + Deployment + Service (a real Valkey; the image is preloaded). |
| Off switch | label removed; `get caches -l allow-auto-remediation=true` finds nothing | Revoking consent is one label. |

Each beat also runs on its own: `./demo.sh stuck|explain|consent|patch|reconcile|off`. `consent` runs beats 3 and 4. For Q&A, `./demo.sh fence` shows the schema rejecting `ARD-1`, then three bad proposals (a `sku` change, an unknown `ARD-999`, a rewrite of the model's Secret) rejected by the same fence code.

Flags: `--notes` prints your speaker lines on screen, and `--auto SECS` replaces ENTER with a sleep, for recordings.

### Your lines, two per beat

1. **Stuck.** "A developer asked for a cache. It's stuck: Synced, not Ready, and an event saying no ResourceGroup matches ARD-010." / "The controller knows exactly what is wrong. It has no idea what you meant, and it shouldn't guess."
2. **Explain.** "A WatchOperation hands this Cache to a model on this laptop. It may write one annotation, and plain Python enforces that, not the prompt." / "It reads the same objects I just read: probably a digit swap, ARD-001 belongs to payments. It explained. Nothing changed."
3. **Consent.** "I agree with it. But I don't type the fix. I grant consent, the Kubernetes way: one label." / "The remediation controller only watches Caches with that label. Without it, it can't even run."
4. **Patch.** "Now the AI may propose a change. The fence checks it: only ardId, only to a group that exists, only with consent." / "Who wrote what: I wrote spec and label, the AI one field and its notes, the controller status. One Cache, three writers."
5. **Reconcile.** "From here it's boring on purpose: the composition finds the group, renders a real Valkey, the Cache goes Ready." / "AI thinks. A human consents. The controller reconciles."

## Timings

Measured on 3 October 2026 on this MacBook Pro (M4 Max, colima 4 CPU / 8 GB), model `qwen3:30b-a3b-instruct-2507` (Q4_K_M), three back-to-back unattended runs (`./demo.sh rehearse 3`) with the cluster cut off from the internet (`./demo.sh airplane on`):

| Run | Reset | Reset → diagnosis | Consent → patch | Reset → Ready |
|---|---|---|---|---|
| 1 | 2.3 s | 6.7 s | 4.4 s | 11.9 s |
| 2 | 2.3 s | 8.9 s | 4.9 s | 14.0 s |
| 3 | 2.9 s | 6.8 s | 4.4 s | 11.3 s |

- Each model call takes 3.5–5 s; the prompt is about 5,000 tokens (see the limitations below).
- Each run makes exactly two model calls: one diagnosis and one remediation.
- Ready follows the patch within about a second (Valkey's image is preloaded).
- `./demo.sh up` on an existing setup takes about 10 s; from nothing it is dominated by downloads (the model is 18.6 GB).
- With the smaller fallback model (`./demo.sh model qwen3:4b-instruct-2507-q4_K_M`, 2.5 GB) the timings are the same, but the diagnosis is vaguer.
- `.run/timings.log` collects every rehearsal.

## If a step hangs

Every wait has a spinner and a timeout. In the guided flow, a timed-out beat asks `r` (retry: re-triggers the WatchOperations with a `nudge` annotation and waits again), ENTER (carry on) or `q` (quit). In order of likelihood:

| Symptom | Check | Fix |
|---|---|---|
| Explain or Patch spins past 30 s | `curl -s 127.0.0.1:11434/api/ps` (is the model loaded?) and `tail .run/ollama.log` | `./demo.sh reset` (restarts Ollama if needed and warms the model). On stage: switch to the recording. |
| Patch times out and shows "The fence rejected the proposal" | the message says why (for example a model that picked a group not in the registry) | `kubectl label cache demo-stuck allow-auto-remediation-`, then `./demo.sh consent` again. This makes a good talking point too. |
| Nothing at all happens after the label | `kubectl get operations` and `kubectl get watchoperations` | `./demo.sh reset`, then rerun from `./demo.sh consent` |
| Preflight says "cluster cannot reach Ollama" | `docker exec devopsdays-control-plane curl -s 192.168.5.2:11434/api/version` | Ollama is down or colima restarted with a new address: `./demo.sh reset`, or `./demo.sh up` (idempotent) |
| Anything else | `./demo.sh status` | `./demo.sh reset` (seconds); the last resort is the recording |

The backup recording is `recording/demo.cast` (one clean guided run, 92×30, about a minute, recorded with `--auto 6`). Play it with `.tools/asciinema play recording/demo.cast` in a terminal at least 92 columns wide at your stage font. Space pauses and resumes, so you can talk over each beat.

## How it works

```
 human ── kubectl label ──────────────┐
                                      ▼
 ┌──────────────────────── Cache (cache.demo.example.org/v1alpha1) ─────────────────────────┐
 │ spec.parameters.ardId  ◄── schema: ^ARD-[0-9]{3}$                                        │
 │ metadata.labels        ◄── human: allow-auto-remediation=true                            │
 │ metadata.annotations   ◄── AI via fence: diagnosis / auto-remediated                     │
 │ status                 ◄── controller: conditions, resourceGroup.known, endpoint         │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
       │ watched by                                  │ composed by
       ▼                                             ▼
 WatchOperation diagnose-caches (Forbid)        Composition cache (function-python)
 WatchOperation remediate-caches (Forbid,         ResourceGroup found? → ConfigMap +
   matchLabels allow-auto-remediation=true)        Valkey Deployment + Service : Ready
   1 gate      function-python  (ask the model?)   not found → nothing, Ready=False,
   2 think     function-openai → Ollama on Mac      condition + Warning event
   3 fence     function-python  (allowlist, registry, consent, dedupe) → server-side apply
   (1 = gate: function-python decides whether the model needs to be asked at all)
```

- **The model runs on the Mac, not in the cluster.** Ollama is bound to `127.0.0.1:11434` (so it isn't reachable from the venue network) and runs on the Mac's GPU. The kind node reaches the Mac's loopback through colima at `192.168.5.2`, and the in-cluster Service `llm/ollama` points there. `llm/Modelfile` sets the base model plus output-length and context limits, because function-openai sends neither.
- **The fence** (`functions/fence.py`) throws away whatever the AI step produced and rebuilds a minimal server-side-apply patch from an allowlist:
  - **diagnose** may set the diagnosis annotation only.
  - **remediate** may set `spec.parameters.ardId` only, to an ID that exists in the registry, with the consent label present on the live object and a diagnosis already recorded.
  - Anything else (another field, another resource, a different Cache) rejects the whole proposal, with a Warning event on the Cache.
  - The fence owns timestamps and de-duplication, and never fails the Operation: a failed Operation is retried and, under `Forbid`, blocks new runs.
- **The gate** (`functions/fence.py`, first step) decides whether the model needs to be asked at all. A WatchOperation starts an Operation on every change to the Cache, including Crossplane's own bookkeeping writes, about ten of them while a Cache converges. The model is called only for a settled state that hasn't been explained yet, or for a remediation that has consent, a recorded diagnosis and something to fix.
  - Crossplane 2.4 has no "nothing to do" result, so a gate that says no ends the run with a fatal result. Those Operations show as Failed ("failure limit of 1 reached"); nothing is applied and the model is not called.
  - "State" means `ardId/sku/ResourceGroupResolved/Ready`, not the resourceVersion.
- **Staleness.** Crossplane fetches the watched resource separately for each pipeline step, so the fence can see a newer Cache than the model saw. The gate records the state the model is about to see in the pipeline context, and the diagnose fence drops text about a state that has since changed.
- **One model call at a time.** Both WatchOperations use `concurrencyPolicy: Forbid`. With `Replace`, superseded Operations are deleted but their model calls keep running, and in testing bursts of them queued for up to a minute. With `Forbid`, a change that arrives while a run is active is dropped, not queued. The flow doesn't depend on such changes, but the "healthy" re-diagnosis after the fix can be missed; the old diagnosis then stays, stamped (`diagnosed-state`) with the state it describes. The retry option in the guided flow re-triggers by adding a `nudge` annotation.
- **`reset` waits for the Cache to go quiet** (no change for 2 s) before re-applying the WatchOperations, so the first diagnosis isn't competing with Crossplane's bookkeeping writes.
- **RBAC.** Crossplane already has access to ConfigMaps, Deployments, Services, Events and the XRs it defines. The only addition is `registry/rbac.yaml` (read and watch ResourceGroups), aggregated into Crossplane's role. Both WatchOperations act as Crossplane's service account, so RBAC can't tell them apart: the per-operation scope comes from the fence and the schema.

## Limitations of function-openai v0.3.10 (and how the demo handles them)

| Limitation | Handled by |
|---|---|
| Only the watched resource reaches the prompt; other required resources are ignored | The composition writes the known resource groups into `status.resourceGroup.known`, so the controller reports what it observed |
| `html/template` escapes the resource JSON (`"` becomes `&#34;`) | The prompt says so; the prompt text avoids `<`, `>` and `&`; the context is raised to 16k |
| An unparseable reply is silently "success, nothing applied" | The fence reports "no usable proposal" |
| No `max_tokens`, no timeout, no way to switch off thinking | `llm/Modelfile` limits output; the model must not think by default (qwen3.5 does, and burned 2048 tokens on thinking without answering) |
| The whole watched object goes into the prompt, `metadata.managedFields` included (57% of it) | About 5,000 tokens per call; the gate keeps calls to two per run |
| The model's output is applied to whatever object it names | The fence checks identity and rejects other objects |

The unreleased branch `fix-selfhosted-issues` of function-openai fixes most of these.

## Tests

```sh
./demo.sh test
```

- **Gate and fence unit tests** (`tests/fence/`, 36 tests, run in a Python 3.13 container with the same SDK as function-python):
  - good diagnosis and remediation patches, and a full-object echo
  - a diagnosis that also patches `ardId`
  - the AI granting itself consent
  - a `sku` change, an unknown `ardId`, a malformed `ardId`
  - a proposal touching a Secret, and one touching another Cache
  - no consent, no diagnosis yet, already fixed
  - a deleted Cache, empty model output
  - a fence bug (applies nothing, never fails the Operation)
  - stale snapshots
  - the gate: already diagnosed, converging, bookkeeping-only changes, no consent, no diagnosis, nothing to fix
- **Composition render tests** (`tests/composition/run.sh`, `crossplane composition render`): with and without a matching ResourceGroup.

## Layout

```
demo.sh                     everything: up, reset, beats, fence, test, rehearse, airplane, down
apis/cache/                 XRD (schema guardrail) and Composition (script injected at build)
functions/compose_cache.py  composition logic (function-python)
functions/fence.py          gate + fence (function-python, MODE appended at build)
operations/                 diagnose-caches and remediate-caches WatchOperations (prompts)
registry/                   ResourceGroup CRD, three groups, RBAC aggregated to Crossplane
llm/                        Modelfile, Ollama Service/EndpointSlice, function-openai Secret
crossplane/                 Helm values (--enable-operations, persistent package cache), functions
cluster/kind.yaml           pinned kind node image
tests/                      fence unit tests, composition render tests, Q&A fence-demo Operations
examples/demo-stuck.yaml    the stuck Cache
```

`.tools/` (kind, ollama, asciinema), `.models/` (model weights), `.run/` (logs, timings), `.build/` and `.kubeconfig` are generated and git-ignored. The demo uses its own kubeconfig and never changes your current kubectl context.

## Versions

Crossplane 2.4.2 (Helm chart `crossplane-stable/crossplane`), crossplane CLI 2.5.0, function-python v0.6.0, function-openai v0.3.10, kind v0.33.0 with node v1.36.4, Ollama v0.35.1, Valkey 9.1.2, asciinema 3.2.1.
