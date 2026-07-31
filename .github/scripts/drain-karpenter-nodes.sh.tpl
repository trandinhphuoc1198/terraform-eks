#!/bin/bash
# Deprovisions every Karpenter-managed node before terraform destroy runs.
# See header rationale from the original draft - unchanged. Runs LAST in
# drain-cluster.yml, after drain-loadbalancers.sh.tpl and drain-pvcs.sh.tpl.
#
# Karpenter now runs ON THE MASTER (moved off worker nodes to avoid a
# self-termination race where deleting the node hosting the controller
# would kill the controller mid-drain of the other nodes).
#
# Deletes NodeClaims directly rather than relying on NodePool
# cascade=foreground to propagate - NodeClaim -> EC2 instance is the
# reliable 1:1 relationship (each carries Karpenter's own termination
# finalizer); whether NodeClaims carry a K8s ownerReference back to their
# NodePool (which cascade=foreground depends on) is not something this
# script assumes.
set -uo pipefail
export KUBECONFIG=/home/ec2-user/.kube/config
export PATH=$PATH:/usr/local/bin

CLUSTER_NAME="__CLUSTER_NAME__"

echo "=== Checking for Karpenter CRDs ==="
if ! kubectl get crd nodeclaims.karpenter.sh >/dev/null 2>&1; then
  echo "nodeclaims.karpenter.sh CRD not found - Karpenter not installed. Nothing to drain."
  exit 0
fi

# ── Step 1: stop new provisioning ─────────────────────────────────────────
# Delete NodePools first so Karpenter doesn't immediately replace a
# NodeClaim we're about to delete for a still-Pending pod.
echo "=== Deleting NodePools (stops new node provisioning) ==="
kubectl delete nodepools.karpenter.sh --all --wait=false --ignore-not-found=true || true

# ── Step 2: delete NodeClaims directly, wait for real deletion ───────────
echo "=== Deleting NodeClaims and waiting for Karpenter to terminate the underlying EC2 instances ==="
kubectl delete nodeclaims.karpenter.sh --all --wait=true --timeout=600s || \
  echo "WARNING: not all NodeClaims finished deleting within 600s."

REMAINING=$(kubectl get nodeclaims.karpenter.sh --no-headers 2>/dev/null | wc -l)
if [ "$REMAINING" -eq 0 ]; then
  echo "All Karpenter-managed nodes deprovisioned via the K8s API."
  exit 0
fi

echo "WARNING: $REMAINING NodeClaim(s) still present - controller may be unresponsive."
kubectl get nodeclaims.karpenter.sh

# ── Step 3: hard AWS-side fallback ─────────────────────────────────────────
# Only reachable if the graceful path above didn't clear everything -
# e.g. Karpenter's controller crash-looped, or (bug) got deleted out from
# under us by an earlier ArgoCD deregistration step. Requires the master's
# IAM role to carry ec2:TerminateInstances scoped to this cluster's tag.
echo "=== Falling back to direct EC2 termination for any instance still tagged for this cluster's Karpenter nodepools ==="
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

STRAY_IDS=$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
            "Name=tag-key,Values=karpenter.sh/nodepool" \
            "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || true)

if [ -z "$STRAY_IDS" ]; then
  echo "No stray Karpenter-tagged instances found via AWS API - nothing to force-terminate."
  exit 0
fi

echo "Force-terminating: $STRAY_IDS"
aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids $STRAY_IDS || \
  echo "WARNING: terminate-instances call failed - check the master role's IAM permissions and these instances' tags manually."

exit 0