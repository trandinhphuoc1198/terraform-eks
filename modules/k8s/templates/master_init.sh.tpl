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

# ── IRSA role ARNs for the two day-0 workloads ────────────────────────────
# NEW - as of moving cilium-operator and aws-ccm off the node instance
# profile and onto IRSA. Both roles already exist for the ArgoCD-managed
# steady state (platform/values/hub/cilium.yaml's operator.extraEnv,
# platform/values/hub/aws-ccm.yaml's env) - this just wires the SAME two
# role ARNs into the inline day-0 install below, since neither
# pod-identity-webhook nor ArgoCD exists yet at this point in the
# bootstrap. Must be passed in via the Terraform templatefile() call that
# renders this script (e.g. module.irsa.roles["cilium-operator"].arn /
# module.irsa.roles["aws-ccm"].arn) - see the note at the bottom of this
# file for what to add on the Terraform side.
CILIUM_OPERATOR_ROLE_ARN="${cilium_operator_role_arn}"
AWS_CCM_ROLE_ARN="${aws_ccm_role_arn}"

# ── Create Kubeadm Cluster Configuration ─────────────────────────────────
cat <<EOF > /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: "${k8s_version}"
%{ if oidc_issuer_url != "" }
apiServer:
  extraArgs:
    service-account-issuer: "${oidc_issuer_url}"
    service-account-jwks-uri: "${oidc_issuer_url}/openid/v1/jwks"
%{ endif }
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

# ── IRSA: publish OIDC discovery + JWKS for AWS STS federation ───────────
# Deliberately does NOT hand-derive the JWKS (getting the "kid" to match
# what kube-apiserver actually signs tokens with is easy to get subtly
# wrong). Instead this fetches the exact, already-correct documents
# kube-apiserver is self-serving on localhost:6443 - both endpoints are
# unauthenticated/anonymous-accessible by design (that's how EKS's own
# managed OIDC endpoint works too) - and mirrors them verbatim to the
# public bucket at the same path structure the issuer URL implies. No
# manual JWK/RSA math, no possibility of a kid mismatch.
#
# This MUST run before the Cilium/CCM installs below now that both use
# IRSA - kube-apiserver's OIDC discovery has to be publicly resolvable
# before AWS STS can validate a projected service-account token from
# either of them.
if [ -n "${oidc_issuer_url}" ]; then
  echo "=== Publishing OIDC discovery documents to S3 for IRSA ===" >> /var/log/kubeadm-init.log
  mkdir -p /tmp/oidc

  kubectl get --raw /.well-known/openid-configuration > /tmp/oidc/openid-configuration
  kubectl get --raw /openid/v1/jwks > /tmp/oidc/jwks.json

  aws s3 cp /tmp/oidc/openid-configuration \
    "s3://${oidc_s3_bucket}/${oidc_s3_prefix}/.well-known/openid-configuration" \
    --content-type application/json --region "$AWS_REGION"
  aws s3 cp /tmp/oidc/jwks.json \
    "s3://${oidc_s3_bucket}/${oidc_s3_prefix}/openid/v1/jwks" \
    --content-type application/json --region "$AWS_REGION"

  echo "OIDC discovery published: ${oidc_issuer_url}/.well-known/openid-configuration" >> /var/log/kubeadm-init.log
else
  echo "=== Skipping OIDC discovery publish (oidc_issuer_url not set) ===" >> /var/log/kubeadm-init.log
fi

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

  # ── cilium-operator IRSA values ─────────────────────────────────────────
  # NEW - cilium-operator needs real AWS credentials for its ENI IPAM calls
  # (DescribeSubnets/CreateNetworkInterface/AssignPrivateIpAddresses/...).
  # It used to get these from the node's instance-profile role; now that
  # role is gone, so the operator container needs a projected
  # service-account token + AWS_ROLE_ARN/AWS_WEB_IDENTITY_TOKEN_FILE env
  # vars pointed at CILIUM_OPERATOR_ROLE_ARN, mirroring
  # platform/values/hub/cilium.yaml's operator block exactly (this is the
  # SAME "inject directly, no pod-identity-webhook" pattern that file
  # already documents - it just has to happen here too, since ArgoCD
  # hasn't reconciled anything yet at day-0).
  #
  # Written as a values file rather than --set, since --set into
  # deeply-nested list-of-maps (extraVolumes[0].projected.sources[0]...)
  # is fragile and hard to read; a values file also matches the format
  # already committed in platform/values/hub/cilium.yaml, so this stays a
  # close 1:1 mirror instead of a second, drifting representation.
  cat <<IRSAEOF > /tmp/cilium-irsa-values.yaml
