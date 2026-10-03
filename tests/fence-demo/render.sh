#!/usr/bin/env bash
# Prints three one-off Operations for `./demo.sh fence`. Each runs a canned
# "fake-ai" step (a stand-in for a misbehaving model) followed by the exact
# fence step remediate-caches uses. Usage: render.sh BUILD_DIR
set -euo pipefail
BUILD="$1"
python3 - "${BUILD}/remediate-caches.yaml" <<'PY'
import json, subprocess, sys

fence_step = json.loads(subprocess.check_output(
    ["yq", "-o", "json", ".spec.operationTemplate.spec.pipeline[] | select(.step == \"fence\")", sys.argv[1]]))
# A plain Operation has no watched resource; require it explicitly, the way a
# WatchOperation injects it.
fence_step["requirements"]["requiredResources"].insert(0, {
    "requirementName": "ops.crossplane.io/watched-resource",
    "apiVersion": "cache.demo.example.org/v1alpha1", "kind": "Cache",
    "name": "demo-rogue", "namespace": "qa"})

def cache(**params):
    return {"apiVersion": "cache.demo.example.org/v1alpha1", "kind": "Cache",
            "metadata": {"name": "demo-rogue", "namespace": "qa"},
            "spec": {"parameters": params}}

proposals = {
    "sku": [cache(ardId="ARD-001", sku="xl")],
    "registry": [cache(ardId="ARD-999")],
    "hostile": [cache(ardId="ARD-001"),
                {"apiVersion": "v1", "kind": "Secret",
                 "metadata": {"name": "gpt", "namespace": "crossplane-system"},
                 "stringData": {"OPENAI_BASE_URL": "http://attacker.example:11434/v1"}}],
}

items = []
for name, objs in proposals.items():
    script = "\n".join([
        "from crossplane.function import resource",
        f"PROPOSALS = {objs!r}",
        "def operate(req, rsp):",
        "    for i, p in enumerate(PROPOSALS):",
        "        resource.update(rsp.desired.resources[f'ai-{i}'], p)",
    ])
    items.append({
        "apiVersion": "ops.crossplane.io/v1alpha1", "kind": "Operation",
        "metadata": {"name": f"fence-demo-{name}"},
        "spec": {"mode": "Pipeline", "retryLimit": 1, "pipeline": [
            {"step": "fake-ai", "functionRef": {"name": "function-python"},
             "input": {"apiVersion": "python.fn.crossplane.io/v1beta1", "kind": "Script", "script": script}},
            fence_step,
        ]},
    })
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
PY
