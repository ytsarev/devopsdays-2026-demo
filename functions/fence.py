"""Deterministic steps around the AI step: the gate before it, the fence after it.

Both WatchOperations run   gate -> think (function-openai) -> fence.

gate   decides whether the model needs to be asked at all. Crossplane 2.4 has no
       "nothing to do" result, so a gate that says no ends the run with a fatal
       result: the model is not called and nothing is applied. Without the
       gate every change to the Cache (status writes included) would cost a
       model call. It also records which state the model is about to see.
fence  throws away whatever the AI step produced and rebuilds the patch from an
       allowlist, or applies nothing. It never returns a fatal result.

demo.sh appends `MODE = "<mode>"` when it injects this file into a pipeline
step: gate-diagnose, gate-remediate, diagnose or remediate. Tests call gate()
and fence() directly.
"""

import datetime
import hashlib
import json
import re
import traceback

from crossplane.function import request, resource, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

GROUP = "cache.demo.example.org"
DIAGNOSIS = f"{GROUP}/diagnosis"
LAST_DIAGNOSED = f"{GROUP}/last-diagnosed"
DIAGNOSED_STATE = f"{GROUP}/diagnosed-state"
AUTO_REMEDIATED = f"{GROUP}/auto-remediated"
APPROVAL_LABEL = "allow-auto-remediation"

# Declared as a step requirement in the remediate Operation: every CostCenter.
COST_CENTERS = "cost-centers"

# The resourceVersion of the stand-in object a WatchOperation passes when the
# watched resource was deleted.
DELETED = "ops.crossplane.io/synthetic-deleted"

COST_CENTER = re.compile(r"^CC-[0-9]{4}$")
MAX_DIAGNOSIS = 360

# What each mode may change. Paths are tuples of keys.
ALLOWED = {
    "diagnose": {("metadata", "annotations", DIAGNOSIS)},
    "remediate": {("spec", "parameters", "costCenter")},
}

# Never counted as a proposed change and never forwarded: the API server, the
# controller or the fence itself own these.
IGNORED_PREFIXES = {
    ("status",),
    ("metadata", "uid"),
    ("metadata", "resourceVersion"),
    ("metadata", "generation"),
    ("metadata", "creationTimestamp"),
    ("metadata", "managedFields"),
    ("metadata", "annotations", LAST_DIAGNOSED),
    ("metadata", "annotations", DIAGNOSED_STATE),
    ("metadata", "annotations", AUTO_REMEDIATED),
}


SNAPSHOT = f"{GROUP}/snapshot"


