"""Unit tests for the fence: fixtures of AI output, good and bad.

Every bad proposal must be rejected or skipped, and nothing but the allowlisted
fields may ever reach the API server.
"""

import copy
import datetime
import importlib.util
import pathlib

import pytest
from crossplane.function import resource, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("fence", ROOT / "functions" / "fence.py")
fence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fence)

NOW = datetime.datetime(2026, 10, 5, 9, 30, 0, tzinfo=datetime.timezone.utc)
API = "cache.demo.example.org/v1alpha1"
DIAG = "cache.demo.example.org/diagnosis"
REGISTRY = ["CC-4711", "CC-5200", "CC-6300"]

STUCK = {
    "apiVersion": API,
    "kind": "Cache",
    "metadata": {
        "name": "demo-stuck",
        "namespace": "default",
        "uid": "0b5c1f2e-0000-4000-8000-000000000001",
        "resourceVersion": "4242",
        "generation": 1,
        "creationTimestamp": "2026-10-05T09:28:00Z",
        "managedFields": [{"manager": "kubectl-create", "operation": "Update"}],
    },
    "spec": {
        "parameters": {"application": "payments-api", "costCenter": "CC-4171", "sku": "s"},
        "crossplane": {"compositionRef": {"name": "cache"}},
    },
    "status": {
        "costCenter": {"code": "CC-4171", "found": False},
        "conditions": [
            {"type": "Ready", "status": "False", "reason": "Creating"},
            {
                "type": "CostCenterResolved",
                "status": "False",
                "reason": "NotFound",
                "message": "No CostCenter matches CC-4171. Known: CC-4711, CC-5200, CC-6300",
            },
        ],
    },
}


def watched(labels=None, annotations=None, **meta):
    w = copy.deepcopy(STUCK)
    if labels:
        w["metadata"]["labels"] = labels
    if annotations:
        w["metadata"]["annotations"] = annotations
    w["metadata"].update(meta)
    return w


APPROVED = dict(labels={"allow-auto-remediation": "true"}, annotations={DIAG: "costCenter CC-4171 does not exist."})


def cache_patch(annotations=None, labels=None, parameters=None, **meta):
    p = {"apiVersion": API, "kind": "Cache", "metadata": {"name": "demo-stuck", "namespace": "default", **meta}}
    if annotations:
        p["metadata"]["annotations"] = annotations
    if labels:
        p["metadata"]["labels"] = labels
    if parameters:
        p["spec"] = {"parameters": parameters}
    return p


def run(mode, w, proposals, seen=None):
    """Run the fence the way Crossplane would after the AI step.

    seen is the state the gate recorded before the AI step.
    """
    req = fnv1.RunFunctionRequest()
    if seen is not None:
        req.context[fence.SNAPSHOT] = {"state": seen}
    if w is not None:
        req.required_resources["ops.crossplane.io/watched-resource"].items.add().resource.update(w)
    for g in REGISTRY:
        item = req.required_resources["cost-centers"].items.add()
        item.resource.update({"apiVersion": "registry.demo.example.org/v1alpha1", "kind": "CostCenter", "spec": {"code": g}})
    for i, p in enumerate(proposals):
        req.desired.resources[f"ai-{i}"].resource.update(p)
    rsp = response.to(req)
    fence.fence(mode, req, rsp, now=NOW)
    applied = {k: resource.struct_to_dict(v.resource) for k, v in rsp.desired.resources.items()}
    caches = [a for a in applied.values() if a["kind"] == "Cache"]
    events = [a for a in applied.values() if a["kind"] == "Event"]
    assert len(applied) == len(caches) + len(events), f"fence emitted unexpected kinds: {applied}"
    for r in rsp.results:
        assert r.severity != fnv1.SEVERITY_FATAL, "the fence must never fail the Operation"
    return caches, events, [r.message for r in rsp.results]


def assert_nothing_applied(caches):
    assert caches == []


# --- diagnose ----------------------------------------------------------------


