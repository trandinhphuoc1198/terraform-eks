#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/k8s-bootstrap.log) 2>&1

export PATH=$PATH:/usr/local/bin
echo 'alias k=kubectl' >> /home/ec2-user/.bashrc

# ── CNI/CCM installation toggle ───────────────────────────────────────────
# Hub installs Cilium + AWS CCM directly, below - Argo CD needs a working
# pod network and a cleared uninitialized taint before it can run at all,
# so the hub can't outsource its own bootstrap to Argo CD (chicken-and-egg).
#
# Spokes set install_cni_ccm=false (modules/k8s var, wired from
# live/spoke/main.tf): Cilium + AWS CCM are installed later by Argo CD's
# own ApplicationSet on the hub, once this spoke pushes its registration
# secret (k8s-register-with-hub.yml). The hub's Argo CD reaches this
# spoke's apiserver directly over the TGW (trusted_api_cidr_blocks) - a
# hostNetwork control-plane path that doesn't need this node's pod network
# up first. Until that sync lands, this node stays NotReady and tainted
# node.cloudprovider.kubernetes.io/uninitialized - expected and harmless,
# since nothing except CNI/CCM's own DaemonSets (which carry matching
# tolerations) needs to schedule here before that.
INSTALL_CNI_CCM="${install_cni_ccm}"
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

# ── Create Kubeadm Cluster Configuration ─────────────────────────────────
cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: "${k8s_version}"
controllerManager:
  extraArgs:
    cloud-provider: "external"
    bind-address: "0.0.0.0"
scheduler:
  extraArgs:
    bind-address: "0.0.0.0"
etcd:
  local:
    extraArgs:
      listen-metrics-urls: "http://127.0.0.1:2381,http://$PRIVATE_IP:2381"
networking:
  podSubnet: "${pod_cidr}"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
systemReserved:
  memory: "100Mi"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
skipPhases:
  - addon/kube-proxy
localAPIEndpoint:
  advertiseAddress: "$PRIVATE_IP"
  bindPort: 6443
nodeRegistration:
  kubeletExtraArgs:
    cloud-provider: "external"
EOF

# ── Run kubeadm init ──────────────────────────────────────────────────────
kubeadm init --config=/tmp/kubeadm-config.yaml 2>&1 | tee /var/log/kubeadm-init.log

# ── kubectl setup for ec2-user ────────────────────────────────────────────
mkdir -p /home/ec2-user/.kube
cp /etc/kubernetes/admin.conf /home/ec2-user/.kube/config
chown ec2-user:ec2-user /home/ec2-user/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

# ── Wait for apiserver to be consistently reachable ───────────────────────
# kubeadm init can finish with a brief window where the apiserver is still
# cycling (e.g. kubelet restarting to pick up the rotated client cert in
# [kubelet-finalize]). Racing straight into `helm install` against it can
# hit a transient "connection refused" / GOAWAY. Wait for a stable
# response before proceeding.
echo "=== Waiting for apiserver to be consistently reachable ===" >> /var/log/kubeadm-init.log
for i in $(seq 1 30); do
  if kubectl get --raw='/readyz' >/dev/null 2>&1; then
    echo "apiserver is ready (attempt $i)" >> /var/log/kubeadm-init.log
    break
  fi
  echo "apiserver not ready yet, retrying in 5s (attempt $i/30)..." >> /var/log/kubeadm-init.log
  sleep 5
done

# ── CNI ─────────────────────────────────────────────────────────────────
# Unconditional - every cluster (hub and spoke) needs pod networking to
# reach Ready, regardless of whether it also runs Argo CD/CCM/ESO.
#
# routingMode=native (was tunnel): pod traffic between nodes is no longer
# VXLAN-encapsulated. Nodes span multiple AZs/subnets (not L2-adjacent),
# so autoDirectNodeRoutes stays off - cross-node pod routing depends on
# the AWS CCM route controller installed below keeping the VPC route
# table in sync with each node's podCIDR. See
# platform/values/base/cilium.yaml for the full rationale; this inline
# install just needs to match those values for day-0 bootstrap, since
# ArgoCD only takes over reconciliation afterward.
if [ "$INSTALL_CNI_CCM" = "true" ]; then
  echo "=== Installing CNI ===" >> /var/log/kubeadm-init.log
  helm repo add cilium https://helm.cilium.io/
  helm repo update

  for i in $(seq 1 5); do
    helm upgrade --install cilium cilium/cilium \
    --version "1.16.0" \
    --namespace kube-system \
    --create-namespace \
    --set operator.replicas=1 \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="$PRIVATE_IP" \
    --set k8sServicePort="6443" \
    --set routingMode=native \
    --set ipv4NativeRoutingCIDR="${pod_cidr_supernet}" \
    --set autoDirectNodeRoutes=false \
    --set ipam.mode=kubernetes \
    --set ipam.operator.clusterPoolIPv4PodCIDRList="${pod_cidr}" \
    --set nodePort.enabled=true \
    --set nodePort.range="30000\,32767" \
    --set bpf.masquerade=true \
    --set enableIPv4Masquerade=true \
    --set enableIPv6Masquerade=false \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.cpu=500m \
    --set resources.limits.memory=256Mi \
    --set identityAllocationMode=crd \
    --set encryption.enabled=true \
    --set encryption.type=wireguard \
    --set rollOutCiliumPods=true \
    --wait \
    --timeout=10m && break
    echo "Cilium install attempt $i failed, retrying in 10s..." >> /var/log/kubeadm-init.log
    sleep 10
  done
