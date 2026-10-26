# K8s Autoscaling Workshop

[![Dynatrace](https://img.shields.io/badge/Dynatrace-Enablement-purple?logo=dynatrace&logoColor=white)](https://dynatrace-wwse.github.io/k8s-autoscaling-workshop/)

Right-size Kubernetes workloads with Dynatrace **Smartscape**, **DQL** and a **Workflow**: find the
workloads whose CPU and memory requests do not match what they use, compute new requests from
7-day p95 usage, apply them and watch the gap between *requested* and *used* shrink.

📖 **Workshop:** <https://dynatrace-wwse.github.io/k8s-autoscaling-workshop/>

## Credits

This workshop was created by **[Henrik Rexed](https://github.com/henrikrexed)** —
[henrikrexed/K8s-autoscalingWorkshop](https://github.com/henrikrexed/K8s-autoscalingWorkshop), with his
[opentelemetry-demo-light](https://github.com/henrikrexed/opentelemetry-demo-light) as the workload.
This repository migrates it to the [Dynatrace enablement framework](https://github.com/dynatrace-wwse/codespaces-framework)
so that it runs as a training in the Dynatrace Enablement app (and still in a GitHub Codespace).
The workshop, its manifests, collector configuration, workflow query and images are his work; the
changes are listed below.

## TODO — for Henrik

Tracked in the issue **“Henrik: confirm licence and review the migration”** of this repository.

- [ ] **Licence.** Neither `K8s-autoscalingWorkshop` nor `opentelemetry-demo-light` carries a licence.
      This repository is published under Apache-2.0 (the framework's licence) with attribution.
      Please confirm that is fine for both — ideally by adding Apache-2.0 to the two upstream repos.
- [ ] **Accuracy.** Walk the six steps once and check every statement and command against what your
      workshop intends.
- [ ] **Deviations.** Review the list below and say which ones you want changed.

## What changed from the original

| Area | Original | Here | Why |
|---|---|---|---|
| Container | `mcr.microsoft.com/devcontainers/base` + features | framework image `shinojosa/dt-enablement` | runs the same in Codespaces, Dev Containers and Orbital |
| Cluster | `kind` (`kind/cluster.yaml`) | `k3d` (`startK3dCluster`) | kind does not run in Orbital's Sysbox containers |
| Secrets | attendee pastes `DT_OPERATOR_TOKEN`, `DT_API_TOKEN`, `DT_ENVIRONMENT_ID/TYPE` | minted per learner by the Enablement app | no token handling by learners |
| Service prefix | `OTEL_SERVICE_PREFIX` typed by each attendee | learner's session id | unique per learner without input |
| DynaKube | `dynatrace/dynakube.yaml` (ActiveGate k8s-monitoring + routing, apponly on `oneagent=true` namespaces, feature annotations) | framework-generated (`generateDynakube`), mode `k8s-only` via `.devcontainer/yaml/dynakube-config.yaml` | the framework's DynaKube is the standard; k8s-only matches the original's "no injection into the demo" |
| Collector | own DaemonSet, `otel/opentelemetry-collector-contrib:0.103.0` | framework `deployOtelCollector` (Dynatrace distribution) as DaemonSet with pod logs, config in `.devcontainer/yaml/otel-collector.yaml` | framework standard; config ported (OTLP, filelog, k8sattributes incl. the annotation, cumulativetodelta) |
| filelog parsing | hand-written docker/crio/containerd router | the `container` operator | same result, maintained upstream |
| Workflow | DQL → patch manifests → commit to the fork → open a PR | DQL → compute recommendations; filtered to the learner's cluster; GitHub tasks removed | owner decision: no fork, no GitHub token |
| Apply | merge the PR | `applyRecommendations` runs the same DQL and `kubectl patch`es the requests | in-cluster apply |
| Annotations | `github-repo`, `github-rep`, `github-path`, `github-branch`, rewritten by `rewrite-annotations.sh` | removed; `resource-optimization.dynatrace.com/enabled` kept | no fork to point at |
| Frontend service | `NodePort 30080` | `ClusterIP` + framework ingress (`registerApp`) | framework exposes apps through ingress |
| Notebook | pre-provisioned on the trial tenant | shipped as `dynatrace/smartscape-resource-allocation.notebook.json` for upload | not every tenant has it |
| Docs | `docs/` + `dynatrace/launchpad.md` | six steps with checks, quizzes, solutions and an assessment | Enablement app training format |

## Repository layout

```text
.devcontainer/
  post-create.sh              builds the environment: k3d, Operator + DynaKube, collector, demo
  util/my_functions.sh        everything workshop-specific (deploy, checks, recommendations)
  yaml/otel-collector.yaml    the collector config handed to deployOtelCollector
  yaml/dynakube-config.yaml   DynaKube override: mode k8s-only
otel-demo-light/              the demo's manifests (kustomize)
dynatrace/                    workflow template + notebook
docs/                         the training (MkDocs; each nav entry is a step in the app)
.assessment/                  the final assessment
```

## Run it

- **Enablement app:** import `dynatrace-wwse/k8s-autoscaling-workshop` and press Start.
- **Codespace:** set the secrets `DT_ENVIRONMENT`, `DT_OPERATOR_TOKEN`, `DT_INGEST_TOKEN` (and, for
  `applyRecommendations`, `DT_DTCTL_TOKEN`) and create a Codespace — 4 cores.

## Licence

Apache-2.0 — see [LICENSE](LICENSE). Original work © Henrik Rexed; see *Credits* and *TODO* above.