def test_diagnose_good_patch_writes_only_diagnosis_annotations():
    caches, events, msgs = run("diagnose", watched(), [cache_patch(annotations={DIAG: "costCenter CC-4171 matches no cost center; likely CC-4711."})])
    assert caches == [
        {
            "apiVersion": API,
            "kind": "Cache",
            "metadata": {
                "name": "demo-stuck",
                "namespace": "default",
                "annotations": {
                    DIAG: "costCenter CC-4171 matches no cost center; likely CC-4711.",
                    "cache.demo.example.org/last-diagnosed": "2026-10-05T09:30:00Z",
                    "cache.demo.example.org/diagnosed-state": "CC-4171/s/False/False",
                },
            },
        }
    ]
    assert events == []
    assert "approved" in msgs[-1]


def test_diagnose_full_object_echo_is_accepted():
    """Models often echo the whole object back, status and all."""
    echo = watched(annotations={DIAG: "CC-4171 is a typo for CC-4711."})
    caches, _, _ = run("diagnose", watched(), [echo])
    assert caches[0]["metadata"]["annotations"][DIAG] == "CC-4171 is a typo for CC-4711."
    assert "spec" not in caches[0] and "status" not in caches[0]


def test_diagnose_that_also_patches_cost_center_is_rejected():
    p = cache_patch(annotations={DIAG: "fixed it"}, parameters={"costCenter": "CC-4711"})
    caches, events, msgs = run("diagnose", watched(), [p])
    assert_nothing_applied(caches)
    assert events[0]["reason"] == "FenceRejected"
    assert 'spec.parameters.costCenter' in events[0]["message"]


def test_diagnose_that_grants_itself_approval_is_rejected():
    p = cache_patch(annotations={DIAG: "ok"}, labels={"allow-auto-remediation": "true"})
    caches, events, _ = run("diagnose", watched(), [p])
    assert_nothing_applied(caches)
    assert "allow-auto-remediation" in events[0]["message"]


def test_diagnose_is_deduplicated_per_state():
    w = watched(annotations={DIAG: "old", "cache.demo.example.org/diagnosed-state": "CC-4171/s/False/False"})
    caches, events, msgs = run("diagnose", w, [cache_patch(annotations={DIAG: "new words, same facts"})])
    assert_nothing_applied(caches)
    assert events == []
    assert "already diagnosed" in msgs[-1]


def test_diagnose_long_text_is_trimmed_to_one_line():
    caches, _, _ = run("diagnose", watched(), [cache_patch(annotations={DIAG: "word\n" * 200})])
    text = caches[0]["metadata"]["annotations"][DIAG]
    assert "\n" not in text and len(text) <= fence.MAX_DIAGNOSIS


# --- remediate ---------------------------------------------------------------


def test_remediate_good_patch_changes_only_cost_center():
    caches, events, msgs = run("remediate", watched(**APPROVED), [cache_patch(parameters={"costCenter": "CC-4711"})])
    assert caches == [
        {
            "apiVersion": API,
            "kind": "Cache",
            "metadata": {
                "name": "demo-stuck",
                "namespace": "default",
                "annotations": {"cache.demo.example.org/auto-remediated": "2026-10-05T09:30:00Z: costCenter CC-4171 → CC-4711"},
            },
            "spec": {"parameters": {"costCenter": "CC-4711"}},
        }
    ]
    assert events[0]["reason"] == "FenceApproved" and events[0]["type"] == "Normal"
    assert events[0]["involvedObject"]["uid"] == STUCK["metadata"]["uid"]


def test_remediate_proposal_without_namespace_is_accepted():
    p = cache_patch(parameters={"costCenter": "CC-4711"})
    del p["metadata"]["namespace"]
    caches, _, _ = run("remediate", watched(**APPROVED), [p])
    assert caches[0]["spec"]["parameters"]["costCenter"] == "CC-4711"


def test_remediate_that_also_changes_sku_is_rejected():
    p = cache_patch(parameters={"costCenter": "CC-4711", "sku": "xl"})
    caches, events, _ = run("remediate", watched(**APPROVED), [p])
    assert_nothing_applied(caches)
    assert "spec.parameters.sku" in events[0]["message"]


