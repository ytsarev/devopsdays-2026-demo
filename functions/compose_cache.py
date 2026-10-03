"""Composition logic for Cache: resolve the ResourceGroup, then compose a local Valkey.

Runs inside function-python. demo.sh injects this file into the Composition.
"""

from crossplane.function import request, resource, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

# Declared as a step requirement in the Composition: every ResourceGroup.
GROUPS = "resource-groups"

VALKEY_IMAGE = "valkey/valkey:9.1.2-alpine"
MAXMEMORY = {"xs": "16mb", "s": "64mb", "m": "128mb", "l": "256mb", "xl": "512mb"}


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    xr = resource.struct_to_dict(req.observed.composite.resource)
    name = xr["metadata"]["name"]
    namespace = xr["metadata"]["namespace"]
    params = xr["spec"]["parameters"]
    ard_id = params["ardId"]

    groups = request.get_required_resources(req, GROUPS)
    known = sorted(
        (
            {"ardId": g["spec"]["ardId"], "owner": g["spec"]["owner"], "region": g["spec"]["region"]}
            for g in groups
        ),
        key=lambda g: g["ardId"],
    )
    match = next((g for g in known if g["ardId"] == ard_id), None)

    status = {"resourceGroup": {"ardId": ard_id, "found": match is not None, "known": known}}

    if match is None:
        # Nothing to place the cache in. Compose nothing, say why, and stay not
        # Ready: with zero composed resources Crossplane would otherwise report
        # the XR as Ready.
        msg = f"No ResourceGroup matches ardId {ard_id}"
        rsp.desired.composite.ready = fnv1.READY_FALSE
        response.set_conditions(
            rsp,
            resource.Condition(
                typ="ResourceGroupResolved",
                status="False",
                reason="NotFound",
                message=f"{msg}. Known: {', '.join(g['ardId'] for g in known) or 'none'}",
            ),
        )
        response.warning(rsp, msg)
        rsp.results[-1].reason = "ResourceGroupNotFound"
        resource.update(rsp.desired.composite, {"status": status})
        return

    response.set_conditions(
        rsp,
        resource.Condition(
            typ="ResourceGroupResolved",
            status="True",
            reason="Found",
            message=f"Placed in {ard_id} (owner {match['owner']}, region {match['region']})",
        ),
    )

    labels = {
        "app.kubernetes.io/name": "valkey",
        "app.kubernetes.io/instance": name,
        "cache.demo.example.org/ard-id": ard_id,
    }

    desired = {
        "config": {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": f"{name}-config", "namespace": namespace, "labels": labels},
            "data": {
                "valkey.conf": "\n".join(
                    [
                        f"maxmemory {MAXMEMORY[params['sku']]}",
                        "maxmemory-policy allkeys-lru",
                        'save ""',
                        "appendonly no",
                        "",
                    ]
                )
            },
        },
        "deployment": {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {"name": f"{name}-valkey", "namespace": namespace, "labels": labels},
            "spec": {
                "replicas": 1,
                "selector": {"matchLabels": {"app.kubernetes.io/instance": name}},
                "template": {
                    "metadata": {"labels": labels},
                    "spec": {
                        "containers": [
                            {
                                "name": "valkey",
                                "image": VALKEY_IMAGE,
                                # Preloaded into kind by demo.sh up: no pulls on stage.
                                "imagePullPolicy": "IfNotPresent",
                                "args": ["/etc/valkey/valkey.conf"],
                                "ports": [{"name": "valkey", "containerPort": 6379}],
                                "readinessProbe": {
                                    "exec": {"command": ["valkey-cli", "ping"]},
                                    "periodSeconds": 1,
                                },
                                "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}},
                                "volumeMounts": [{"name": "config", "mountPath": "/etc/valkey"}],
                            }
                        ],
                        "volumes": [{"name": "config", "configMap": {"name": f"{name}-config"}}],
                    },
                },
            },
        },
        "service": {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {"name": f"{name}-valkey", "namespace": namespace, "labels": labels},
            "spec": {
                "selector": {"app.kubernetes.io/instance": name},
                "ports": [{"name": "valkey", "port": 6379, "targetPort": "valkey"}],
            },
        },
    }

    for key, body in desired.items():
        resource.update(rsp.desired.resources[key], body)
        if is_ready(key, req.observed.resources):
            rsp.desired.resources[key].ready = fnv1.READY_TRUE

    status["endpoint"] = f"{name}-valkey.{namespace}.svc:6379"
    resource.update(rsp.desired.composite, {"status": status})


def is_ready(key: str, observed) -> bool:
    """ConfigMaps and Services are ready once they exist; Deployments once available."""
    if key not in observed:
        return False
    if key != "deployment":
        return True
    obs = resource.struct_to_dict(observed[key].resource)
    return int(obs.get("status", {}).get("availableReplicas", 0)) >= 1
