# 5. Apply the Recommendations

The workflow computed the requests; now they go into the cluster. In the original workshop this was
a pull request on your fork. Here `applyRecommendations` does the same change in place: it runs the
workflow's query for your cluster, and for every opted-in container patches the workload's CPU and
memory **requests** (raising the memory limit where the new request would exceed it). Kubernetes
then rolls the pods with the new values.

Look once more at what will change, then apply it:

```bash
showRecommendations
applyRecommendations
```

Each patched workload is annotated with what was applied and when, so the change is traceable:

```bash
kubectl get deployments,statefulsets -n otel-demo \
  -o custom-columns='WORKLOAD:.metadata.name,CPU REQUEST:.spec.template.spec.containers[0].resources.requests.cpu,MEMORY REQUEST:.spec.template.spec.containers[0].resources.requests.memory,APPLIED AT:.metadata.annotations.resource-optimization\.dynatrace\.com/applied-at'
```

This check proves the workloads now run with the recommended requests — a CPU request on every
container and the `applied-at` annotation, neither of which the manifests had:

<!-- LAB_QUESTION
type: shell-verification
question: "Verify the otel-demo workloads run with the recommended requests"
buttonText: "Check applied requests"
command: "checkRecommendationsApplied"
expect:
  operator: exit-zero
hint: "Run `applyRecommendations`. If it says there are no recommendations yet, Dynatrace needs a few more minutes of usage data — wait and run it again."
explanation: "The requests now come from measured usage. Kubernetes rolled the pods with the new values."
-->

<!-- LAB_SOLUTION
reveal: |
  Run `applyRecommendations` in the terminal. It runs the workflow's Smartscape query for your
  cluster and patches each opted-in workload's CPU and memory requests with `kubectl patch`.
commands:
  - applyRecommendations
verify:
  - LAB_WAIT=1 checkRecommendationsApplied
-->

<!-- LAB_QUESTION
type: multiple-choice
question: "What happens to a running pod when its Deployment's resource requests change?"
options:
  - "Kubernetes replaces it with a new pod that has the new requests (a rolling update)"
  - "The running pod's requests change in place, without a restart"
  - "Nothing until the node is restarted"
  - "The pod is deleted and not replaced"
correct: 0
explanation: "Requests are part of the pod template; changing the template triggers a rolling update of the workload's pods."
-->

<!-- checklist [ ] human-apply-fail-first: checkRecommendationsApplied fails on a fresh environment and passes after applyRecommendations -->