def test_remediate_to_cost_center_not_in_registry_is_rejected():
    caches, events, _ = run("remediate", watched(**APPROVED), [cache_patch(parameters={"costCenter": "CC-9999"})])
    assert_nothing_applied(caches)
    assert "not in the registry" in events[0]["message"]


def test_remediate_to_malformed_cost_center_is_rejected():
    caches, events, _ = run("remediate", watched(**APPROVED), [cache_patch(parameters={"costCenter": "cc-4711; drop"})])
    assert_nothing_applied(caches)
    assert "does not match" in events[0]["message"]


def test_hostile_proposal_touching_another_resource_is_rejected():
    secret = {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "gpt", "namespace": "crossplane-system"}, "stringData": {"OPENAI_BASE_URL": "http://evil"}}
    good = cache_patch(parameters={"costCenter": "CC-4711"})
    caches, events, _ = run("remediate", watched(**APPROVED), [good, secret])
    assert_nothing_applied(caches)
    assert "another resource" in events[0]["message"] and "Secret" in events[0]["message"]


def test_hostile_proposal_for_a_different_cache_is_rejected():
    other = cache_patch(parameters={"costCenter": "CC-4711"})
    other["metadata"]["name"] = "someone-elses-cache"
    caches, events, _ = run("remediate", watched(**APPROVED), [other])
    assert_nothing_applied(caches)
    assert "someone-elses-cache" in events[0]["message"]


def test_remediate_without_approval_label_applies_nothing():
    w = watched(annotations={DIAG: "CC-4171 does not exist."})
    caches, events, msgs = run("remediate", w, [cache_patch(parameters={"costCenter": "CC-4711"})])
    assert_nothing_applied(caches)
    assert events == []
    assert "not approved" in msgs[-1]


def test_remediate_without_diagnosis_is_rejected():
    w = watched(labels={"allow-auto-remediation": "true"})
    caches, events, _ = run("remediate", w, [cache_patch(parameters={"costCenter": "CC-4711"})])
    assert_nothing_applied(caches)
    assert "explain before acting" in events[0]["message"]


def test_remediate_when_cost_center_already_valid_is_a_noop():
    w = watched(**APPROVED)
    w["spec"]["parameters"]["costCenter"] = "CC-4711"
    caches, events, msgs = run("remediate", w, [cache_patch(parameters={"costCenter": "CC-5200"})])
    assert_nothing_applied(caches)
    assert events == []
    assert "nothing to fix" in msgs[-1]


# --- both modes --------------------------------------------------------------


@pytest.mark.parametrize("mode", ["diagnose", "remediate"])
def test_deleted_cache_applies_nothing(mode):
    w = watched(**APPROVED, resourceVersion="ops.crossplane.io/synthetic-deleted")
    caches, events, _ = run(mode, w, [cache_patch(annotations={DIAG: "x"}, parameters={"costCenter": "CC-4711"})])
    assert_nothing_applied(caches)
    assert events == []


@pytest.mark.parametrize("mode", ["diagnose", "remediate"])
def test_empty_model_output_applies_nothing(mode):
    caches, events, msgs = run(mode, watched(**APPROVED), [])
    assert_nothing_applied(caches)
    assert "no usable proposal" in msgs[-1]


@pytest.mark.parametrize("mode", ["diagnose", "remediate"])
def test_fence_bug_applies_nothing_and_does_not_fail(mode, monkeypatch):
    def boom(*_):
        raise KeyError("spec")

    monkeypatch.setattr(fence, "judge", boom)
    caches, events, msgs = run(mode, watched(**APPROVED), [cache_patch(annotations={DIAG: "x"})])
    assert_nothing_applied(caches)
    assert "fence error" in msgs[-1]


# --- gate ---------------------------------------------------------------------


def run_gate(mode, w):
    req = fnv1.RunFunctionRequest()
    if w is not None:
        req.required_resources["ops.crossplane.io/watched-resource"].items.add().resource.update(w)
    for g in REGISTRY:
        req.required_resources["cost-centers"].items.add().resource.update({"spec": {"code": g}})
    rsp = response.to(req)
    fence.gate(mode, req, rsp)
    fatal = [r.message for r in rsp.results if r.severity == fnv1.SEVERITY_FATAL]
    return fatal, resource.struct_to_dict(rsp.context).get(fence.SNAPSHOT), len(rsp.desired.resources)


