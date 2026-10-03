#!/usr/bin/env bash
#
# "Let AI Think. Let Controllers Reconcile." DevOpsDays Prague 2026 demo.
#
# Fully local: kind + Crossplane v2.4 + function-openai -> Ollama on this Mac.
# The AI explains and proposes; a deterministic fence checks; a human consents
# with a label; the Cache controller converges. The AI never touches anything
# but the API.
#
# Usage:
#   ./demo.sh up            # one-time setup, needs network (run before the talk)
#   ./demo.sh               # guided talk: preflight, then 5 beats, ENTER between steps
#   ./demo.sh reset         # back to the start state
#   ./demo.sh <beat>        # stuck | explain | consent | patch | reconcile | off
#   ./demo.sh fence         # Q&A: bad proposals bounce off the fence and the schema
#   ./demo.sh status        # preflight checklist only
#   ./demo.sh rehearse [N]  # N unattended full runs with timings (default 1)
#   ./demo.sh test          # fence unit tests + composition render tests
#   ./demo.sh model [BASE]  # show or switch the local model (rebuilds cache-sre)
#   ./demo.sh airplane on|off  # cut the cluster off the internet (rehearse offline)
#   ./demo.sh down          # delete the cluster, stop Ollama (models stay on disk)
#
# Flags:
#   --auto SECS             # don't wait for ENTER; sleep SECS instead (recording)
#   --notes                 # print speaker lines on screen
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TOOLS="${DIR}/.tools"
RUN="${DIR}/.run"
BUILD="${DIR}/.build"
mkdir -p "${RUN}" "${BUILD}"

CLUSTER="devopsdays"
KCFG="${DIR}/.kubeconfig"          # own kubeconfig: never touches ~/.kube/config
KCTX="kind-${CLUSTER}"
NODE="${CLUSTER}-control-plane"

CROSSPLANE_VERSION="2.4.2"
VALKEY_IMAGE="valkey/valkey:9.1.2-alpine"
KIND_VERSION="v0.33.0"
OLLAMA_VERSION="v0.35.1"
ASCIINEMA_VERSION="v3.2.1"

export OLLAMA_HOST="127.0.0.1:11434"   # loopback only: not reachable from the venue Wi-Fi
OLLAMA_URL="http://${OLLAMA_HOST}"
MODEL="cache-sre"                       # built from llm/Modelfile

CACHE="demo-stuck"
NS="default"
CONSENT="allow-auto-remediation"
A="cache.demo.example.org"              # annotation prefix

AUTO_SLEEP=""
NOTES=0
POSITIONAL=()
while (( $# > 0 )); do
  case "$1" in
    --auto)   AUTO_SLEEP="$2"; shift 2 ;;
    --notes)  NOTES=1; shift ;;
    -h|--help) sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)        POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]:-}"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  CYAN=$'\033[36m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; MAGENTA=$'\033[35m'; RED=$'\033[31m'; BLUE=$'\033[34m'
else
  BOLD=""; DIM=""; RESET=""; CYAN=""; YELLOW=""; GREEN=""; MAGENTA=""; RED=""; BLUE=""
fi

k() { kubectl --kubeconfig "${KCFG}" --context "${KCTX}" "$@"; }

now() { python3 -c 'import time; print(f"{time.time():.1f}")'; }
since() { python3 -c "print(f'{$(now) - $1:.1f}')"; }

# ---------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------

pause() {
  local prompt="${1:-ENTER}"
  if [[ -n "${AUTO_SLEEP}" ]]; then
    sleep "${AUTO_SLEEP}"
  else
    read -r -p "${DIM}↪ ${prompt}…${RESET}" _
  fi
}

banner() {
  clear
  echo
  echo "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
  echo "${BOLD}${CYAN}  $*${RESET}"
  echo "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
  echo
}

beat()      { echo "${BOLD}${YELLOW}▸ $*${RESET}"; }
note()      { echo "${DIM}  $*${RESET}"; }
say()       { (( NOTES )) && echo "${MAGENTA}🗣  $*${RESET}" || true; }
ok()        { echo "  ${GREEN}✔${RESET} $*"; }
bad()       { echo "  ${RED}✘${RESET} $*"; }
echo_cmd()  { echo "${BOLD}${CYAN}\$ $*${RESET}"; }
punchline() { echo; echo "${BOLD}${GREEN}💡 $*${RESET}"; echo; }

# Show a kubectl command as the audience would type it, then run it.
kshow() { echo_cmd "kubectl $*"; k "$@"; }

# Indent and wrap free text (AI output) for a large stage font.
wrap() { fold -s -w "${1:-62}" | sed 's/^/    /'; }

