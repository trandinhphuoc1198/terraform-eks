#!/bin/bash
# Scales ArgoCD's own controllers on THIS cluster to 0 before this same
# job's drain-pvcs.sh / drain-loadbalancers.sh steps run.
set -uo pipefail

# Fallback to default path if KUBECONFIG is not already exported
export KUBECONFIG="${KUBECONFIG:-/home/ec2-user/.kube/config}"
export PATH=$PATH:/usr/local/bin

ARGOCD_NAMESPACE="__ARGOCD_NAMESPACE__"

echo "=== Freezing ArgoCD controllers in namespace ${ARGOCD_NAMESPACE} ==="

FROZE_ANY=false

# 1. Scale ApplicationSet controller if present
if kubectl get deployment argocd-applicationset-controller -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  echo "Scaling deployment/argocd-applicationset-controller to 0..."
  if kubectl scale deployment argocd-applicationset-controller -n "$ARGOCD_NAMESPACE" --replicas=0; then
    FROZE_ANY=true
  fi
fi

# 2. Scale Application controller (Deployment or StatefulSet)
if kubectl get deployment argocd-application-controller -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  echo "Scaling deployment/argocd-application-controller to 0..."
  if kubectl scale deployment argocd-application-controller -n "$ARGOCD_NAMESPACE" --replicas=0; then
    FROZE_ANY=true
  fi
elif kubectl get statefulset argocd-application-controller -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  echo "Scaling statefulset/argocd-application-controller to 0..."
  if kubectl scale statefulset argocd-application-controller -n "$ARGOCD_NAMESPACE" --replicas=0; then
    FROZE_ANY=true
  fi
fi

if [ "$FROZE_ANY" = false ]; then
  echo "WARNING: No argocd-application-controller or argocd-applicationset-controller workload found in ${ARGOCD_NAMESPACE} - nothing to freeze."
  exit 0
fi

echo "=== Waiting for controller pod(s) to terminate (up to 90s) ==="

# Native kubectl wait for both controllers to fully delete their pods
if kubectl wait --for=delete pod \
  -l 'app.kubernetes.io/name in (argocd-application-controller, argocd-applicationset-controller)' \
  -n "$ARGOCD_NAMESPACE" \
  --timeout=90s 2>/dev/null; then
  echo "ArgoCD controllers are fully scaled down - selfHeal can no longer race this drain."
  exit 0
else
  echo "WARNING: Controller pod(s) still present after 90s - selfHeal may still be active. Proceeding with drain anyway (best-effort)."
  exit 0
fi