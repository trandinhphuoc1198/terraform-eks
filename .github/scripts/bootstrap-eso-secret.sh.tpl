#!/bin/bash
set -euo pipefail
export KUBECONFIG=/home/ec2-user/.kube/config

AWS_REGION="__AWS_REGION__"
ENV="__ENV__"

ESO_CREDS=$(aws secretsmanager get-secret-value \
  --secret-id "$ENV/eso/bootstrap-credentials" \
  --region "$AWS_REGION" --query SecretString --output text)
ESO_ACCESS_KEY=$(echo "$ESO_CREDS" | jq -r .access_key_id)
ESO_SECRET_KEY=$(echo "$ESO_CREDS" | jq -r .secret_access_key)

kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic aws-creds -n external-secrets \
  --from-literal=access-key-id="$ESO_ACCESS_KEY" \
  --from-literal=secret-access-key="$ESO_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
