#!/bin/bash
# Load framework
source .devcontainer/util/source_framework.sh

printInfoSection "Running integration Tests for $RepositoryName"

# What post-create.sh builds
assertRunningPod dynatrace operator
assertRunningPod dynatrace activegate
assertRunningPod otel-collector otel-collector
for w in frontend cart checkout payment product-catalog postgres valkey load-generator; do
  assertRunningPod otel-demo "$w"
done
assertRunningApp otel-demo-light

LAB_WAIT=1 checkOtelDemoRunning || exit 1
LAB_WAIT=1 checkCollectorRunning || exit 1

# Step 5's check must FAIL before its solution: the manifests ship no CPU requests
# and no applied annotation.
if checkRecommendationsApplied; then
  printError "checkRecommendationsApplied passed before applyRecommendations ran — the check cannot fail"
  exit 1
fi
