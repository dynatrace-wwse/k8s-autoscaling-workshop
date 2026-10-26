#!/bin/bash
# Builds the K8s Autoscaling Workshop environment:
#   k3d cluster -> Dynatrace Operator + DynaKube (k8s-only) -> OpenTelemetry
#   Collector (DaemonSet, pod logs) -> opentelemetry-demo-light with k6 load.
# The learner's work (finding, computing and applying the recommendations) is in
# the steps, not here.
export SECONDS=0
source .devcontainer/util/source_framework.sh

# Orbital mints these into .devcontainer/.env; Codespaces asks for them as secrets.
variablesNeeded DT_ENVIRONMENT:true DT_OPERATOR_TOKEN:true DT_INGEST_TOKEN:true || exit 1

setUpTerminal

startK3dCluster

installK9s

dynatraceDeployOperator

deployDynatrace

deployWorkshopCollector

deployOtelDemoLight

finalizePostCreation

printInfoSection "Your dev container finished creating"
