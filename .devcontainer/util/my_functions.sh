#!/bin/bash
# ======================================================================
#          ------- K8s Autoscaling Workshop functions -------          #
#  Everything specific to this workshop lives here; the framework's    #
#  functions.sh stays untouched. Sourced into every shell (Codespaces, #
#  Dev Containers and Orbital), so a function here can be called from #
#  post-create.sh, the terminal, a shell-verification `command:` and a #
#  LAB_SOLUTION.                                                       #
#                                                                      #
#  Ported from Henrik Rexed's K8s-autoscalingWorkshop                  #
#  (github.com/henrikrexed/K8s-autoscalingWorkshop): deployment.sh and #
#  the Smart K8s Resource Optimizer workflow. The workflow opened a    #
#  pull request on the attendee's fork; here applyRecommendations runs #
#  the same DQL and applies the new requests in the cluster.           #
#                                                                      #
#  Rules: `return`, never `exit`; idempotent; a check returns 0 = pass,#
#  probes once for a click and waits first only when LAB_WAIT is set.  #
# ======================================================================

OTEL_DEMO_NS="${OTEL_DEMO_NS:-otel-demo}"
# Workloads the recommendations may touch: the demo's, nothing else.
OTEL_DEMO_WORKLOADS="cart checkout frontend payment product-catalog postgres valkey load-generator"

# ----------------------------------------------------------------------
#  Identity
# ----------------------------------------------------------------------

