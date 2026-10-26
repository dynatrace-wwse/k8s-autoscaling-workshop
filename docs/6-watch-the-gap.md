# 6. Watch the Gap Shrink

The pods now reserve what they use plus headroom. Dynatrace sees the new requests within a minute or
two. Run the query from step 3 again, or this one, which shows CPU requests appear on the app
containers and memory requests move toward usage:

```dql
timeseries {
    cpu_requested = sum(dt.kubernetes.container.requests_cpu),
    cpu_used = max(dt.kubernetes.container.cpu_usage),
    mem_requested = sum(dt.kubernetes.container.requests_memory),
    mem_used = max(dt.kubernetes.container.memory_working_set)
  },
  by:{k8s.workload.name, k8s.container.name},
  filter: endsWith(k8s.cluster.name, "{{DT_SESSION_ID}}") AND k8s.namespace.name == "otel-demo",
  from:now()-1h
| filter k8s.container.name == k8s.workload.name
```

The last line keeps the application containers. Each pod also runs a short `dynatrace-operator` init
container, injected by the DynaKube, which requests 30m CPU of its own: left in, it makes every
workload look as if it had a CPU request all along.

Switch the result to a line chart: for each workload, *requested* steps to just above *used* at the
moment you applied the recommendations.

This check proves Dynatrace now reports CPU requests on your application containers — before step 5
they had none:

<!-- LAB_QUESTION
type: dql-verification
question: "Verify Dynatrace reports the new CPU requests of your otel-demo workloads"
buttonText: "Check new requests"
dql: |
  timeseries cpu_requested = sum(dt.kubernetes.container.requests_cpu), by:{k8s.workload.name, k8s.container.name}, filter: endsWith(k8s.cluster.name, "{{DT_SESSION_ID}}") AND k8s.namespace.name == "otel-demo", from:now()-10m
  | filter k8s.container.name == k8s.workload.name
  | filter arrayLast(cpu_requested) > 0
  | summarize count = count()
expect:
  operator: gte
  field: count
  value: 1
hint: "The ActiveGate reports the new requests within a minute or two of the rollout. Make sure step 5 passed, wait, then check again."
explanation: "Dynatrace sees the right-sized requests: the gap between requested and used is closed."
-->

## Where to go from here

- **Schedule the workflow.** Give it a daily trigger and it keeps recommending as the load changes.
- **GitOps.** The original workshop let the workflow open a pull request with the patched manifests —
  in production, that review step is what keeps a human in the loop.
- **Autoscaling.** Right-sized requests are what Horizontal Pod Autoscalers and cluster autoscalers
  scale on: wrong requests make them scale at the wrong time.

<!-- LAB_QUESTIONAIRE: k8s-autoscaling-workshop retake=false -->

<!-- LAB_NO_SOLUTION: observation step — step 5 made the change; nothing more in the environment changes -->