# wait_for SECS "label" check_fn: spinner with elapsed time; 0 on success.
wait_for() {
  local timeout="$1" label="$2" check="$3" i=0 start=$SECONDS
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  while (( SECONDS - start < timeout )); do
    if "${check}"; then
      printf "\r\033[K  ${GREEN}✔${RESET} %s ${DIM}(%ss)${RESET}\n" "${label}" "$(( SECONDS - start ))"
      return 0
    fi
    printf "\r\033[K  ${CYAN}%s${RESET} %s ${DIM}%ss${RESET}" "${frames[$(( i % 10 ))]}" "${label}" "$(( SECONDS - start ))"
    i=$(( i + 1 ))
    sleep 0.5
  done
  printf "\r\033[K  ${RED}✘${RESET} %s ${DIM}(timed out after %ss)${RESET}\n" "${label}" "${timeout}"
  return 1
}

die() { echo "${RED}error:${RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# State queries
# ---------------------------------------------------------------------------

cache_json() { k get cache "${CACHE}" -n "${NS}" -o json 2>/dev/null; }
ann() { cache_json | jq -r --arg k "${A}/$1" '.metadata.annotations[$k] // empty'; }
cond() { cache_json | jq -r --arg t "$1" '.status.conditions[]? | select(.type==$t) | .status'; }

has_diagnosis()   { [[ -n "$(ann diagnosis)" ]]; }
has_remediation() { [[ -n "$(ann auto-remediated)" ]]; }
is_ready()        { [[ "$(cond Ready)" == "True" ]]; }
has_status()      { [[ -n "$(cond ResourceGroupResolved)" ]]; }

# True once the Cache's resourceVersion has not changed for 2 seconds.
LAST_RV=""; QUIET_SINCE=0
is_quiet() {
  local rv; rv=$(k get cache "${CACHE}" -n "${NS}" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)
  if [[ "${rv}" != "${LAST_RV}" ]]; then LAST_RV="${rv}"; QUIET_SINCE=${SECONDS}; return 1; fi
  (( SECONDS - QUIET_SINCE >= 2 ))
}
cache_gone()      { ! k get cache "${CACHE}" -n "${NS}" >/dev/null 2>&1; }

# Re-trigger the WatchOperations (any change to the Cache does). Used by retries.
nudge() { k annotate cache "${CACHE}" -n "${NS}" --overwrite "${A}/nudge=$(date +%s)" >/dev/null; }
watching_none()   { [[ "$(k get watchoperation remediate-caches -o jsonpath='{.status.watchingResources}' 2>/dev/null)" =~ ^0?$ ]]; }
fence_rejected()  { [[ -n "$(fence_events Warning | head -1)" ]]; }

# Conditions as aligned, colored rows: TYPE STATUS MESSAGE.
show_conditions() {
  cache_json | jq -r '.status.conditions[]? | select(.type=="Ready" or .type=="ResourceGroupResolved")
      | [.type, .status, (.message // .reason // "")] | @tsv' |
  while IFS=$'\t' read -r typ st msg; do
    local c="${RED}"; [[ "${st}" == "True" ]] && c="${GREEN}"
    printf "  %-22s %s%-6s%s" "${typ}" "${c}" "${st}" "${RESET}"
    echo "${msg}" | fold -s -w 40 | sed '2,$s/^/                               /'
  done
}

# The fence's verdicts, as events on the Cache. Optional type filter.
fence_events() {
  k get events -n "${NS}" --field-selector "involvedObject.name=${CACHE}" -o json 2>/dev/null |
    jq -r --arg t "${1:-}" '.items | map(select(.source.component // "" | startswith("fence/")))
      | map(select($t == "" or .type == $t)) | sort_by(.lastTimestamp) | .[] | [.type, .reason, .message] | @tsv'
}

# Each Operation's outcome: the gate's "model not called", or the fence's verdict.
op_verdicts() {
  k get events -A -o json 2>/dev/null | jq -r --arg w "$1" '.items
    | map(select(.involvedObject.kind == "Operation" and (.involvedObject.name | startswith($w))
                 and (.message | test("fence/|gate/[a-z]+: model not called"))))
    | sort_by(.lastTimestamp) | .[]
    | [.involvedObject.name, (.message | capture("(?<who>fence|gate)/[a-z]+: (?<v>.*)$") | .who + ": " + .v)] | @tsv'
}

# Last N fence verdicts of a WatchOperation's Operations, short and wrapped.
show_verdicts() {
  op_verdicts "$1" | tail -"${2:-3}" | while IFS=$'\t' read -r op v; do
    local c="${DIM}"
    case "${v}" in *approved*) c="${GREEN}" ;; *REJECTED*) c="${RED}" ;; esac
    printf "  #%s  %s" "${op##*-}" "${c}"
    echo "${v}" | fold -s -w 50 | sed '2,$s/^/            /'
    printf "%s" "${RESET}"
  done
}

# "One Cache, three writers": who owns which fields, from metadata.managedFields.
show_writers() {
  echo_cmd "kubectl get cache ${CACHE} --show-managed-fields -o yaml"
  k get cache "${CACHE}" -n "${NS}" --show-managed-fields -o json | jq -r '
    def short: sub("^f:"; "") | sub("^cache.demo.example.org/"; "");
    .metadata.managedFields[]
    | (.fieldsV1 // {}) as $f
    | ([$f | paths | select(length == 3 and .[0] == "f:spec" and .[1] == "f:parameters" and .[2] != ".") | "spec." + (.[2] | short)]
       + [$f | paths | select(length == 3 and .[0] == "f:metadata" and .[1] == "f:labels" and .[2] != "." and (.[2] | test("crossplane.io") | not)) | "label " + (.[2] | short)]
       + [$f | paths | select(length == 3 and .[0] == "f:metadata" and .[1] == "f:annotations" and .[2] != "."
            and (.[2] | test("last-diagnosed|diagnosed-state") | not)) | (.[2] | short)]
       + (if .subresource == "status" and ($f | has("f:status")) then ["status"] else [] end)) as $fields
    | select($fields | length > 0)
    | (if (.manager | startswith("kubectl")) then "0human"
       elif (.manager | startswith("ops.crossplane.io/operation/")) then "1AI+fence"
       else "2controller" end) as $who
    | [$who, (.manager | sub("^ops.crossplane.io/operation/(?<u>.{8}).*"; "operation/\(.u)") | sub("^apiextensions.crossplane.io/.*"; "crossplane")), ($fields | join(", "))] | @tsv' |
  sort -u | while IFS=$'\t' read -r who mgr fields; do
    local c="${CYAN}"
    case "${who}" in 1*) c="${YELLOW}" ;; 2*) c="${GREEN}" ;; esac
    printf "  %s%-10s%s %-19s " "${c}" "${who:1}" "${RESET}" "${mgr}"
    echo "${fields}" | fold -s -w 32 | sed '2,$s/^/                                 /'
  done
}

