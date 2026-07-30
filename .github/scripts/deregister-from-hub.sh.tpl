#!/bin/bash
# Fully deregisters one spoke cluster from ArgoCD, run ON THE HUB MASTER.
#
# Exits non-zero on any step that can't be confirmed - this script is
# intentionally NOT tolerant of failure. The whole point of running it
# before destroy-spoke's PVC drain is to guarantee no ArgoCD controller can
# recreate anything on the spoke while that drain is in progress. A partial
# failure here means that guarantee doesn't hold, so the caller should stop
# rather than proceed.
#
# Order matters and is deliberate:
#   0. Remove ArgoCD's OWN control over cluster registration first:
#      delete the `root-clusters` Application with --cascade=orphan. This
#      is what actually stops the resurrection race - `root-clusters`
#      watches argocd/clusters/*.yaml in git and reconciles the
#      ExternalSecret for EVERY registered cluster (selfHeal: true), so as
#      long as it's alive it will recreate whatever we delete in step 1
#      within its own reconcile loop (observed as fast as immediately, not
#      on ESO's 5m refreshInterval - ESO isn't the thing recreating it,
#      ArgoCD is). --cascade=orphan removes only the Application object,
#      NOT the resources it created - so every OTHER spoke's ExternalSecret/
#      Secret (still managed the same way) is left alone and keeps working
#      via ESO's own controller, just without ArgoCD drift-correction on it
#      until root-clusters is re-applied. This script deliberately does NOT
#      re-apply root-clusters itself - see the destroy-spoke.yml workflow
#      for that, added as a step AFTER terraform-destroy-spoke, only when
#      the hub is expected to survive this teardown. Re-applying it here
#      would just race the drain step that runs immediately after this
#      script.
#   1. Delete the ExternalSecret (+ its generated Secret) for THIS cluster
#      only. With root-clusters gone, nothing can regenerate it anymore.
#   2. Only once the cluster is gone from ArgoCD's inventory do we delete
#      the generated Applications - otherwise every spokes/ ApplicationSet
#      (selfHeal: true) can regenerate an Application faster than this
#      script deletes the previous one. (These ApplicationSets are separate
#      from root-clusters and are untouched by step 0.)
#   3. Applications are deleted in REVERSE sync-wave order, discovered
#      dynamically from each Application's own
#      argocd.argoproj.io/sync-wave annotation (every spokes/ ApplicationSet
#      template stamps this on generated Applications already) - so this
#      script needs no manual, hand-maintained list of release names.
#      Adding/removing an ApplicationSet under argocd/spokes/ never requires
#      touching this script.
#   4. CNI (cilium-*) / CSI (aws-ebs-csi-driver-*) / other node-critical
#      infra is excluded from this script's deletion entirely -
#      drain-pvcs.sh (run after this script) needs a live CSI controller and
#      live pod networking on the spoke to issue real EBS DeleteVolume calls
#      and let pods unmount cleanly. Delete those separately, later.
set -uo pipefail
export KUBECONFIG=/home/ec2-user/.kube/config
export PATH=$PATH:/usr/local/bin

CLUSTER_NAME="__CLUSTER_NAME__"

# release-name prefixes this script will NOT touch - node-critical infra
# that must stay alive on the spoke until drain-pvcs.sh has run. Add more
# here (e.g. "aws-cloud-controller-manager") if you want them held back too.
EXCLUDED_RELEASES=(
  "cilium"
  "aws-ebs-csi-driver"
  "aws-cloud-controller-manager"
)

echo "=== Deregistering cluster: $CLUSTER_NAME ==="

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }

# ── Step 0: stop root-clusters from being able to resurrect anything ───────
# --cascade=orphan: removes the Application object only. Everything it
# created (every spoke's ExternalSecret/Secret, including ones we are NOT
# touching right now) is left in place and keeps functioning independently
# via the external-secrets-operator controller - it just stops being
# drift-corrected by ArgoCD until root-clusters is re-applied.
echo "--- Removing root-clusters Application (cascade=orphan) so nothing can resurrect the ExternalSecret ---"
if kubectl get application root-clusters -n argocd >/dev/null 2>&1; then
  kubectl delete application root-clusters -n argocd --cascade=orphan --wait=true --timeout=60s || {
    echo "ERROR: failed to delete application/root-clusters." >&2
    exit 1
  }

  echo "--- Verifying root-clusters Application is actually gone ---"
  for i in $(seq 1 12); do
    if ! kubectl get application root-clusters -n argocd >/dev/null 2>&1; then
      echo "Confirmed: root-clusters Application removed - nothing can regenerate cluster ExternalSecrets now."
      break
    fi
    if [ "$i" -eq 12 ]; then
      echo "ERROR: root-clusters Application still present after 60s." >&2
      exit 1
    fi
    sleep 5
  done
else
  echo "root-clusters Application not found - already removed (e.g. a previous run got this far). Continuing."
fi

# ── Step 1: delete the ExternalSecret (and its generated Secret) ───────────
# Safe now - with root-clusters gone, nothing reconciles this manifest back
# from git. ESO's own refreshInterval only re-syncs an EXISTING
# ExternalSecret's value from Secrets Manager; it does not recreate a
# deleted ExternalSecret object, so this deletion sticks.
echo "--- Deleting ExternalSecret + generated Secret ---"
EXTSECRET_NAME=$(kubectl get externalsecret -n argocd -o json 2>/dev/null \
  | jq -r --arg cn "$CLUSTER_NAME" '.items[] | select(.spec.dataFrom[]?.extract.key // "" | test($cn)) | .metadata.name' \
  | head -n1)