# workshopClusterName — the name Dynatrace knows this cluster by: the DynaKube's
# name, which the framework builds as <repo part>-<session id>. Every DQL in the
# workshop filters with endsWith(k8s.cluster.name, <session id>), so the OTel
# data the collector sends carries the same name.
workshopClusterName() {
  local name
  name=$(kubectl get dynakube -n dynatrace -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$name" ]; then
    name="$(getDtSessionId)"
    [ -n "$name" ] || name="$(echo "${RepositoryName:-k8s-autoscaling-workshop}" | tr '[:upper:]' '[:lower:]')"
  fi
  echo "$name"
}

# The session id the DQL filters on (endsWith). Falls back to the cluster name
# when there is no session (a local run).
workshopSessionFilter() {
  local sid
  sid="$(getDtSessionId)"
  [ -n "$sid" ] && echo "$sid" || workshopClusterName
}

# ----------------------------------------------------------------------
#  Environment (post-create.sh)
# ----------------------------------------------------------------------

# deployWorkshopCollector — the framework collector (deployOtelCollector) as a
# DaemonSet that also reads pod logs, with this workshop's config.
deployWorkshopCollector() {
  local src="$REPO_PATH/.devcontainer/yaml/otel-collector.yaml"
  local gen="$REPO_PATH/.devcontainer/yaml/gen/otel-collector.yaml"
  local cluster
  cluster="$(workshopClusterName)"
  mkdir -p "$(dirname "$gen")"
  sed "s|CLUSTER_NAME_TO_REPLACE|${cluster}|" "$src" > "$gen" || return 1
  printInfo "Collector config rendered for cluster '$cluster'"
  OTEL_COLLECTOR_MODE=daemonset OTEL_COLLECTOR_POD_LOGS=true OTEL_COLLECTOR_CONFIG_FILE="$gen" \
    deployOtelCollector
}

# deployOtelDemoLight — opentelemetry-demo-light (frontend, cart, checkout,
# payment, product-catalog, postgres, valkey and a k6 load generator) into
# namespace otel-demo, sending OTLP to the collector. Service names carry the
# session id as prefix so learners on one tenant do not collide.
deployOtelDemoLight() {
  local prefix sid
  sid="$(getDtSessionId)"
  prefix="${OTEL_SERVICE_PREFIX:-${sid:+${sid}-}}"
  printInfoSection "Deploying opentelemetry-demo-light (namespace $OTEL_DEMO_NS, service prefix '${prefix}')"
  kubectl kustomize "$REPO_PATH/otel-demo-light" \
    | sed "s|OTEL_SERVICE_PREFIX_TO_REPLACE|${prefix}|g" \
    | kubectl apply -f - >/dev/null || { printError "Could not apply otel-demo-light"; return 1; }
  waitForAllReadyPods "$OTEL_DEMO_NS"
  registerApp otel-demo-light "$OTEL_DEMO_NS" frontend 8080
}

# ----------------------------------------------------------------------
#  Checks
# ----------------------------------------------------------------------

# Every otel-demo-light workload has a Running pod (step 1).
checkOtelDemoRunning() {
  local want=8 running i=0
  if [ -n "${LAB_WAIT:-}" ]; then
    while [ "$i" -lt 36 ]; do
      running=$(kubectl get pods -n "$OTEL_DEMO_NS" --no-headers 2>/dev/null | grep -c " Running ")
      [ "$running" -ge "$want" ] && break
      i=$((i + 1)); printInfo "$running/$want otel-demo pods Running ($i/36), waiting 5s"; sleep 5
    done
  fi
  running=$(kubectl get pods -n "$OTEL_DEMO_NS" --no-headers 2>/dev/null | grep -c " Running ")
  if [ "$running" -ge "$want" ]; then
    printInfo "All $want otel-demo-light workloads are Running"; return 0
  fi
  printError "Only $running of $want otel-demo-light pods are Running — the environment may still be starting"
  return 1
}

# One collector per node is Running (step 1).
checkCollectorRunning() {
  local ns="${OTEL_COLLECTOR_NAMESPACE:-otel-collector}" want ready
  [ -n "${LAB_WAIT:-}" ] && kubectl -n "$ns" rollout status ds/otel-collector --timeout=180s >/dev/null 2>&1
  want=$(kubectl -n "$ns" get ds otel-collector -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
  ready=$(kubectl -n "$ns" get ds otel-collector -o jsonpath='{.status.numberReady}' 2>/dev/null)
  if [ -n "$want" ] && [ "$want" -gt 0 ] && [ "$ready" = "$want" ]; then
    printInfo "OpenTelemetry Collector DaemonSet: $ready/$want ready"; return 0
  fi
  printError "OpenTelemetry Collector DaemonSet not ready (${ready:-0}/${want:-?})"
  return 1
}

# ----------------------------------------------------------------------
#  Recommendations — the workflow's DQL, run from the container
# ----------------------------------------------------------------------

# The workflow's collect_underutilized_workloads query, scoped to this learner's
# cluster (the tenant may be shared). $1 = session filter. 7-day p95; a young
# cluster simply has less history. Recommended = p95 usage x 1.30.
# The CPU request is looked up on its own: a timeseries over several metrics only
# returns containers that have ALL of them, and the demo's containers have no CPU
# request — in one timeseries (as upstream) every one of them dropped out.
# Requests are avg, not sum: the 7-day query rolls up to 1-hour buckets, and a sum
# there adds up every sample of the hour (100Mi read as 6000Mi).
_recommendationsDql() {
  cat <<DQLEOF
smartscapeNodes CONTAINER
| fieldsRename containername = name
| traverse is_part_of, K8S_POD, fieldsKeep:{id, containername}
| fieldsAdd podname = k8s.pod.name, podid = id
| traverse is_part_of, K8S_DEPLOYMENT, fieldsKeep:{podname, podid}
| fieldsAdd podname = dt.traverse.history[1][podname], podid = dt.traverse.history[1][podid], containername = dt.traverse.history[0][containername], containerid = dt.traverse.history[0][id]
| filter endsWith(k8s.cluster.name, "$1")
| filter k8s.namespace.name == "$OTEL_DEMO_NS"
| fieldsAdd optimization = if(isNotNull(\`tags:k8s.annotations\`[\`resource-optimization.dynatrace.com/enabled\`]), \`tags:k8s.annotations\`[\`resource-optimization.dynatrace.com/enabled\`], else: "false")
| filter optimization == "true"
| lookup [
    timeseries memusagevalues = max(dt.kubernetes.container.memory_working_set), memrequest_value = avg(dt.kubernetes.container.requests_memory), cpusagevalues = max(dt.kubernetes.container.cpu_usage), by:{dt.smartscape.container}, from: -7d
    | fieldsAdd request_memory = arrayPercentile(memrequest_value, 95), usage_memory = arrayPercentile(memusagevalues, 95), usage_cpu = arrayPercentile(cpusagevalues, 95)
  ], sourceField:containerid, lookupField:dt.smartscape.container, fields:{usage_memory, request_memory, usage_cpu}
| lookup [
    timeseries cpurequest_value = avg(dt.kubernetes.container.requests_cpu), by:{dt.smartscape.container}, from: -7d
    | fieldsAdd request_cpu = arrayPercentile(cpurequest_value, 95)
  ], sourceField:containerid, lookupField:dt.smartscape.container, fields:{request_cpu}
| filter isNotNull(usage_memory) AND isNotNull(usage_cpu)
| fieldsAdd memratio = if(request_memory > 0, usage_memory / request_memory * 100), cpuratio = if(request_cpu > 0, usage_cpu / request_cpu * 100)
| fieldsAdd cpurecommended = usage_cpu * 1.30, memoryrecommended = usage_memory * 1.30
| summarize containers = collectArray(record(containername, cpurecommended, memoryrecommended, request_cpu, request_memory, cpuratio, memratio)), by:{workloadname = k8s.workload.name}
DQLEOF
}

# _dqlQuery <dql> — runs a DQL query with the seat's read token and prints the
# result JSON. The token travels in a header read from a file descriptor, never
# in argv or output. Token: $DQL_TOKEN_VAR (default DT_DTCTL_TOKEN — minted on
# every Orbital seat with the Grail and Smartscape read scopes).
_dqlQuery() {
  local q="$1" var="${DQL_TOKEN_VAR:-DT_DTCTL_TOKEN}" tok body out code token tries=0
  eval "tok=\${$var}"
  if [ -z "$tok" ] || [ -z "$DT_ENVIRONMENT" ]; then
    printError "No DQL token: $var and DT_ENVIRONMENT must be set (Orbital sets both). Locally, put a platform token with storage:*:read and storage:smartscape:read in $var." >&2
    return 1
  fi
  body=$(jq -nc --arg q "$q" '{query: $q, requestTimeoutMilliseconds: 60000, maxResultRecords: 1000}')
  out=$(mktemp) || return 1
  code=$(curl -sS --max-time 90 -o "$out" -w '%{http_code}' -X POST \
    -H @<(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$tok") \
    --data-binary @<(printf '%s' "$body") "${DT_ENVIRONMENT%/}/platform/storage/query/v1/query:execute" 2>/dev/null)
  while [ "$code" = 202 ] || { [ "$code" = 200 ] && [ "$(jq -r '.state // "SUCCEEDED"' "$out")" = RUNNING ]; }; do
    token=$(jq -r '.requestToken // empty' "$out")
    [ -n "$token" ] && [ "$tries" -lt 60 ] || break
    tries=$((tries + 1)); sleep 2
    code=$(curl -sS --max-time 60 -o "$out" -w '%{http_code}' \
      -H @<(printf 'Authorization: Bearer %s\n' "$tok") \
      "${DT_ENVIRONMENT%/}/platform/storage/query/v1/query:poll?request-token=$(jq -rn --arg t "$token" '$t|@uri')" 2>/dev/null)
  done
  if [ "$code" != 200 ]; then
    printError "DQL query failed (HTTP ${code:-000}): $(jq -r '.error.message // .message // empty' "$out" 2>/dev/null | head -c 300)" >&2
    rm -f "$out"; return 1
  fi
  jq -c '.result.records // []' "$out"; rm -f "$out"
}

# _recommendationRows — one TSV line per container:
# workload  container  new_cpu_m  new_mem_Mi  request_cpu_m  request_mem_Mi
_recommendationRows() {
  local recs
  recs=$(_dqlQuery "$(_recommendationsDql "$(workshopSessionFilter)")") || return 1
  printf '%s' "$recs" | jq -r '
    .[] | .workloadname as $w | .containers[] |
    [ $w, .containername,
      ((.cpurecommended // 0) | tonumber | ceil),
      (((.memoryrecommended // 0) | tonumber) / 1048576 | ceil),
      ((.request_cpu // 0) | tonumber | round),
      (((.request_memory // 0) | tonumber) / 1048576 | round) ] | @tsv'
}

# showRecommendations — what the Smart K8s Resource Optimizer workflow
# computes, for your cluster: p95 usage over the last 7 days x 1.30 per container.
showRecommendations() {
  local rows
  printInfoSection "Resource recommendations for your cluster (p95 usage x 1.30)"
  rows=$(_recommendationRows) || return 1
  if [ -z "$rows" ]; then
    printWarn "No recommendations yet — Dynatrace needs a few minutes of usage metrics for your workloads. Try again shortly."
    return 1
  fi
  printf '%-16s %-16s %12s %12s %14s %14s\n' WORKLOAD CONTAINER "CPU now (m)" "CPU new (m)" "Memory now(Mi)" "Memory new(Mi)"
  printf '%s\n' "$rows" | while IFS=$'\t' read -r w c ncpu nmem rcpu rmem; do
    printf '%-16s %-16s %12s %12s %14s %14s\n' "$w" "$c" "$rcpu" "$ncpu" "$rmem" "$nmem"
  done
}

# applyRecommendations — applies the recommended requests to the demo's
# Deployments/StatefulSets in the cluster (the step the workflow's pull request
# did on the fork). Memory limits are raised when the new request would exceed
# them. Each patched workload is annotated with what was applied and when.
applyRecommendations() {
  local rows applied=0 w c ncpu nmem kind limit limit_mi patch
  printInfoSection "Applying the recommended requests in namespace $OTEL_DEMO_NS"
  rows=$(_recommendationRows) || return 1
  if [ -z "$rows" ]; then
    printWarn "No recommendations yet — Dynatrace needs a few minutes of usage metrics. Run showRecommendations again shortly."
    return 1
  fi
  while IFS=$'\t' read -r w c ncpu nmem _ _; do
    case " $OTEL_DEMO_WORKLOADS " in *" $w "*) ;; *) continue ;; esac
    [ "$ncpu" -ge 1 ] 2>/dev/null || ncpu=1
    [ "$nmem" -ge 4 ] 2>/dev/null || nmem=4
    kind=""
    kubectl -n "$OTEL_DEMO_NS" get deployment "$w" >/dev/null 2>&1 && kind=deployment
    [ -z "$kind" ] && kubectl -n "$OTEL_DEMO_NS" get statefulset "$w" >/dev/null 2>&1 && kind=statefulset
    [ -n "$kind" ] || { printWarn "  $w: not found in $OTEL_DEMO_NS, skipped"; continue; }
    limit=$(kubectl -n "$OTEL_DEMO_NS" get "$kind" "$w" -o json \
      | jq -r --arg c "$c" '.spec.template.spec.containers[] | select(.name == $c) | .resources.limits.memory // empty')
    limit_mi=$(_toMi "$limit")
    patch=$(jq -nc --arg c "$c" --arg cpu "${ncpu}m" --arg mem "${nmem}Mi" \
      '{spec:{template:{spec:{containers:[{name:$c, resources:{requests:{cpu:$cpu, memory:$mem}}}]}}}}')
    if [ -n "$limit_mi" ] && [ "$nmem" -gt "$limit_mi" ]; then
      patch=$(printf '%s' "$patch" | jq -c --arg l "$((nmem * 2))Mi" '.spec.template.spec.containers[0].resources.limits = {memory: $l}')
    fi
    if kubectl -n "$OTEL_DEMO_NS" patch "$kind" "$w" --type strategic -p "$patch" >/dev/null; then
      kubectl -n "$OTEL_DEMO_NS" annotate "$kind" "$w" --overwrite \
        "resource-optimization.dynatrace.com/applied=cpu=${ncpu}m,memory=${nmem}Mi" \
        "resource-optimization.dynatrace.com/applied-at=$(date -u +%FT%TZ)" >/dev/null
      printInfo "  $kind/$w [$c]: requests cpu=${ncpu}m memory=${nmem}Mi"
      applied=$((applied + 1))
    else
      printError "  $kind/$w [$c]: patch failed"
    fi
  done <<< "$rows"
  [ "$applied" -gt 0 ] || { printError "No workload was patched"; return 1; }
  printInfo "$applied container(s) patched — Kubernetes rolls the pods with the new requests"
  # $(...) so zsh (the learner's shell) splits the list as bash does
  for w in $(echo "$OTEL_DEMO_WORKLOADS"); do
    kubectl -n "$OTEL_DEMO_NS" rollout status deployment "$w" --timeout=180s >/dev/null 2>&1 \
      || kubectl -n "$OTEL_DEMO_NS" rollout status statefulset "$w" --timeout=180s >/dev/null 2>&1
  done
  return 0
}

# _toMi <quantity> — a Kubernetes memory quantity in Mi (integer), empty if unset.
_toMi() {
  local q="$1"
  case "$q" in
    "") echo "" ;;
    *Gi) echo $(( ${q%Gi} * 1024 )) ;;
    *Mi) echo "${q%Mi}" ;;
    *Ki) echo $(( ${q%Ki} / 1024 )) ;;
    *G) echo $(( ${q%G} * 1000000000 / 1048576 )) ;;
    *M) echo $(( ${q%M} * 1000000 / 1048576 )) ;;
    *) echo $(( q / 1048576 )) ;;
  esac
}

# Every demo workload carries a CPU request and the applied annotation (step 5).
# Fails before applyRecommendations: the manifests ship memory requests only.
checkRecommendationsApplied() {
  local i=0 n
  _appliedCount() {
    kubectl -n "$OTEL_DEMO_NS" get deployments,statefulsets -o json 2>/dev/null | jq '[.items[]
      | select(.metadata.annotations["resource-optimization.dynatrace.com/applied-at"] != null)
      | select([.spec.template.spec.containers[].resources.requests.cpu] | all(. != null))] | length'
  }
  if [ -n "${LAB_WAIT:-}" ]; then
    while [ "$i" -lt 24 ]; do
      n=$(_appliedCount); [ "${n:-0}" -ge 1 ] && break
      i=$((i + 1)); sleep 5
    done
  fi
  n=$(_appliedCount)
  if [ "${n:-0}" -ge 1 ]; then
    printInfo "$n workload(s) run with the recommended requests"
    kubectl -n "$OTEL_DEMO_NS" get deployments,statefulsets \
      -o custom-columns='WORKLOAD:.metadata.name,APPLIED:.metadata.annotations.resource-optimization\.dynatrace\.com/applied' 2>/dev/null
    return 0
  fi
  printError "No workload carries the recommended requests yet — run applyRecommendations"
  return 1
}

# ----------------------------------------------------------------------
#  Workflow file for the "see it in Dynatrace" step
# ----------------------------------------------------------------------

# generateWorkflow — writes the Smart K8s Resource Optimizer workflow for upload
# in the Workflows app, scoped to YOUR cluster, to .devcontainer/yaml/gen/.
generateWorkflow() {
  local src="$REPO_PATH/dynatrace/smart-resource-optimizer.workflow-template.yaml"
  local gen="$REPO_PATH/.devcontainer/yaml/gen/smart-resource-optimizer.workflow.yaml"
  local sid
  sid="$(workshopSessionFilter)"
  mkdir -p "$(dirname "$gen")"
  sed -e "s|SESSION_ID_TO_REPLACE|${sid}|g" "$src" > "$gen" || return 1
  printInfo "Workflow for your cluster written to: ${gen#"$REPO_PATH"/}"
}
