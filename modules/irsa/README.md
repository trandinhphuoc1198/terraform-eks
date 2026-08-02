# Module: `irsa`

Registers one cluster's self-hosted OIDC issuer with AWS
(`aws_iam_openid_connect_provider`) and creates one **trust-scoped** IAM
role per ServiceAccount that needs to call AWS APIs directly - the actual
IRSA mechanic, adapted from EKS to this repo's self-managed kubeadm
clusters.

Instantiated once per cluster (`live/hub/main.tf`, `live/spoke/main.tf`) -
never shared, since each cluster has its own kubeadm-generated SA signing
key and therefore its own issuer identity.

## Why this exists

Every other AWS-facing controller in this repo (Cilium's ENI operator,
Karpenter, `aws-ebs-csi-driver`, ESO, CCM) currently authenticates as
whichever **node** the pod happens to land on, via the broad instance-profile
roles in `modules/ec2`. This module lets a specific pod (identified by its
Kubernetes ServiceAccount, not the node under it) assume a narrowly-scoped
IAM role instead - the trust policy's `sub` condition means only that exact
`system:serviceaccount:<namespace>:<name>` can ever assume it, regardless
of what else is running on the same node.

## Prerequisites (must already be true before this module is useful)

1. The cluster's master has published its OIDC discovery doc + JWKS to the
   shared bucket from `modules/oidc-bucket` (done automatically at
   bootstrap - see `modules/k8s/templates/master_init.sh.tpl`).
2. kube-apiserver was started with `--service-account-issuer` set to the
   exact same URL passed here as `oidc_issuer_url` (wired via
   `modules/k8s`'s `oidc_issuer_url` variable).
3. The pod-identity webhook (`amazon-eks-pod-identity-webhook`, deployed
   via Argo CD - not part of this Terraform) is running in-cluster to
   actually inject the projected token + env vars into annotated pods.

Terraform alone only gets you the AWS-side trust relationship; the
in-cluster half (webhook + ServiceAccount annotations) is a GitOps concern
in the separate `gitops` repo.

## Resources created

| Resource | Purpose |
|---|---|
| `aws_iam_openid_connect_provider` | Registers this cluster's OIDC issuer with AWS so `sts:AssumeRoleWithWebIdentity` can validate its tokens |
| `aws_iam_role` (×N) | One per entry in `var.roles`, trusted only for that role's specific ServiceAccount |
| `aws_iam_role_policy` (×N) | The actual AWS permissions for that role |

## Variables

| Name | Type | Description |
|---|---|---|
| `cluster_prefix` | `string` | e.g. `hub-dev` - must match `modules/k8s`'s `oidc_s3_prefix` for the same cluster |
| `oidc_issuer_url` | `string` | Must exactly match kube-apiserver's `--service-account-issuer` for this cluster |
| `roles` | `map(object({service_account, namespace, policy_json}))` | One entry per workload to onboard - see `live/hub/main.tf` / `live/spoke/main.tf` for the EBS CSI pilot example |

## Outputs

| Name | Description |
|---|---|
| `oidc_provider_arn` | ARN of the registered OIDC provider |
| `role_arns` | Map of `role_key -> role ARN` - feed into the matching ServiceAccount's `eks.amazonaws.com/role-arn` annotation in the gitops repo |

## Adding a new workload

1. Write its least-privilege policy JSON (steal the equivalent statements
   out of `modules/ec2/main.tf`'s node-role policies as a starting point).
2. Add an entry to the `roles` map in the calling `live/*/main.tf`.
3. Annotate the workload's ServiceAccount in the gitops repo with the new
   `role_arns[<key>]` output.
4. Verify (CloudTrail `assumedRole` should show the new IRSA role, not the
   node role) before removing the equivalent permissions from
   `modules/ec2`'s node-role policy.