# WatchOperations: name, kind, how many Caches each one watches.
show_watchops() {
  echo_cmd "kubectl get watchoperations"
  k get watchoperations -o json | jq -r '["NAME","KIND","WATCHING"], (.items[] | [.metadata.name, .spec.watch.kind, (.status.watchingResources // 0 | tostring)]) | @tsv' |
    column -t | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
# Build: inject Python into the Composition and Operations
# ---------------------------------------------------------------------------

cmd_build() {
  yq '.spec.pipeline[0].input.script = load_str("functions/compose_cache.py")
      | .spec.pipeline[0].input.script style="literal"' \
    "${DIR}/apis/cache/composition.yaml" > "${BUILD}/composition.yaml"
  # The gate and fence steps both run functions/fence.py; MODE picks the role.
  local m
  for m in diagnose remediate; do
    MODE="${m}" yq '
        with(.spec.operationTemplate.spec.pipeline[] | select(.step == "gate") | .input.script;
          . = load_str("functions/fence.py") + "\nMODE = \"gate-" + strenv(MODE) + "\"\n" | . style="literal")
      | with(.spec.operationTemplate.spec.pipeline[] | select(.step == "fence") | .input.script;
          . = load_str("functions/fence.py") + "\nMODE = \"" + strenv(MODE) + "\"\n" | . style="literal")' \
      "${DIR}/operations/${m}-caches.yaml" > "${BUILD}/${m}-caches.yaml"
  done
}

# ---------------------------------------------------------------------------
# Local model (Ollama on the Mac, loopback only)
# ---------------------------------------------------------------------------

ollama() { "${TOOLS}/ollama/ollama" "$@"; }
ollama_alive() { curl -fsS -m 2 "${OLLAMA_URL}/api/version" >/dev/null 2>&1; }

ollama_up() {
  ollama_alive && return 0
  OLLAMA_MODELS="${DIR}/.models" OLLAMA_KEEP_ALIVE=-1 OLLAMA_CONTEXT_LENGTH=16384 \
  OLLAMA_NUM_PARALLEL=4 OLLAMA_NO_CLOUD=1 \
    nohup "${TOOLS}/ollama/ollama" serve > "${RUN}/ollama.log" 2>&1 &
  echo $! > "${RUN}/ollama.pid"
  local i; for i in $(seq 1 40); do ollama_alive && return 0; sleep 0.25; done
  die "Ollama did not start; see ${RUN}/ollama.log"
}

model_base() { awk '/^FROM /{print $2; exit}' "${DIR}/llm/Modelfile"; }
model_loaded() { curl -fsS -m 2 "${OLLAMA_URL}/api/ps" 2>/dev/null | jq -e --arg m "${MODEL}" '.models[] | select(.name | startswith($m))' >/dev/null; }

# Load the model into memory and keep it there.
model_warm() {
  curl -fsS -m 120 "${OLLAMA_URL}/api/generate" \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"\",\"keep_alive\":-1}" >/dev/null
}

cmd_model() {
  ollama_up
  if [[ -n "${1:-}" ]]; then
    ollama list | awk 'NR>1{print $1}' | grep -qx "$1" || ollama pull "$1"
    sed -i '' "s#^FROM .*#FROM $1#" "${DIR}/llm/Modelfile"
  fi
  ollama create "${MODEL}" -f "${DIR}/llm/Modelfile" >/dev/null 2>&1
  model_warm
  echo "model ${BOLD}${MODEL}${RESET} = $(model_base)"
}

# ---------------------------------------------------------------------------
# up / down / reset / status
# ---------------------------------------------------------------------------

fetch_tools() {
  mkdir -p "${TOOLS}"
  if [[ ! -x "${TOOLS}/kind" ]]; then
    curl -fsSL -o "${TOOLS}/kind" "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-darwin-arm64"
    chmod +x "${TOOLS}/kind"
  fi
  if [[ ! -x "${TOOLS}/ollama/ollama" ]]; then
    mkdir -p "${TOOLS}/ollama"
    curl -fsSL "https://github.com/ollama/ollama/releases/download/${OLLAMA_VERSION}/ollama-darwin.tgz" | tar -xz -C "${TOOLS}/ollama"
  fi
  if [[ ! -x "${TOOLS}/asciinema" ]]; then
    curl -fsSL -o "${TOOLS}/asciinema" "https://github.com/asciinema/asciinema/releases/download/${ASCIINEMA_VERSION}/asciinema-aarch64-apple-darwin"
    chmod +x "${TOOLS}/asciinema"
  fi
}

host_ip() { docker exec "${NODE}" getent ahostsv4 host.docker.internal | awk 'NR==1{print $1}'; }

cmd_up() {
  local t0; t0=$(now)
  for t in docker kubectl helm yq jq crossplane python3; do
    command -v "$t" >/dev/null || die "'$t' not found in PATH"
  done
  beat "Tools (into .tools/, nothing system-wide)"; fetch_tools

  beat "Local model"
  ollama_up
  ollama list | awk 'NR>1{print $1}' | grep -qx "$(model_base)" || ollama pull "$(model_base)"
  cmd_model

  beat "kind cluster ${CLUSTER}"
  if ! "${TOOLS}/kind" get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
    "${TOOLS}/kind" create cluster --config "${DIR}/cluster/kind.yaml" --kubeconfig "${KCFG}"
  fi

  beat "Preload ${VALKEY_IMAGE} (no image pulls on stage)"
  docker image inspect "${VALKEY_IMAGE}" >/dev/null 2>&1 || docker pull -q --platform linux/arm64 "${VALKEY_IMAGE}"
  docker save --platform linux/arm64 "${VALKEY_IMAGE}" |
    docker exec -i "${NODE}" ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs - >/dev/null

  beat "Crossplane ${CROSSPLANE_VERSION} (Operations enabled)"
  k create namespace crossplane-system --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply -f "${DIR}/crossplane/package-cache-pvc.yaml" >/dev/null
  helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
  helm repo update crossplane-stable >/dev/null
  helm upgrade --install crossplane crossplane-stable/crossplane --version "${CROSSPLANE_VERSION}" \
    --kubeconfig "${KCFG}" --kube-context "${KCTX}" -n crossplane-system \
    -f "${DIR}/crossplane/values.yaml" --wait --timeout 10m >/dev/null

  beat "Functions"
  k apply -f "${DIR}/crossplane/functions.yaml" >/dev/null
  k wait function --all --for=condition=Healthy --timeout=5m >/dev/null

  beat "APIs, registry, composition"
  cmd_build
  k apply -f "${DIR}/registry/resourcegroup-crd.yaml" -f "${DIR}/registry/rbac.yaml" -f "${DIR}/apis/cache/definition.yaml" >/dev/null
  k wait crd/resourcegroups.registry.demo.example.org --for=condition=Established --timeout=60s >/dev/null
  k wait xrd/caches.cache.demo.example.org --for=condition=Established --timeout=120s >/dev/null
  k apply -f "${DIR}/registry/resourcegroups.yaml" -f "${BUILD}/composition.yaml" >/dev/null

  beat "Cluster -> Ollama on this Mac"
  sed "s/\${HOST_IP}/$(host_ip)/" "${DIR}/llm/ollama-service.yaml" | k apply -f - >/dev/null
  k apply -f "${DIR}/llm/secret.yaml" >/dev/null

  cmd_reset
  echo "${BOLD}${GREEN}✔ up in $(since "${t0}")s${RESET}"
}

cmd_reset() {
  local t0; t0=$(now)
  beat "Reset"
  ollama_up
  # Stop the AI controllers first so nothing reacts while we rebuild.
  k delete watchoperation diagnose-caches remediate-caches --ignore-not-found --wait=true >/dev/null
  k delete operations --all --wait=false >/dev/null 2>&1 || true
  k delete cache "${CACHE}" -n "${NS}" --ignore-not-found --wait=false >/dev/null
  wait_for 60 "old Cache deleted" cache_gone >/dev/null || die "Cache ${CACHE} did not delete"
  k delete events -n "${NS}" --field-selector "involvedObject.name=${CACHE}" >/dev/null 2>&1 || true
  k delete events -A --field-selector involvedObject.kind=Operation >/dev/null 2>&1 || true
  # `create` (not `apply`): no last-applied annotation for the model to read.
  k create -f "${DIR}/examples/demo-stuck.yaml" >/dev/null
  wait_for 60 "controller reported status" has_status >/dev/null || die "Cache got no status"
  # Let Crossplane finish its bookkeeping writes first: each write would start
  # another diagnosis while the first is still with the model.
  LAST_RV=""; wait_for 15 "controller settled" is_quiet >/dev/null || true
  # Now the AI controllers: diagnose starts on the Cache right away.
  cmd_build
  k apply -f "${BUILD}/diagnose-caches.yaml" -f "${BUILD}/remediate-caches.yaml" >/dev/null
  model_loaded || model_warm
  ok "start state: ${CACHE} ardId=ARD-010, no label, not Ready ${DIM}($(since "${t0}")s)${RESET}"
}

cmd_down() {
  "${TOOLS}/kind" delete cluster --name "${CLUSTER}" --kubeconfig "${KCFG}" || true
  if [[ -f "${RUN}/ollama.pid" ]]; then kill "$(cat "${RUN}/ollama.pid")" 2>/dev/null || true; rm -f "${RUN}/ollama.pid"; fi
  echo "down. Models stay in .models/ (delete that folder to reclaim disk)."
}

# Preflight checklist. Returns non-zero if anything critical is off.
cmd_status() {
  local fail=0
  if k get --raw /readyz >/dev/null 2>&1; then ok "kind cluster ${CLUSTER}"; else bad "kind cluster ${CLUSTER} not reachable (./demo.sh up)"; return 1; fi
  if k -n crossplane-system rollout status deploy/crossplane --timeout=5s >/dev/null 2>&1 && k get crd watchoperations.ops.crossplane.io >/dev/null 2>&1; then
    ok "Crossplane ${CROSSPLANE_VERSION}, Operations enabled"
  else bad "Crossplane not ready"; fail=1; fi
  local unhealthy; unhealthy=$(k get functions -o json | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Healthy" and .status!="True")) | .metadata.name')
  if [[ -z "${unhealthy}" ]]; then ok "functions: function-python, function-openai"; else bad "unhealthy functions: ${unhealthy}"; fail=1; fi
  if ollama_alive; then
    if model_loaded; then ok "model ${MODEL} ($(model_base)) loaded on ${OLLAMA_HOST}"; else bad "model not loaded (warming...)"; model_warm && ok "model warm"; fi
  else bad "Ollama not running (./demo.sh reset starts it)"; fail=1; fi
  if docker exec "${NODE}" curl -fsS -m 3 "http://$(host_ip):11434/api/version" >/dev/null 2>&1; then ok "cluster reaches Ollama"; else bad "cluster cannot reach Ollama"; fail=1; fi
  local ard label ready
  ard=$(cache_json | jq -r '.spec.parameters.ardId // empty'); label=$(cache_json | jq -r --arg l "${CONSENT}" '.metadata.labels[$l] // empty'); ready=$(cond Ready)
  if [[ "${ard}" == "ARD-010" && -z "${label}" && "${ready}" != "True" ]]; then
    ok "start state: ${CACHE} ardId=ARD-010, no consent label, not Ready"
  else
    bad "not at start state (ardId=${ard:-none} label=${label:-none} Ready=${ready:-none})"; fail=2
  fi
  return "${fail}"
}

# ---------------------------------------------------------------------------
# The five beats
# ---------------------------------------------------------------------------

beat_stuck() {
  banner "1 · Stuck"
  say "A developer asked for a cache. It's stuck: Synced, not Ready, and an event saying no ResourceGroup matches ARD-010."
  say "The controller knows exactly what is wrong. It has no idea what you meant, and it shouldn't guess."
  kshow get cache "${CACHE}"
  echo
  pause
  beat "Why? The controller's conditions"
  show_conditions
  echo
  beat "Events, raw"
  echo_cmd "kubectl events --for cache/${CACHE}"
  k events -n "${NS}" --for "cache/${CACHE}" -o json | jq -r '.items | map(select(.type=="Warning")) | .[-1:][] | [.type, .reason, .message] | @tsv' |
    while IFS=$'\t' read -r t r m; do echo "  ${YELLOW}${t}${RESET}  ${r}"; echo "  ${m}"; done
  echo
  pause
  beat "The resource groups that do exist"
  kshow get resourcegroups
  punchline "The controller knows what is wrong. Not what you meant."
}

beat_explain() {
  banner "2 · Explain"
  say "A WatchOperation hands this Cache to a model on this laptop. It may write one annotation, and plain Python enforces that, not the prompt."
  say "It reads the same objects I just read: probably a digit swap, ARD-001 belongs to payments. It explained. Nothing changed."
  show_watchops
  echo
  if ! wait_for 90 "AI diagnosis (local model)" has_diagnosis; then
    note "Model slow or down: ./demo.sh status · tail .run/ollama.log · fall back to the recording"
    return 1
  fi
  echo
  beat "What the AI wrote ${DIM}(annotation ${A}/diagnosis)${RESET}"
  echo -n "${YELLOW}"; ann diagnosis | wrap; echo -n "${RESET}"
  echo
  beat "What the deterministic steps decided ${DIM}(per Operation)${RESET}"
  show_verdicts diagnose-caches 3
  echo
  beat "Nothing else changed"
  kshow get cache "${CACHE}"
  punchline "AI reasons and explains. It wrote an annotation, nothing more."
}

beat_consent() {
  banner "3 · Consent"
  say "I agree with it. But I don't type the fix. I grant consent, the Kubernetes way: one label."
  say "The remediation controller only watches Caches with that label. Without it, it can't even run."
  kshow label cache "${CACHE}" "${CONSENT}=true"
  echo
  note "remediate-caches only watches Caches with ${CONSENT}=true:"
  sleep 1
  show_watchops
  punchline "Consent is a label in the API, not a sentence in a prompt."
}

beat_patch() {
  banner "4 · Patch"
  say "Now the AI may propose a change. The fence checks it: only ardId, only to a group that exists, only with consent."
  say "Who wrote what: I wrote spec and label, the AI one field and its notes, the controller status. One Cache, three writers."
  if ! wait_for 90 "AI proposal + fence" has_remediation; then
    fence_rejected && { beat "The fence rejected the proposal"; fence_events Warning | tail -2 | cut -f3 | wrap; }
    note "Retry: ./demo.sh consent · Logs: kubectl get operations · Fall back to the recording"
    return 1
  fi
  echo
  beat "Fence verdict ${DIM}(event on the Cache)${RESET}"
  fence_events Normal | tail -1 | while IFS=$'\t' read -r t r m; do echo "  ${GREEN}${r}${RESET}"; echo "${m}" | wrap; done
  echo
  beat "Desired state, patched"
  echo "  spec.parameters.ardId  ${RED}ARD-010${RESET} → ${GREEN}$(cache_json | jq -r .spec.parameters.ardId)${RESET}"
  echo
  pause
  beat "One Cache, three writers"
  show_writers
  punchline "The AI changed one field, and only because a label said it could."
}

beat_reconcile() {
  banner "5 · Reconcile"
  say "From here it's boring on purpose: the composition finds the group, renders a real Valkey, the Cache goes Ready."
  say "AI thinks. A human consents. The controller reconciles."
  wait_for 60 "Cache Ready" is_ready || { note "Check: crossplane resource trace cache/${CACHE}"; return 1; }
  echo
  kshow get cache "${CACHE}"
  echo
  show_conditions
  echo
  pause
  beat "A real cache, on this laptop"
  echo_cmd "kubectl exec deploy/${CACHE}-valkey -- valkey-cli ping"
  echo "  ${GREEN}$(k exec -n "${NS}" "deploy/${CACHE}-valkey" -- valkey-cli ping 2>&1)${RESET}"
  punchline "AI thinks. A human consents. The controller reconciles."
}

beat_off() {
  banner "Off switch"
  say "And the off switch is just removing the label. The remediation controller no longer sees this Cache."
  kshow label cache "${CACHE}" "${CONSENT}-"
  echo
  note "What remediate-caches can see now:"
  kshow get caches -l "${CONSENT}=true"
  punchline "Revoking consent is one label. Auditable, testable, deterministic."
}

# ---------------------------------------------------------------------------
# Q&A: the fence and the schema, with deliberately bad proposals
# ---------------------------------------------------------------------------

cmd_fence() {
  banner "Q&A · What if the AI goes rogue?"
  beat "Guardrail 1: the schema. A malformed ardId never reaches the controller."
  echo_cmd "kubectl patch cache ${CACHE} --type=merge -p '{\"spec\":{\"parameters\":{\"ardId\":\"ARD-1\"}}}'"
  k patch cache "${CACHE}" -n "${NS}" --type=merge -p '{"spec":{"parameters":{"ardId":"ARD-1"}}}' 2>&1 |
    sed 's/^The Cache "[^"]*" is invalid: //' | wrap 64 | sed "s/^/${RED}/;s/\$/${RESET}/" || true
  echo
  pause
  beat "Guardrail 2: the fence. Three bad proposals, same fence as remediate-caches."
  note "A canned fake-ai step stands in for a misbehaving model."
  note "Target: qa/demo-rogue (stuck, consented, diagnosed)."
  local name
  for name in sku registry hostile; do
    k delete operation "fence-demo-${name}" --ignore-not-found >/dev/null
  done
  k get cache demo-rogue -n qa >/dev/null 2>&1 || k apply -f "${DIR}/tests/fence-demo/rogue-cache.yaml" >/dev/null
  cmd_build
  "${DIR}/tests/fence-demo/render.sh" "${BUILD}" | k apply -f - >/dev/null
  sleep 1
  for name in sku registry hostile; do
    local verdict=""
    local i; for i in $(seq 1 30); do
      verdict=$(op_verdicts "fence-demo-${name}" | tail -1 | cut -f2)
      [[ -n "${verdict}" ]] && break; sleep 0.5
    done
    printf "  %-10s %s\n" "${name}" "$(sed -n "s/^${name}: //p" "${DIR}/tests/fence-demo/proposals.txt")"
    echo "  ${RED}→ ${verdict:-no verdict yet (kubectl get operations)}${RESET}"
  done
  punchline "Guardrails in the API and in code are testable. Guardrails in a prompt are hopes."
}

# ---------------------------------------------------------------------------
# Tests and rehearsal
# ---------------------------------------------------------------------------

cmd_test() {
  cmd_build
  beat "Fence unit tests (Python 3.13, same SDK as function-python)"
  docker image inspect devopsdays-demo-tests >/dev/null 2>&1 ||
    docker build -q -t devopsdays-demo-tests -f "${DIR}/tests/Dockerfile" "${DIR}/tests" >/dev/null
  docker run --rm -v "${DIR}:/src:ro" -e PYTHONDONTWRITEBYTECODE=1 devopsdays-demo-tests -p no:cacheprovider
  beat "Composition render tests"
  "${DIR}/tests/composition/run.sh"
}

cmd_rehearse() {
  local n="${1:-1}" r
  AUTO_SLEEP=0
  for r in $(seq 1 "${n}"); do
    local t0 t_diag t_patch t_ready
    echo "${BOLD}── run ${r}/${n} ──${RESET}"
    t0=$(now)
    cmd_reset
    local tr; tr=$(since "${t0}")
    wait_for 120 "diagnosis" has_diagnosis || { bad "run ${r}: no diagnosis"; return 1; }
    t_diag=$(since "${t0}")
    k label cache "${CACHE}" -n "${NS}" "${CONSENT}=true" >/dev/null
    local tc; tc=$(now)
    wait_for 120 "remediation" has_remediation || { bad "run ${r}: no remediation"; fence_events | tail -2; return 1; }
    t_patch=$(since "${tc}")
    wait_for 60 "Ready" is_ready || { bad "run ${r}: not Ready"; return 1; }
    t_ready=$(since "${t0}")
    k label cache "${CACHE}" -n "${NS}" "${CONSENT}-" >/dev/null
    echo "  reset ${tr}s · diagnosis +${t_diag}s · consent→patch ${t_patch}s · reset→Ready ${t_ready}s"
    echo "  diagnosis: $(ann diagnosis)" | cut -c1-200
    echo "  $(ann auto-remediated)"
    echo "run=${r} reset=${tr} diagnosis=${t_diag} patch=${t_patch} ready=${t_ready} model=$(model_base)" >> "${RUN}/timings.log"
  done
}

# Simulate venue Wi-Fi loss for the cluster: drop all egress from the kind node
# except cluster-internal networks and Ollama on this Mac. (Turn the Mac's
# Wi-Fi off to test the host side too.)
cmd_airplane() {
  local ip; ip=$(host_ip)
  case "${1:-}" in
    on)
      docker exec "${NODE}" sh -c "
        iptables -N DEMO-AIRPLANE 2>/dev/null || iptables -F DEMO-AIRPLANE
        for net in 10.0.0.0/8 172.16.0.0/12 127.0.0.0/8 ${ip}/32; do iptables -A DEMO-AIRPLANE -d \$net -j RETURN; done
        iptables -A DEMO-AIRPLANE -j REJECT
        iptables -C OUTPUT -j DEMO-AIRPLANE 2>/dev/null || iptables -I OUTPUT -j DEMO-AIRPLANE
        iptables -C FORWARD -j DEMO-AIRPLANE 2>/dev/null || iptables -I FORWARD -j DEMO-AIRPLANE"
      if docker exec "${NODE}" curl -fsS -m 3 https://xpkg.crossplane.io >/dev/null 2>&1; then bad "internet still reachable"; else ok "cluster offline (Ollama at ${ip} still allowed)"; fi ;;
    off)
      docker exec "${NODE}" sh -c "
        iptables -D OUTPUT -j DEMO-AIRPLANE 2>/dev/null; iptables -D FORWARD -j DEMO-AIRPLANE 2>/dev/null
        iptables -F DEMO-AIRPLANE 2>/dev/null; iptables -X DEMO-AIRPLANE 2>/dev/null; true"
      ok "cluster online" ;;
    *) echo "usage: ./demo.sh airplane on|off" ;;
  esac
}