def test_gate_asks_the_model_about_an_undiagnosed_state_and_records_it():
    fatal, snap, desired = run_gate("diagnose", watched())
    assert fatal == [] and desired == 0
    assert snap == {"state": "CC-4171/s/False/False"}


def test_gate_does_not_wake_the_model_for_an_already_diagnosed_state():
    w = watched(annotations={DIAG: "x", "cache.demo.example.org/diagnosed-state": "CC-4171/s/False/False"})
    fatal, snap, _ = run_gate("diagnose", w)
    assert "model not called: already diagnosed" in fatal[0] and snap is None


def test_gate_ignores_crossplane_bookkeeping_changes():
    """A new condition such as Responsive is not a new state worth a model call."""
    w = watched(annotations={DIAG: "x", "cache.demo.example.org/diagnosed-state": "CC-4171/s/False/False"})
    w["status"]["conditions"].append({"type": "Responsive", "status": "True"})
    w["metadata"]["resourceVersion"] = "9999"
    fatal, _, _ = run_gate("diagnose", w)
    assert fatal


def converged_to(code, resolved, ready):
    w = watched()
    w["spec"]["parameters"]["costCenter"] = "CC-4711"
    w["status"]["costCenter"]["code"] = code
    w["status"]["conditions"] = [{"type": "CostCenterResolved", "status": resolved}, {"type": "Ready", "status": ready}]
    return w


@pytest.mark.parametrize(
    "w, reason",
    [
        (converged_to("CC-4171", "False", "False"), "status is about CC-4171"),  # status lags the patch
        (converged_to("CC-4711", "True", "False"), "resources coming up"),  # Valkey starting
    ],
)
def test_gate_waits_while_the_controller_converges(w, reason):
    fatal, _, _ = run_gate("diagnose", w)
    assert reason in fatal[0]


def test_gate_asks_the_model_about_a_settled_healthy_state():
    fatal, snap, _ = run_gate("diagnose", converged_to("CC-4711", "True", "True"))
    assert fatal == [] and snap == {"state": "CC-4711/s/True/True"}


@pytest.mark.parametrize(
    "w, reason",
    [
        (watched(annotations={DIAG: "x"}), "not approved"),
        (watched(labels={"allow-auto-remediation": "true"}), "explain before acting"),
        (None, "no watched resource"),
    ],
)
def test_gate_does_not_wake_the_model_for_remediation_it_may_not_do(w, reason):
    fatal, _, _ = run_gate("remediate", w)
    assert reason in fatal[0]


def test_gate_does_not_wake_the_model_when_nothing_is_broken():
    w = watched(**APPROVED)
    w["spec"]["parameters"]["costCenter"] = "CC-4711"
    fatal, _, _ = run_gate("remediate", w)
    assert "nothing to fix" in fatal[0]


def test_gate_asks_the_model_to_remediate_with_approval_and_diagnosis():
    fatal, snap, _ = run_gate("remediate", watched(**APPROVED))
    assert fatal == [] and snap == {"state": "CC-4171/s/False/False"}


# --- staleness ----------------------------------------------------------------


def test_diagnosis_of_a_state_that_changed_meanwhile_is_not_applied():
    caches, events, msgs = run("diagnose", watched(), [cache_patch(annotations={DIAG: "not Ready"})], seen="CC-4711/s/True/False")
    assert_nothing_applied(caches)
    assert events == []
    assert "stale" in msgs[-1]


def test_diagnosis_of_the_state_the_model_saw_is_applied():
    caches, _, _ = run("diagnose", watched(), [cache_patch(annotations={DIAG: "not Ready"})], seen="CC-4171/s/False/False")
    assert caches[0]["metadata"]["annotations"][DIAG] == "not Ready"


def test_remediation_is_judged_against_the_live_cache_not_the_snapshot():
    caches, _, _ = run("remediate", watched(**APPROVED), [cache_patch(parameters={"costCenter": "CC-4711"})], seen="something else")
    assert caches[0]["spec"]["parameters"]["costCenter"] == "CC-4711"