operator:
  extraVolumes:
    - name: aws-iam-token
      projected:
        sources:
          - serviceAccountToken:
              audience: sts.amazonaws.com
              expirationSeconds: 3600
              path: token
  extraVolumeMounts:
    - name: aws-iam-token
      mountPath: /var/run/secrets/eks.amazonaws.com/serviceaccount
      readOnly: true
  extraEnv:
    - name: AWS_ROLE_ARN
      value: "$CILIUM_OPERATOR_ROLE_ARN"
    - name: AWS_WEB_IDENTITY_TOKEN_FILE
      value: "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
    - name: AWS_REGION
      value: "$AWS_REGION"
IRSAEOF

  for i in $(seq 1 5); do
    helm upgrade --install cilium cilium/cilium \
    --version "1.20.0-rc.1" \
    --namespace kube-system \
    --create-namespace \
    -f /tmp/cilium-irsa-values.yaml \
    --set operator.replicas=1 \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="$PRIVATE_IP" \
    --set k8sServicePort="6443" \
    --set routingMode=native \
    --set ipv4NativeRoutingCIDR="${vpc_cidr_supernet}" \
    --set autoDirectNodeRoutes=false \
    --set ipam.mode=eni \
    --set eni.enabled=true \
    --set eni.awsEnablePrefixDelegation=true \
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
# Under ENI IPAM, pods carry real VPC IPs; no per-node podCIDR route
# sync is needed in the VPC route table.
if [ "$INSTALL_CNI_CCM" = "true" ]; then
  echo "=== Installing AWS CCM ===" >> /var/log/kubeadm-init.log
  helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
  helm repo update

  # ── aws-ccm IRSA values ──────────────────────────────────────────────────
  # NEW - same rationale as cilium-operator above, but this chart takes
  # extraVolumes/extraVolumeMounts/env at the TOP LEVEL, not nested under a
  # sub-key - mirrors platform/values/hub/aws-ccm.yaml exactly. CCM needs
  # this to call EC2/ELB APIs (node metadata sync, LoadBalancer Service
  # provisioning for the Gateway NLBs) now that the instance-profile role
  # is gone.
  cat <<IRSAEOF > /tmp/aws-ccm-irsa-values.yaml
extraVolumes:
  - name: aws-iam-token
    projected:
      sources:
        - serviceAccountToken:
            audience: sts.amazonaws.com
            expirationSeconds: 3600
            path: token
extraVolumeMounts:
  - name: aws-iam-token
    mountPath: /var/run/secrets/eks.amazonaws.com/serviceaccount
    readOnly: true
env:
  - name: AWS_ROLE_ARN
    value: "$AWS_CCM_ROLE_ARN"
  - name: AWS_WEB_IDENTITY_TOKEN_FILE
    value: "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
  - name: AWS_REGION
    value: "$AWS_REGION"
IRSAEOF

  helm upgrade --install aws-cloud-controller-manager aws-cloud-controller-manager/aws-cloud-controller-manager \
    --namespace kube-system \
    -f /tmp/aws-ccm-irsa-values.yaml \
    --set 'args={--v=2,--cloud-provider=aws,--configure-cloud-routes=false}'

  echo "=== Waiting for uninitialized taint to clear ===" >> /var/log/kubeadm-init.log
  timeout 240 bash -c 'until ! kubectl get nodes -o json | grep -q "node.cloudprovider.kubernetes.io/uninitialized"; do sleep 5; done'

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