# ---------------------------------------------------------------------------
# Guided flow
# ---------------------------------------------------------------------------

# Run a beat; if it fails (a wait timed out), offer retry instead of dying mid-talk.
run_beat() {
  local fn="$1" next="$2" ans
  until "${fn}"; do
    [[ -n "${AUTO_SLEEP}" ]] && return 1
    echo
    read -r -p "${YELLOW}↪ r = retry this beat · ENTER = continue anyway · q = quit ${RESET}" ans
    case "${ans}" in
      r|R) nudge; continue ;;
      q|Q) exit 1 ;;
      *)   break ;;
    esac
  done
  [[ -n "${next}" ]] && pause "next: ${next}"
  return 0
}

cmd_all() {
  banner "Preflight"
  local rc=0; cmd_status || rc=$?
  if (( rc == 2 )); then
    echo; pause "not at start state: ENTER to reset (Ctrl-C to abort)"; cmd_reset
  elif (( rc != 0 )); then
    die "fix the items above first"
  fi
  echo; pause "ENTER to start: 1 · Stuck"
  run_beat beat_stuck     "2 · Explain"
  run_beat beat_explain   "3 · Consent"
  run_beat beat_consent   "4 · Patch"
  run_beat beat_patch     "5 · Reconcile"
  run_beat beat_reconcile "off switch"
  run_beat beat_off       ""
  echo "${BOLD}${GREEN}🎉 Demo complete.${RESET} ${DIM}(./demo.sh fence for Q&A · ./demo.sh reset to rehearse again)${RESET}"
}

case "${1:-all}" in
  all|"")     cmd_all ;;
  up)         cmd_up ;;
  down)       cmd_down ;;
  reset)      cmd_reset ;;
  status)     cmd_status ;;
  build)      cmd_build ;;
  stuck)      beat_stuck ;;
  explain)    beat_explain ;;
  consent)    beat_consent; pause "next: 4 · Patch"; beat_patch ;;
  patch)      beat_patch ;;
  reconcile)  beat_reconcile ;;
  off)        beat_off ;;
  fence)      cmd_fence ;;
  test)       cmd_test ;;
  rehearse)   cmd_rehearse "${2:-1}" ;;
  model)      cmd_model "${2:-}" ;;
  airplane)   cmd_airplane "${2:-}" ;;
  *)          echo "unknown command: $1 (see ./demo.sh --help)" >&2; exit 1 ;;
esac