# Fallback: naming convention - every ExternalSecret in argocd/clusters/ is
# named after the cluster today.
if [ -z "$EXTSECRET_NAME" ]; then
  EXTSECRET_NAME=$(kubectl get externalsecret -n argocd -o name 2>/dev/null | grep -- "/${CLUSTER_NAME}$" | sed 's#.*/##' || true)
fi

if [ -z "$EXTSECRET_NAME" ]; then
  echo "No ExternalSecret found matching cluster ${CLUSTER_NAME}. Skipping (may already be deleted)."
else
  echo "Deleting ExternalSecret/${EXTSECRET_NAME}..."
  kubectl delete externalsecret -n argocd "$EXTSECRET_NAME" --wait=true --timeout=60s || {
    echo "ERROR: failed to delete ExternalSecret/${EXTSECRET_NAME}." >&2
    exit 1
  }
fi

kubectl delete secret -n argocd -l "cluster-name=${CLUSTER_NAME}" --ignore-not-found=true --wait=true --timeout=60s

echo "--- Verifying the cluster is gone from ArgoCD's inventory ---"
STILL_THERE=$(kubectl get secret -n argocd -l "cluster-name=${CLUSTER_NAME}" --no-headers 2>/dev/null | wc -l)
if [ "$STILL_THERE" -ne 0 ]; then
  echo "ERROR: cluster registration Secret still present after delete." >&2
  exit 1
fi
echo "Confirmed: cluster no longer in ArgoCD's inventory. No generator can recreate Applications for it now."

# ── Step 2: delete every Application ArgoCD generated for this spoke ───────
# Discovered dynamically and sorted by descending sync-wave (highest wave -
# e.g. fastapi-app at 50 - deleted first; lowest - e.g. cilium at 00 -
# deleted last / excluded), so no hardcoded release list to maintain.
is_excluded() {
  local release="$1"
  for ex in "${EXCLUDED_RELEASES[@]}"; do
    [ "$release" = "$ex" ] && return 0
  done
  return 1
}

echo "--- Discovering Applications targeting this cluster (sorted by descending sync-wave) ---"
APP_LIST=$(kubectl get applications -n argocd -o json 2>/dev/null | jq -r --arg cn "$CLUSTER_NAME" '
  [ .items[]
    | select(.metadata.name | endswith("-" + $cn))
    | { name: .metadata.name,
        wave: ((.metadata.annotations["argocd.argoproj.io/sync-wave"] // "-1") | tonumber) }
  ]
  | sort_by(-.wave)
  | .[].name
')

if [ -z "$APP_LIST" ]; then
  echo "No Applications found for cluster ${CLUSTER_NAME}."
else
  echo "Deletion order:"
  echo "$APP_LIST"
  echo

  for app in $APP_LIST; do
    release="${app%-${CLUSTER_NAME}}"

    if is_excluded "$release"; then
      echo "Skipping ${app} (excluded - node-critical infra, delete after drain-pvcs.sh)"
      continue
    fi

    echo "Deleting application.argoproj.io/${app} (cascade=foreground - this can take a few minutes)..."
    kubectl delete application "$app" -n argocd --cascade=foreground --ignore-not-found=true --wait=true --timeout=600s || {
      echo "ERROR: failed to fully delete ${app} within timeout." >&2
      exit 1
    }
  done
fi

echo "--- Verifying no non-excluded Applications remain for this cluster ---"
REMAINING=$(kubectl get applications -n argocd -o name 2>/dev/null | grep -- "-${CLUSTER_NAME}$" || true)
UNEXPECTED=""
for app_path in $REMAINING; do
  app_name=$(echo "$app_path" | sed 's#.*/##')
  release="${app_name%-${CLUSTER_NAME}}"
  if ! is_excluded "$release"; then
    UNEXPECTED="${UNEXPECTED}${app_name}\n"
  fi
done

if [ -n "$UNEXPECTED" ]; then
  echo "ERROR: unexpected Applications still present after delete:" >&2
  echo -e "$UNEXPECTED" >&2
  exit 1
fi

echo "=== Deregistration complete: $CLUSTER_NAME is no longer tracked by ArgoCD ==="
echo "root-clusters Application was removed (cascade=orphan) to stop it recreating this cluster's ExternalSecret."
echo "If the hub survives this teardown and other spokes remain registered, re-apply it manually or via a"
echo "follow-up workflow step once this spoke's terraform destroy has finished:"
echo "  kubectl apply -f \$GITOPS_REPO_RAW_URL/argocd/root-apps/root-clusters.yaml"
echo
echo "Excluded and left running on purpose (delete these AFTER drain-pvcs.sh):"
for release in "${EXCLUDED_RELEASES[@]}"; do
  app="${release}-${CLUSTER_NAME}"
  kubectl get application "$app" -n argocd >/dev/null 2>&1 && echo "  - $app"
done
echo
echo "Note: any PersistentVolumeClaim created via a StatefulSet volumeClaimTemplate"
echo "(Prometheus, Tempo ingester) is NOT deleted by this step - Kubernetes"
echo "deliberately leaves those unowned so they survive pod recreation. They are"
echo "simply idle now (no pod holds them). The drain-pvcs.sh step that runs next"
echo "is what actually deletes them and triggers the EBS DeleteVolume calls."
echo "Run drain-pvcs.sh now, THEN manually delete: ${EXCLUDED_RELEASES[*]/%/-$CLUSTER_NAME}"