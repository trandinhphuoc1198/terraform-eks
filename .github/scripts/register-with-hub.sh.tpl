#!/bin/bash
set -euo pipefail
export KUBECONFIG=/home/ec2-user/.kube/config
export PATH=$PATH:/usr/local/bin

CLUSTER_NAME="__CLUSTER_NAME__"
CLUSTER_ROLE="__CLUSTER_ROLE__"
ENV="__ENV__"

echo "=== Creating argocd-manager service account ==="
kubectl create namespace argocd-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount argocd-manager -n argocd-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding argocd-manager-binding \
  --clusterrole=cluster-admin \
  --serviceaccount=argocd-manager:argocd-manager \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Rotation script, installed on the host (not a k8s CronJob - see note
# in the PR/commit message on why: avoids relying on IMDS hop-limit being
# locked down for pod-level credential isolation) ─────────────────────────
cat <<ROTATE > /usr/local/bin/push-argocd-registration.sh
#!/bin/bash
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
IMDS_TOKEN=\$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=\$(curl -s -H "X-aws-ec2-metadata-token: \$IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
MASTER_IP=\$(curl -s -H "X-aws-ec2-metadata-token: \$IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

TOKEN=\$(kubectl create token argocd-manager -n argocd-manager --duration=2160h)
CA_DATA=\$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
SECRET_NAME="argocd-clusters/${CLUSTER_NAME}"
SERVER_URL="https://\$MASTER_IP:6443"

PAYLOAD=\$(jq -n \\
  --arg name "${CLUSTER_NAME}" \\
  --arg role "${CLUSTER_ROLE}" \\
  --arg server "\$SERVER_URL" \\
  --arg token "\$TOKEN" \\
  --arg ca "\$CA_DATA" \\
  '{name:\$name, role:\$role, server:\$server, token:\$token, caData:\$ca}')

aws secretsmanager put-secret-value \\
  --secret-id "\$SECRET_NAME" \\
  --secret-string "\$PAYLOAD" \\
  --region "\$AWS_REGION" 2>/dev/null || \\
aws secretsmanager create-secret \\
  --name "\$SECRET_NAME" \\
  --secret-string "\$PAYLOAD" \\
  --tags Key=ManagedBy,Value=k8s-bootstrap Key=ClusterName,Value=${CLUSTER_NAME} Key=ClusterRole,Value=${CLUSTER_ROLE} Key=Purpose,Value=argocd-registration \\
  --region "\$AWS_REGION"
ROTATE
chmod +x /usr/local/bin/push-argocd-registration.sh

echo "=== Pushing initial registration ==="
/usr/local/bin/push-argocd-registration.sh

echo "=== Installing rotation timer (every 30 days) ==="
cat <<TIMERUNIT > /etc/systemd/system/argocd-registration-rotate.timer
[Unit]
Description=Rotate argocd-manager token every 30 days
[Timer]
OnCalendar=*-*-1..28/30 03:00:00
Persistent=true
[Install]
WantedBy=timers.target
TIMERUNIT

cat <<SERVICEUNIT > /etc/systemd/system/argocd-registration-rotate.service
[Unit]
Description=Push refreshed argocd-manager token to Secrets Manager
[Service]
Type=oneshot
ExecStart=/usr/local/bin/push-argocd-registration.sh
SERVICEUNIT

systemctl daemon-reload
systemctl enable --now argocd-registration-rotate.timer
