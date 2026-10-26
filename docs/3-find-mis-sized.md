# 3. Find the Mis-sized Workloads

A request is a reservation: the scheduler sets that much CPU and memory aside for the pod whether it
uses it or not. Requested too high, you pay for idle capacity; too low (or not at all), pods are
packed onto nodes that cannot serve them under load. Dynatrace knows both sides — the requests from
the Kubernetes API and the real usage from the container metrics — so the gap is one query away.

## Usage against requests, per container

Open a Notebook in your tenant and run:

```dql
timeseries {
    mem_used = max(dt.kubernetes.container.memory_working_set),
    mem_requested = sum(dt.kubernetes.container.requests_memory),
    cpu_used = max(dt.kubernetes.container.cpu_usage)
  },
  by:{k8s.workload.name, k8s.container.name},
  filter: endsWith(k8s.cluster.name, "{{DT_SESSION_ID}}") AND k8s.namespace.name == "otel-demo",
  from:now()-30m
| filter k8s.container.name == k8s.workload.name
| fieldsAdd mem_used_p95_MiB = arrayPercentile(mem_used, 95) / 1048576,
            mem_requested_MiB = arrayAvg(mem_requested) / 1048576,
            cpu_used_p95_millicores = arrayPercentile(cpu_used, 95)
| fieldsAdd memory_used_pct_of_request = mem_used_p95_MiB / mem_requested_MiB * 100
| fields k8s.workload.name, mem_used_p95_MiB, mem_requested_MiB, memory_used_pct_of_request, cpu_used_p95_millicores
| sort memory_used_pct_of_request desc
```

Read the result:

- **`memory_used_pct_of_request` above 100** — the container uses more than it reserved. The node
  is over-committed; under pressure, these pods are the first to be evicted.
- **Far below 100** — reserved and idle.
- **CPU** has no request at all yet, so every millicore used is unreserved.

The `k8s.container.name == k8s.workload.name` line keeps the application container of each pod and
drops the `dynatrace-operator` init container the DynaKube injects, whose own small requests would
otherwise be added in.

The workflow you run next uses the same metrics, over **7 days** and through **Smartscape**: it walks
from each container to its pod and its workload, keeps only workloads annotated
`resource-optimization.dynatrace.com/enabled: "true"`, and recommends **p95 usage × 1.30** — usage
plus 30 % headroom.

!!! tip "The upstream notebook"
    The original workshop ships a notebook, *Smartscape Resource allocation*, with these queries and
    charts. It is in this repository as `dynatrace/smartscape-resource-allocation.notebook.json`; to
    use it, download it and choose **Upload** in the Notebooks app. Its queries are not scoped to
    your cluster: in a shared tenant you see every learner's workloads.

This check proves Dynatrace has your containers' usage and memory requests — the inputs of every
recommendation:

<!-- LAB_QUESTION
type: dql-verification
question: "Verify Dynatrace has usage and memory requests for your otel-demo workloads"
buttonText: "Check usage data"
dql: |
  timeseries { used = max(dt.kubernetes.container.memory_working_set), requested = sum(dt.kubernetes.container.requests_memory) }, by:{k8s.workload.name}, filter: endsWith(k8s.cluster.name, "{{DT_SESSION_ID}}") AND k8s.namespace.name == "otel-demo", from:now()-30m
  | filter isNotNull(arrayLast(used)) AND isNotNull(arrayLast(requested))
  | summarize count = count()
expect:
  operator: gte
  field: count
  value: 5
hint: "The ActiveGate reports container metrics every minute; a fresh cluster needs a few minutes. Wait and check again."
explanation: "Usage and requests are in Grail for your workloads — the optimizer has what it needs."
-->

<!-- LAB_QUESTION
type: multiple-choice
question: "A container's p95 memory usage is 80 MiB. What memory request does the optimizer recommend?"
options:
  - "104 MiB — p95 usage plus 30 % headroom"
  - "80 MiB — exactly the p95 usage"
  - "160 MiB — twice the usage"
  - "It keeps the current request"
correct: 0
explanation: "Recommended = p95 usage × 1.30: enough headroom for spikes above the 95th percentile without reserving idle capacity."
-->

<!-- LAB_NO_SOLUTION: read-only step — queries only; nothing in the environment changes -->
