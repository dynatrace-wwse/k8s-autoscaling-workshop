# 1. Check the Environment

Your environment already runs everything the upstream workshop's bootstrap built: a Kubernetes
cluster, the Dynatrace Operator with a DynaKube, an OpenTelemetry Collector and
`opentelemetry-demo-light` under constant load from k6. This step makes sure all of it is up
before you start optimizing.

## The demo application

Look at the eight workloads of the demo, and at the resources each container **requests**:

```bash
kubectl get pods -n otel-demo
kubectl get deployments,statefulsets -n otel-demo \
  -o custom-columns='WORKLOAD:.metadata.name,CPU REQUEST:.spec.template.spec.containers[0].resources.requests.cpu,MEMORY REQUEST:.spec.template.spec.containers[0].resources.requests.memory'
```

Every workload requests a little memory and **no CPU at all**. The scheduler places pods by their
requests, so these numbers decide how many pods fit on a node — whatever the pods actually use.
Keep this table in mind: in step 4 you replace these guesses with numbers measured by Dynatrace.

Each workload also carries the annotation `resource-optimization.dynatrace.com/enabled: "true"`.
That is the opt-in the optimizer looks for — workloads without it are never touched:

```bash
kubectl get deployment cart -n otel-demo -o jsonpath='{.metadata.annotations}' ; echo
```

The check below proves the demo app `post-create.sh` deployed is running — every one of its eight
workloads has a `Running` pod (and so the cluster under it is up):

<!-- LAB_QUESTION
type: shell-verification
question: "Verify all eight otel-demo-light workloads are Running"
buttonText: "Check the demo app"
command: "checkOtelDemoRunning"
expect:
  operator: exit-zero
hint: "The demo pulls eight images on first start. Wait a minute, watch `kubectl get pods -n otel-demo`, then check again."
explanation: "frontend, cart, checkout, payment, product-catalog, postgres, valkey and the k6 load generator are all Running."
-->

## The OpenTelemetry Collector

The demo's services are instrumented with OpenTelemetry and send OTLP to a collector in namespace
`otel-collector`. It runs as a **DaemonSet** — one collector per node — because besides OTLP it also
reads every container's log files from the node it runs on (`/var/log/pods`, the `filelog`
receiver). Look at its pipeline:

```bash
kubectl get ds -n otel-collector
kubectl get cm otel-collector-config -n otel-collector -o jsonpath='{.data.config\.yaml}' | grep -A3 'pipelines:' -m1 ; \
kubectl get cm otel-collector-config -n otel-collector -o jsonpath='{.data.config\.yaml}' | sed -n '/^    logs:/,/exporters/p'
```

- `k8sattributes` adds the pod, workload and namespace — and the `resource-optimization` annotation —
  to every span, metric and log.
- `cumulativetodelta` converts cumulative counters to the delta temporality Dynatrace ingests.
- `otlp_http` exports to your Dynatrace tenant with an ingest token that never left the cluster's
  Secret.

This check proves the collector is running on every node:

<!-- LAB_QUESTION
type: shell-verification
question: "Verify the OpenTelemetry Collector DaemonSet is ready on every node"
buttonText: "Check the collector"
command: "checkCollectorRunning"
expect:
  operator: exit-zero
hint: "Run `kubectl get pods -n otel-collector`. If a pod is not Running, read its log with `kubectl logs -n otel-collector ds/otel-collector --tail=50`."
explanation: "One collector per node is ready: OTLP and pod logs flow to Dynatrace."
-->

<!-- LAB_QUESTION
type: multiple-choice
question: "Why does this workshop run the collector as a DaemonSet instead of a single Deployment?"
options:
  - "Each collector reads the log files of the pods on its own node from /var/log/pods"
  - "OTLP can only be received by a DaemonSet"
  - "A Deployment cannot export to Dynatrace"
  - "The Dynatrace Operator requires it"
correct: 0
explanation: "Container logs are files on the node. A filelog receiver must run on every node to read them; OTLP alone would work with a Deployment."
-->

## Dynatrace in the cluster

The Operator deployed a DynaKube in **Kubernetes monitoring** mode: an ActiveGate watches the
Kubernetes API and reports the cluster, its workloads and every container's CPU and memory usage
and requests to Dynatrace. Nothing is injected into the demo pods — they are observed through
OpenTelemetry only.

```bash
kubectl get dynakube -n dynatrace
kubectl get pods -n dynatrace
```

This check proves the ActiveGate is up — without it, Smartscape and the container metrics the
recommendations are computed from never reach your tenant:

<!-- LAB_QUESTION
type: shell-verification
question: "Verify the ActiveGate is Running in the dynatrace namespace"
buttonText: "Check ActiveGate"
command: "checkActiveGateReady"
expect:
  operator: exit-zero
hint: "The ActiveGate starts a minute or two after the DynaKube. Watch `kubectl get pods -n dynatrace` and check again."
explanation: "The ActiveGate is connected: Smartscape and the Kubernetes container metrics reach your tenant."
-->

<!-- LAB_NO_SOLUTION: environment check — post-create.sh built everything; nothing for the learner to change -->

<!-- checklist [ ] author-step-1-checks: Step 1 checks only what post-create.sh builds -->
