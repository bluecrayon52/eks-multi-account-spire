#!/usr/bin/env bash
set -e

kubectl config use-context $SHARED_CXT

echo "Creating the appmesh-system namespace..."
kubectl create ns appmesh-system

echo "Creating an OIDC identity provider for the cluster..."
eksctl --profile shared utils associate-iam-oidc-provider \
  --cluster eks-cluster-shared \
  --approve

echo "Creating an IAM role for the appmesh-controller service account..."
eksctl --profile shared create iamserviceaccount \
  --cluster eks-cluster-shared \
  --namespace appmesh-system \
  --name appmesh-controller \
  --attach-policy-arn  arn:aws:iam::aws:policy/AWSCloudMapFullAccess,arn:aws:iam::aws:policy/AWSAppMeshFullAccess \
  --override-existing-serviceaccounts \
  --approve

echo "Adding the eks-charts helm repo..."
helm repo add eks https://aws.github.io/eks-charts

helm repo update

echo "Installing the appmesh-controller..."
helm upgrade -i appmesh-controller eks/appmesh-controller \
  --namespace appmesh-system \
  --set serviceAccount.create=false \
  --set serviceAccount.name=appmesh-controller \
  --set sds.enabled=true

echo "Creating the yelb namespace..."
kubectl create ns yelb

echo "Labeling the yelb namespace..."
kubectl label namespace yelb mesh=am-multi-account-mesh 

kubectl label namespace yelb "appmesh.k8s.aws/sidecarInjectorWebhook"=enabled

MESH_OWNER=$(aws --profile shared sts get-caller-identity | jq -r .Account)

cat << EOF > app-mesh.yaml
  apiVersion: appmesh.k8s.aws/v1beta2
  kind: Mesh
  metadata:
    name: am-multi-account-mesh
  spec:
    meshOwner: "${MESH_OWNER}"
    namespaceSelector:
      matchLabels:
        mesh: am-multi-account-mesh
EOF

echo "Creating the am-multi-account-mesh..."
kubectl apply -f app-mesh.yaml

echo "Sharing the am-multi-account-mesh with the frontend and backend accounts..." 
aws --profile shared ram create-resource-share \
 --name mesh-share \
 --resource-arns $(kubectl get meshes -o json \
 | jq -r '.items[] | select(.metadata.name =="am-multi-account-mesh").status.meshARN') \
 --principals $(aws --profile frontend sts get-caller-identity | jq -r .Account) \
 $(aws --profile backend sts get-caller-identity | jq -r .Account) > /dev/null