def operate(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    if MODE.startswith("gate-"):  # noqa: F821 - MODE is appended by demo.sh
        gate(MODE.removeprefix("gate-"), req, rsp)  # noqa: F821
    else:
        fence(MODE, req, rsp)  # noqa: F821


def state(obj: dict) -> str:
    """What a diagnosis is about: the parameters and the controller's verdict.

    Not resourceVersion: Crossplane's own bookkeeping writes (finalizers,
    resourceRefs, the Responsive condition) change that without changing
    anything worth explaining.
    """
    p = obj.get("spec", {}).get("parameters", {})
    return f"{p.get('costCenter')}/{p.get('sku')}/{condition(obj, 'CostCenterResolved')}/{condition(obj, 'Ready')}"


def gate(mode: str, req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    """First step: is there anything new for the model? If not, stop here."""
    watched = request.get_watched_resource(req)
    codes = [c["spec"]["code"] for c in request.get_required_resources(req, COST_CENTERS)]
    reason = needless(mode, watched, codes)
    if reason:
        response.fatal(rsp, f"gate/{mode}: model not called: {reason}")
        return
    # Crossplane fetches the watched resource separately for every step, so the
    # fence may see a newer Cache than the model did. The pipeline context
    # carries what the model is about to see past the AI step to the fence.
    rsp.context[SNAPSHOT] = {"state": state(watched)}
    response.normal(rsp, f"gate/{mode}: asking the model about {state(watched)}")


def converging(obj: dict) -> str:
    """Why the controller hasn't settled yet, or "" if it has.

    While Crossplane converges (after a spec change, while Valkey starts) the
    Cache changes several times a second. A diagnosis of a moving target is
    stale before it lands, and each one costs a model call; wait for the next
    settled state instead, which arrives as a change of its own.
    """
    want = obj.get("spec", {}).get("parameters", {}).get("costCenter")
    seen = obj.get("status", {}).get("costCenter", {}).get("code")
    if seen is None:
        return "controller has not reported yet"
    if seen != want:
        return f"controller still converging (status is about {seen}, spec says {want})"
    if condition(obj, "CostCenterResolved") == "True" and condition(obj, "Ready") != "True":
        return "controller still converging (resources coming up)"
    return ""


def needless(mode: str, watched: dict | None, codes: list[str]) -> str:
    """Why the model need not be asked, or "" if it should be."""
    if watched is None:
        return "no watched resource"
    meta = watched.get("metadata", {})
    if meta.get("resourceVersion") == DELETED or meta.get("deletionTimestamp"):
        return "cache is being deleted"
    if mode == "diagnose":
        if annotations(watched).get(DIAGNOSED_STATE) == state(watched):
            return f"already diagnosed {state(watched)}"
        return converging(watched)
    if (meta.get("labels") or {}).get(APPROVAL_LABEL) != "true":
        return f"not approved: label {APPROVAL_LABEL}=true is not set"
    if not annotations(watched).get(DIAGNOSIS):
        return "no diagnosis yet: explain before acting"
    current = watched.get("spec", {}).get("parameters", {}).get("costCenter")
    if current in codes:
        return f"cost center {current} exists, nothing to fix"
    return ""


def fence(mode: str, req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse, now=None):
    """Replace the AI's proposal in rsp with what the fence allows, if anything."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    proposals = [resource.struct_to_dict(r.resource) for r in rsp.desired.resources.values()]
    # Nothing the AI step produced is applied unless the fence rebuilds it below.
    rsp.desired.resources.clear()

    try:
        watched = request.get_watched_resource(req)
        codes = [c["spec"]["code"] for c in request.get_required_resources(req, COST_CENTERS)]
        seen = resource.struct_to_dict(req.context).get(SNAPSHOT, {}).get("state")
        verdict = judge(mode, watched, proposals, codes, now, seen)
    except Exception as e:  # noqa: BLE001 - a bug in the fence must not apply anything
        verdict = Verdict("reject", f"fence error, nothing applied: {e!r}", detail=traceback.format_exc(limit=3))
        watched = None

    if verdict.kind == "skip":
        response.normal(rsp, f"fence/{mode}: skipped: {verdict.message}")
        return

    if verdict.kind == "reject":
        response.warning(rsp, f"fence/{mode}: REJECTED: {verdict.message}")
        rsp.results[-1].reason = "FenceRejected"
        if watched is not None:
            add(rsp, event(watched, "FenceRejected", verdict.message, "Warning", mode, now))
        return

    response.normal(rsp, f"fence/{mode}: approved: {verdict.message}")
    rsp.results[-1].reason = "FenceApproved"
    add(rsp, verdict.patch)
    if mode == "remediate":
        add(rsp, event(watched, "FenceApproved", verdict.message, "Normal", mode, now))


class Verdict:
    def __init__(self, kind: str, message: str, patch: dict | None = None, detail: str = ""):
        self.kind = kind  # approve | reject | skip
        self.message = message
        self.patch = patch
        self.detail = detail

    def __repr__(self):
        return f"Verdict({self.kind!r}, {self.message!r})"


def judge(mode: str, watched: dict | None, proposals: list[dict], codes: list[str], now, seen=None) -> Verdict:
    """Decide what, if anything, to apply. Pure function: no I/O.

    seen is the state() the gate recorded before the AI step.
    """
    if mode not in ALLOWED:
        return Verdict("reject", f"unknown fence mode {mode!r}")

    if watched is None:
        return Verdict("skip", "no watched resource")
    meta = watched.get("metadata", {})
    if meta.get("resourceVersion") == DELETED or meta.get("deletionTimestamp"):
        return Verdict("skip", "cache is being deleted")

    # A diagnosis describes the state the model saw. If that changed while it
    # was thinking, the text is about a state that no longer exists. (The
    # remediate checks below all run against the live Cache, so they don't
    # need this.)
    if mode == "diagnose" and seen is not None and seen != state(watched):
        return Verdict("skip", f"stale: state changed while the model was thinking ({seen} → {state(watched)})")

    if not proposals:
        return Verdict("skip", "the model returned no usable proposal")

    # Small models often leave out the namespace of a namespaced object they
    # were shown; read that as "the same namespace".
    for p in proposals:
        if isinstance(p.get("metadata"), dict) and not p["metadata"].get("namespace"):
            p["metadata"]["namespace"] = meta.get("namespace")

    # Every proposal must target the watched Cache, and only it.
    strangers = [p for p in proposals if identity(p) != identity(watched)]
    if strangers:
        names = ", ".join("/".join(x for x in identity(p) if x) for p in strangers)
        return Verdict("reject", f"proposal touches another resource: {names}")
    if len(proposals) > 1:
        return Verdict("reject", "more than one proposal for the same resource")
    proposal = proposals[0]

    changed = sorted(diff(proposal, watched))
    disallowed = [p for p in changed if p not in ALLOWED[mode]]
    if disallowed:
        return Verdict("reject", f"{mode} may not change {', '.join(fmt(p) for p in disallowed)}")

    if mode == "diagnose":
        return judge_diagnosis(watched, proposal, now)
    return judge_remediation(watched, proposal, codes, now)


def judge_diagnosis(watched: dict, proposal: dict, now) -> Verdict:
    current = state(watched)
    if annotations(watched).get(DIAGNOSED_STATE) == current:
        return Verdict("skip", f"already diagnosed {current}")

    text = annotations(proposal).get(DIAGNOSIS)
    if not isinstance(text, str) or not text.strip():
        return Verdict("skip", "the model proposed no diagnosis")
    text = " ".join(text.split())
    if len(text) > MAX_DIAGNOSIS:
        text = text[: MAX_DIAGNOSIS - 1].rstrip() + "…"

    patch = skeleton(watched)
    patch["metadata"]["annotations"] = {
        DIAGNOSIS: text,
        LAST_DIAGNOSED: stamp(now),
        DIAGNOSED_STATE: current,
    }
    return Verdict("approve", "diagnosis annotations only", patch)


def judge_remediation(watched: dict, proposal: dict, codes: list[str], now) -> Verdict:
    if watched["metadata"].get("labels", {}).get(APPROVAL_LABEL) != "true":
        # Not an AI misstep: the watch's label filter already excludes such
        # Caches, except for the one run triggered by removing the label.
        return Verdict("skip", f"not approved: label {APPROVAL_LABEL}=true is not set")
    if not annotations(watched).get(DIAGNOSIS):
        return Verdict("reject", "no diagnosis recorded yet: explain before acting")

    current = watched["spec"]["parameters"]["costCenter"]
    if current in codes:
        return Verdict("skip", f"cost center {current} already exists in the registry, nothing to fix")

    proposed = proposal.get("spec", {}).get("parameters", {}).get("costCenter", current)
    if proposed == current:
        return Verdict("skip", "the model proposed no change")
    if not isinstance(proposed, str) or not COST_CENTER.match(proposed):
        return Verdict("reject", f"cost center {proposed!r} does not match ^CC-[0-9]{{4}}$")
    if proposed not in codes:
        return Verdict("reject", f"cost center {proposed} is not in the registry (known: {', '.join(sorted(codes))})")

    patch = skeleton(watched)
    patch["spec"] = {"parameters": {"costCenter": proposed}}
    patch["metadata"]["annotations"] = {AUTO_REMEDIATED: f"{stamp(now)}: costCenter {current} → {proposed}"}
    return Verdict("approve", f"spec.parameters.costCenter {current} → {proposed} (in registry, approved by label)", patch)


def diff(proposal: dict, watched: dict, path: tuple = ()) -> set[tuple]:
    """Paths of leaves the proposal sets to a value different from the watched object.

    Fields the proposal leaves out are not changes: the fence's patch is applied
    with server-side apply, which never removes fields it does not mention.
    """
    if any(path[: len(p)] == p for p in IGNORED_PREFIXES):
        return set()
    if isinstance(proposal, dict) and isinstance(watched, dict):
        out = set()
        for k, v in proposal.items():
            out |= diff(v, watched.get(k, Missing), path + (k,))
        return out
    if isinstance(proposal, dict) and watched is Missing:
        out = set()
        for k, v in proposal.items():
            out |= diff(v, Missing, path + (k,))
        return out
    return set() if same(proposal, watched) else {path}


class _Missing:
    def __repr__(self):
        return "Missing"


Missing = _Missing()


def same(a, b) -> bool:
    if b is Missing:
        return False
    # Struct numbers arrive as floats; 1 and 1.0 are the same value.
    return json.dumps(a, sort_keys=True, default=str) == json.dumps(b, sort_keys=True, default=str) or (
        isinstance(a, (int, float)) and isinstance(b, (int, float)) and float(a) == float(b)
    )


def identity(obj: dict) -> tuple:
    meta = obj.get("metadata", {})
    return (obj.get("apiVersion"), obj.get("kind"), meta.get("namespace"), meta.get("name"))


def skeleton(watched: dict) -> dict:
    meta = watched["metadata"]
    return {
        "apiVersion": watched["apiVersion"],
        "kind": watched["kind"],
        "metadata": {"name": meta["name"], "namespace": meta["namespace"]},
    }


def annotations(obj: dict) -> dict:
    return obj.get("metadata", {}).get("annotations", {}) or {}


def condition(obj: dict, typ: str) -> str:
    for c in obj.get("status", {}).get("conditions", []):
        if c.get("type") == typ:
            return c.get("status", "Unknown")
    return "Unknown"


def fmt(path: tuple) -> str:
    out = ""
    for p in path:
        out += f'["{p}"]' if ("." in p or "/" in p) else (f".{p}" if out else p)
    return out


def stamp(now) -> str:
    return now.strftime("%Y-%m-%dT%H:%M:%SZ")


def event(watched: dict, reason: str, message: str, typ: str, mode: str, now) -> dict:
    """A core Event on the Cache. Operations can't target their own events at the
    watched resource, so the fence applies one as an ordinary object."""
    meta = watched["metadata"]
    key = hashlib.sha256(f"{meta.get('uid')}|{reason}|{message}|{now.isoformat()}".encode()).hexdigest()[:10]
    return {
        "apiVersion": "v1",
        "kind": "Event",
        "metadata": {"name": f"{meta['name']}.fence-{key}", "namespace": meta["namespace"]},
        "involvedObject": {
            "apiVersion": watched["apiVersion"],
            "kind": watched["kind"],
            "name": meta["name"],
            "namespace": meta["namespace"],
            "uid": meta.get("uid", ""),
        },
        "reason": reason,
        "message": message,
        "type": typ,
        "source": {"component": f"fence/{mode}"},
        "firstTimestamp": stamp(now),
        "lastTimestamp": stamp(now),
        "count": 1,
    }


def add(rsp: fnv1.RunFunctionResponse, obj: dict):
    key = obj["kind"].lower() + "-" + obj["metadata"]["name"]
    resource.update(rsp.desired.resources[key], obj)