else
  echo "=== Skipping CNI install (install_cni_ccm=false) - Argo CD installs Cilium on this cluster from the hub ===" >> /var/log/kubeadm-init.log
fi

# ── AWS Cloud Controller Manager ──────────────────────────────────────────
# Unconditional - every node registers with cloud-provider=external, so every
# node (hub and spoke, master and workers) carries the
# node.cloudprovider.kubernetes.io/uninitialized:NoSchedule taint until CCM
# runs and clears it. This MUST happen before anything else tries to
# schedule - including Argo CD's own pods, which is why this can't be an
# Argo CD Application (Argo CD's chart ships no toleration for this taint;
# CNI's DaemonSet does, which is why CNI is safe to apply before this step).
#
# --configure-cloud-routes=true (was false): with Cilium routingMode=native
# above, this is what actually makes cross-AZ pod traffic routable - CCM's
# route controller watches node.spec.podCIDR and syncs the matching route
# into the VPC route table modules/vpc tags with
# kubernetes.io/cluster/<cluster_name> (master's IAM role
# - master_ccm_policy in modules/ec2/main.tf - is scoped to that same tag).
# --cluster-cidr is required for the route controller to start.
if [ "$INSTALL_CNI_CCM" = "true" ]; then
  echo "=== Installing AWS CCM ===" >> /var/log/kubeadm-init.log
  helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
  helm repo update
  helm upgrade --install aws-cloud-controller-manager aws-cloud-controller-manager/aws-cloud-controller-manager \
    --namespace kube-system \
    --set 'args={--v=2,--cloud-provider=aws,--configure-cloud-routes=true,--cluster-cidr=${pod_cidr}}'

  echo "=== Waiting for uninitialized taint to clear ===" >> /var/log/kubeadm-init.log
  timeout 120 bash -c 'until ! kubectl get nodes -o json | grep -q "node.cloudprovider.kubernetes.io/uninitialized"; do sleep 5; done'

  echo "=== Waiting for node to become Ready ===" >> /var/log/kubeadm-init.log
  kubectl wait node --all --for=condition=Ready --timeout=180s
else
  echo "=== Skipping AWS CCM install and node-Ready wait (install_cni_ccm=false) ===" >> /var/log/kubeadm-init.log
  echo "This node will stay NotReady and tainted until Argo CD (hub) syncs Cilium + CCM after registration." >> /var/log/kubeadm-init.log
fi
# ── Join-token push script + rotation timer ──────────────────────────────
# This is the only "hand-off" Terraform-owned bootstrap needs to make: it
# publishes what a worker needs to join. Everything past "node is Ready"
# (CCM, Argo CD, ESO, hub registration) is intentionally NOT here anymore -
# see modules/k8s/README.md for where each of those now lives.

echo "=== Installing join-token push script ===" >> /var/log/kubeadm-init.log
cat <<'PUSHTOKEN' > /usr/local/bin/push-join-token.sh
#!/bin/bash
set -euo pipefail
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)

TOKEN=$(kubeadm token create --ttl 24h)
CA_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | sha256sum | awk '{print $1}')
API_ENDPOINT="$PRIVATE_IP:6443"

JOIN_PAYLOAD=$(jq -n \
  --arg tok "$TOKEN" \
  --arg hash "sha256:$CA_HASH" \
  --arg ep "$API_ENDPOINT" \
  '{token: $tok, ca_hash: $hash, endpoint: $ep}')

aws ssm put-parameter \
  --name "/${env}/k8s/join_token" \
  --value "$JOIN_PAYLOAD" \
  --type "SecureString" \
  --overwrite \
  --region "$AWS_REGION"
PUSHTOKEN
chmod +x /usr/local/bin/push-join-token.sh

echo "=== Pushing initial JSON join payload to SSM ===" >> /var/log/kubeadm-init.log
/usr/local/bin/push-join-token.sh

echo "=== Installing join-token rotation timer (every 8h; token TTL is 24h) ===" >> /var/log/kubeadm-init.log
cat <<TIMERUNIT > /etc/systemd/system/k8s-join-token-rotate.timer
[Unit]
Description=Refresh the kubeadm join token pushed to SSM (TTL is 24h; refresh well inside that window so a late Cluster Autoscaler scale-out never reads an expired token)
[Timer]
OnBootSec=8h
OnUnitActiveSec=8h
Persistent=true
[Install]
WantedBy=timers.target
TIMERUNIT

cat <<SERVICEUNIT > /etc/systemd/system/k8s-join-token-rotate.service
[Unit]
Description=Push a refreshed kubeadm join token to SSM
[Service]
Type=oneshot
ExecStart=/usr/local/bin/push-join-token.sh
SERVICEUNIT

systemctl daemon-reload
systemctl enable --now k8s-join-token-rotate.timer
