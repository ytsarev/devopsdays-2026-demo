# On stage

Everything here runs from the repository root.

## Runbook

**Night before (needs network; about 10 minutes, mostly downloads):**

```sh
./demo.sh up            # tools, model, kind, Crossplane, functions, APIs, start state
./demo.sh rehearse 3    # three unattended full runs with timings
./demo.sh airplane on   # optional: cut the cluster off the internet...
./demo.sh rehearse 1    # ...and prove it still works
./demo.sh airplane off
```

Then turn Wi-Fi off and run `./demo.sh` once more. Leave colima and the cluster running, and don't run `down`. If the laptop restarts, run `./demo.sh status`; Crossplane's package cache is on a persistent volume, so it comes back without network.

**On stage:**

```sh
./demo.sh               # preflight checklist, offers a reset if needed, then ENTER through the beats
```

| Beat | What the audience sees |
|---|---|
| 1 · Stuck | `READY False`; `kubectl get cache -o yaml` with the spec and the conditions; the raw Warning event; `kubectl get costcenters` |
| 2 · Explain | the AI's diagnosis as an annotation in `kubectl get cache -o yaml`, next to the unchanged spec; the fence's verdict |
| 3 · Approve | `remediate-caches`' `spec.watch` selector, and `kubectl get caches -l allow-auto-remediation=true` finding nothing; then `kubectl label …`, the same query finding `demo-stuck`, and `remediate-caches` watching 1 Cache |
| 4 · Patch | the fence's approval; `kubectl get cache -o yaml` with the label, the `auto-remediated` annotation and `costCenter: CC-4711`; who wrote which fields (from `metadata.managedFields`) |
| 5 · Reconcile | `READY True`; `crossplane resource trace` (Cache → Deployment, ConfigMap, Service); `valkey-cli ping` → `PONG` |
| Off switch | the label removed; `kubectl get caches -l allow-auto-remediation=true` finds nothing |

- **Single beats:** each beat also runs on its own: `./demo.sh stuck|explain|approve|patch|reconcile|off`. `approve` runs beats 3 and 4.
- **YAML views:** the `kubectl get cache -o yaml` views are the real objects, trimmed with `yq` to the fields the beat is about; each one says what it shows. Long values are wrapped as folded YAML so they stay readable at a large font.
- **Flags:** `--notes` prints your speaker lines on screen, and `--auto SECS` replaces ENTER with a sleep, for recordings.
- **Q&A:** `./demo.sh fence` shows the schema rejecting `CC-12`, then three bad proposals (a `sku` change, an unknown `CC-9999`, a rewrite of the model's Secret) rejected by the same fence code.

## Speaker lines, two per beat

1. **Stuck.** "A developer asked for a cache billed to cost center CC-4171. It's stuck: not Ready, and an event saying no cost center matches." / "No valid cost center, no infrastructure. The controller knows what is wrong. It has no idea what you meant, and it shouldn't guess."
2. **Explain.** "A WatchOperation hands this Cache to a model on this laptop. It may write one annotation, and plain Python enforces that, not the prompt." / "It reads the same objects I just read: CC-4171 doesn't exist, CC-4711 belongs to payments, like payments-api. It explained. Nothing changed."
3. **Approve.** "I agree with it. But I don't type the fix. I approve it, the Kubernetes way: one label." / "The remediation controller only watches Caches with that label. Without it, it can't even run."
4. **Patch.** "Now the AI may propose a change. The fence checks it: only costCenter, only to a cost center that exists, only with approval." / "Who wrote what: I wrote spec and label, the AI one field and its notes, the controller status. One Cache, three writers."
5. **Reconcile.** "From here it's boring on purpose: the composition finds the cost center, renders a real Valkey, the Cache goes Ready." / "AI thinks. A human approves. The controller reconciles."

## Timings

Measured on 3 October 2026 on a MacBook Pro (M4 Max, colima 4 CPU / 8 GB) with model `qwen3:30b-a3b-instruct-2507` (Q4_K_M). Three back-to-back unattended runs (`./demo.sh rehearse 3`), with the cluster cut off from the internet (`./demo.sh airplane on`):

| Run | Reset | Reset → diagnosis | Approve → patch | Reset → Ready |
|---|---|---|---|---|
| 1 | 2.2 s | 5.6 s | 4.4 s | 10.7 s |
| 2 | 2.3 s | 5.7 s | 4.4 s | 10.3 s |
| 3 | 1.7 s | 9.9 s | 4.9 s | 15.6 s |

- **Model calls:** each takes 3.5–5 s; the prompt is about 5,000 tokens (see [design.md](design.md)).
- **Calls per run:** two, one diagnosis and one remediation, and sometimes a third for the "healthy" re-diagnosis.
- **Ready:** follows the patch within about a second, because Valkey's image is preloaded.
- **`./demo.sh up`:** about 10 s on an existing setup; from nothing it's dominated by downloads (the model is 18.6 GB).
- **Smaller fallback model:** `./demo.sh model qwen3:4b-instruct-2507-q4_K_M` (2.5 GB) gives the same timings, but a vaguer diagnosis.
- **Log:** `.run/timings.log` collects every rehearsal.

## If a step hangs

Every wait has a spinner and a timeout. In the guided flow, a timed-out beat offers:

- `r` to retry: it re-triggers the WatchOperations with a `nudge` annotation and waits again.
- ENTER to carry on.
- `q` to quit.

Causes, most likely first:

| Symptom | Check | Fix |
|---|---|---|
| Explain or Patch spins past 30 s | `curl -s 127.0.0.1:11434/api/ps` (is the model loaded?) and `tail .run/ollama.log` | `./demo.sh reset` (restarts Ollama if needed and warms the model). On stage: switch to the recording. |
| Patch times out and shows "The fence rejected the proposal" | the message says why (for example, a model that picked a cost center not in the registry) | `kubectl label cache demo-stuck allow-auto-remediation-`, then `./demo.sh approve` again. This makes a good talking point too. |
| Nothing at all happens after the label | `kubectl get operations` and `kubectl get watchoperations` | `./demo.sh reset`, then rerun from `./demo.sh approve` |
| Preflight says "cluster cannot reach Ollama" | `docker exec devopsdays-control-plane curl -s 192.168.5.2:11434/api/version` | Ollama is down, or colima restarted with a new address: `./demo.sh reset`, or `./demo.sh up` (idempotent) |
| Anything else | `./demo.sh status` | `./demo.sh reset` (seconds); the last resort is the recording |

## Backup recording

`recording/demo.cast` is one clean guided run: 92×30, about a minute, recorded with `--auto 6`. Play it with `.tools/asciinema play recording/demo.cast` in a terminal at least 92 columns wide at your stage font. Space pauses and resumes, so you can talk over each beat.

The diagram is also available as [architecture.png](architecture.png) (2400×1400) for slides.
