# 2. See Your Telemetry in Dynatrace

Two independent paths bring your cluster into Dynatrace:

- the **OpenTelemetry Collector** ships the demo's traces, metrics and logs, and
- the **Operator's ActiveGate** reports the Kubernetes objects (Smartscape) and the container CPU and
  memory metrics the optimization is computed from.

Every learner of a workshop shares one tenant, so each query below keeps only **your** cluster: its
name ends with your session id, `{{DT_SESSION_ID}}`.

## Traces from the demo

Open a Notebook in your tenant and run:

```dql
fetch spans, from:now()-15m
| filter endsWith(k8s.cluster.name, "{{DT_SESSION_ID}}")
| filter k8s.namespace.name == "otel-demo"
| summarize spans = count(), by:{service.name}
| sort spans desc
```

Every service of the demo shows up, named `{{DT_SESSION_ID}}-cart`, `{{DT_SESSION_ID}}-checkout`
and so on — the session id prefix keeps them apart from your classmates' services. This check
proves the collector exported spans from your cluster:

<!-- LAB_QUESTION
type: dql-verification
question: "Verify the demo's spans from your cluster reached Grail"
buttonText: "Check spans"
dql: |
  fetch spans, from:now()-15m
  | filter endsWith(k8s.cluster.name, "{{DT_SESSION_ID}}")
  | filter k8s.namespace.name == "otel-demo"
  | summarize count = count()
expect:
  operator: gte
  field: count
  value: 1
hint: "Spans arrive a minute or two after the demo starts. If none come, read the collector's log: `kubectl logs -n otel-collector ds/otel-collector --tail=50`."
explanation: "Your cluster's spans are in Grail, enriched with the Kubernetes cluster name by the collector."
-->

## Pod logs through the filelog receiver

The collector also reads every container's log file on the node. Those logs carry the file they came
from — the proof they were collected by `filelog`, not sent by an SDK:

```dql
fetch logs, from:now()-15m
| filter endsWith(k8s.cluster.name, "{{DT_SESSION_ID}}")
| filter isNotNull(log.file.path)
| summarize lines = count(), by:{k8s.namespace.name}
| sort lines desc
```

This check proves pod logs from your cluster reached Grail through the collector:

<!-- LAB_QUESTION
type: dql-verification
question: "Verify pod logs read by the collector's filelog receiver reached Grail"
buttonText: "Check pod logs"
dql: |
  fetch logs, from:now()-15m
  | filter endsWith(k8s.cluster.name, "{{DT_SESSION_ID}}")
  | filter k8s.namespace.name == "otel-demo"
  | filter isNotNull(log.file.path)
  | summarize count = count()
expect:
  operator: gte
  field: count
  value: 1
hint: "The filelog receiver starts at the end of each file, so only new lines are shipped. The demo logs continuously; wait a minute and check again."
explanation: "Container logs from your node are in Grail, with the Kubernetes metadata the collector attached."
-->

<!-- LAB_QUESTION
type: multiple-choice
question: "Which component reports the containers' CPU and memory requests that the optimizer compares with usage?"
options:
  - "The ActiveGate deployed by the Dynatrace Operator (Kubernetes monitoring)"
  - "The k6 load generator"
  - "The filelog receiver of the OpenTelemetry Collector"
  - "Each demo service's OpenTelemetry SDK"
correct: 0
explanation: "Requests are Kubernetes object data. The ActiveGate reads them from the Kubernetes API, together with the container usage metrics, and feeds Smartscape."
-->

<!-- LAB_NO_SOLUTION: read-only step — the telemetry was set up by post-create.sh; nothing changes -->
