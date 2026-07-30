#!/bin/bash
# Deletes every namespace that currently owns a PersistentVolumeClaim, then
# waits for those PVCs to fully disappear.
#
# WHY NAMESPACE DELETE, NOT `kubectl delete pvc`:
#   A PVC carries the kubernetes.io/pvc-protection finalizer, which only
#   clears once no Pod is still using it. kube-prometheus-stack's
#   Prometheus/Grafana and Tempo's ingester are StatefulSets/Deployments -
#   their pods are still running at this point, so `kubectl delete pvc`
#   alone just leaves it stuck in Terminating forever: the pod never gets
#   torn down, the volume attachment never releases, the finalizer never
#   clears, and the aws-ebs-csi-driver never reaches the point of calling
#   DeleteVolume on the real AWS resource.
#
#   Deleting the whole namespace cascades pod termination first, which
#   releases the volume attachment, which lets the finalizer chain run to
#   completion: PVC finalizer clears -> PV finalizer clears -> CSI driver
#   issues DeleteVolume. This only works because platform/values/spoke/
#   ebs-csi.yaml sets reclaimPolicy: Delete on the ebs-csi StorageClass.
#
# CAVEAT - ArgoCD self-heal race:
#   If this spoke/hub is still registered with ArgoCD and its Applications
#   have selfHeal: true, ArgoCD *could* try to recreate a deleted namespace
#   mid-drain. It can't successfully create resources into a Terminating
#   namespace, so this mostly just delays things rather than corrupting the
#   drain - but if you want to eliminate the race entirely, deregister the
#   cluster from ArgoCD (delete argocd/clusters/<name>.yaml + the cluster
#   Secret) BEFORE running this, so ArgoCD prunes everything itself first.
#
# Always exits 0 - a stuck PVC should not block terraform destroy from
# proceeding. The caller (GitHub Actions step) surfaces the warning.
set -uo pipefail
export KUBECONFIG=/home/ec2-user/.kube/config
export PATH=$PATH:/usr/local/bin

echo "=== Discovering namespaces with PersistentVolumeClaims ==="
NS_LIST=$(kubectl get pvc --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)

if [ -z "$NS_LIST" ]; then
  echo "No PVCs found on this cluster - nothing to drain."
  exit 0
fi

echo "Namespaces with PVCs: $(echo "$NS_LIST" | tr '\n' ' ')"

for ns in $NS_LIST; do
  echo "Deleting namespace: $ns (cascades pod -> PVC -> PV -> EBS volume deletion)"
  kubectl delete namespace "$ns" --wait=false || true
done

echo "=== Waiting for PVCs to fully terminate (up to 8 minutes) ==="
for i in $(seq 1 48); do
  REMAINING=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)
  if [ "$REMAINING" -eq 0 ]; then
    echo "All PVCs cleaned up - their backing EBS volumes have been deleted."
    exit 0
  fi
  echo "  $REMAINING PVC(s) still terminating (attempt $i/48)..."
  sleep 10
done

echo "WARNING: some PVCs are still stuck after 8 minutes:"
kubectl get pvc --all-namespaces
echo "Their backing EBS volumes may be orphaned once terraform destroy removes the nodes."
echo "Check the AWS Console/CLI for volumes tagged ebs.csi.aws.com/cluster=true and delete manually if needed."
exit 0
