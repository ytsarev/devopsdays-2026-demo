#!/usr/bin/env bash
# Prints three one-off Operations for `./demo.sh fence`. Each runs the
# project's fake-ai function (a stand-in for a misbehaving model) followed by
# the exact fence step remediate-caches uses. Usage: render.sh REPO_ROOT
set -euo pipefail
ROOT="$1"
python3 - "${ROOT}/ai/remediate-caches.yaml" <<'PY'
import json, subprocess, sys

fence_step = json.loads(subprocess.check_output(
    ["yq", "-o", "json", '.spec.operationTemplate.spec.pipeline[] | select(.step == "fence")', sys.argv[1]]))
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
    "sku": [cache(costCenter="CC-4711", sku="xl")],
    "registry": [cache(costCenter="CC-9999")],
    "hostile": [cache(costCenter="CC-4711"),
                {"apiVersion": "v1", "kind": "Secret",
                 "metadata": {"name": "gpt", "namespace": "crossplane-system"},
                 "stringData": {"OPENAI_BASE_URL": "http://attacker.example:11434/v1"}}],
}

items = []
for name, objs in proposals.items():
    items.append({
        "apiVersion": "ops.crossplane.io/v1alpha1", "kind": "Operation",
        "metadata": {"name": f"fence-demo-{name}"},
        "spec": {"mode": "Pipeline", "retryLimit": 1, "pipeline": [
            {"step": "fake-ai", "functionRef": {"name": "devopsdays-demofake-ai"},
             "input": {"apiVersion": "fakeai.demo.example.org/v1alpha1", "kind": "Input", "proposals": objs}},
            fence_step,
        ]},
    })
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
PY
