# Complete Multi-Cluster GitOps Setup with ArgoCD

This comprehensive guide walks you through setting up a multi-cluster GitOps environment using ArgoCD deployed on a hub cluster to manage applications across multiple Kubernetes clusters.

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Cluster Setup](#cluster-setup)
3. [ArgoCD Installation](#argocd-installation)
4. [Multi-Cluster Configuration](#multi-cluster-configuration)
5. [Application Deployment](#application-deployment)
6. [Verification and Testing](#verification-and-testing)
7. [Troubleshooting](#troubleshooting)

## Prerequisites

### Required Tools
```bash
# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Install kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Install ArgoCD CLI
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd-linux-amd64
sudo mv argocd-linux-amd64 /usr/local/bin/argocd
```

## Cluster Setup

### 1. Create Hub Cluster Configuration

Create the hub cluster configuration file:

```yaml
# hub-cluster-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: hub-cluster
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 8080
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
- role: worker
- role: worker
networking:
  disableDefaultCNI: false
  podSubnet: "10.244.0.0/16"
```

### 2. Create Spoke Cluster Configuration

Create the spoke cluster configuration file:

```yaml
# spoke-cluster-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: spoke-cluster
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 8081
    protocol: TCP
  - containerPort: 443
    hostPort: 8444
    protocol: TCP
networking:
  disableDefaultCNI: false
  podSubnet: "10.245.0.0/16"
```

### 3. Create Both Clusters

```bash
# Create hub cluster
kind create cluster --config hub-cluster-config.yaml

# Create spoke cluster
kind create cluster --config spoke-cluster-config.yaml

# Verify clusters
kind get clusters
```

### 4. Configure kubectl Contexts

```bash
# List available contexts
kubectl config get-contexts

# You should see:
# - kind-hub-cluster
# - kind-spoke-cluster

# Set hub cluster as default
kubectl config use-context kind-hub-cluster
```

## ArgoCD Installation

### 1. Install ArgoCD on Hub Cluster

```bash
# Ensure you're on hub cluster context
kubectl config use-context kind-hub-cluster

# Create ArgoCD namespace
kubectl create namespace argocd

# Install ArgoCD (latest stable version)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for all pods to be ready
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
```

### 2. Access ArgoCD UI

```bash
# Port forward ArgoCD server
kubectl port-forward svc/argocd-server -n argocd 8085:443 &

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Login via CLI (replace 'your-password' with actual password)
argocd login localhost:8085 --username admin --password your-password --insecure

# Change password (optional)
argocd account update-password
```

### 3. Verify ArgoCD Installation

```bash
# Check ArgoCD version
kubectl get deployment argocd-server -n argocd -o jsonpath='{.spec.template.spec.containers[0].image}'

# List all ArgoCD pods
kubectl get pods -n argocd
```

## Multi-Cluster Configuration

### 1. Get Spoke Cluster Connection Details

```bash
# Switch to spoke cluster
kubectl config use-context kind-spoke-cluster

# Get cluster server URL
kubectl cluster-info

# Note: For kind clusters, you'll need the internal Docker network IP
# Get the spoke cluster's internal IP
docker inspect spoke-cluster-control-plane | grep IPAddress
```

### 2. Create Service Account on Spoke Cluster

```bash
# Ensure you're on spoke cluster context
kubectl config use-context kind-spoke-cluster

# Create service account and RBAC
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-manager-role
rules:
- apiGroups:
  - '*'
  resources:
  - '*'
  verbs:
  - '*'
- nonResourceURLs:
  - '*'
  verbs:
  - '*'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-manager-role
subjects:
- kind: ServiceAccount
  name: argocd-manager
  namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF
```

### 3. Extract Service Account Token

```bash
# Get the token
TOKEN=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)

# Get the CA certificate
CA_CERT=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.ca\.crt}')

# Get cluster server URL (replace with actual internal IP)
CLUSTER_SERVER="https://172.20.0.5:6443"

echo "Token: $TOKEN"
echo "Server: $CLUSTER_SERVER"
```

### 4. Register Spoke Cluster with ArgoCD

```bash
# Switch back to hub cluster
kubectl config use-context kind-hub-cluster

# Create cluster secret for ArgoCD
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: spoke-cluster-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: spoke-cluster
  server: $CLUSTER_SERVER
  config: |
    {
      "bearerToken": "$TOKEN",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF
```

### 5. Verify Cluster Registration

```bash
# List registered clusters
argocd cluster list

# You should see both clusters:
# - https://kubernetes.default.svc (in-cluster/hub)
# - https://172.20.0.5:6443 (spoke-cluster)
```

## Application Deployment

### 1. Prepare Application Repository

Create a Git repository with your application manifests. For this example, we'll use a Tetris game application.

Example repository structure:
```
tetris-manifest/
├── deployment.yaml
├── service.yaml
└── namespace.yaml
```

**namespace.yaml:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tetris
```

**deployment.yaml:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tetris
  namespace: tetris
spec:
  replicas: 3
  selector:
    matchLabels:
      app: tetris
  template:
    metadata:
      labels:
        app: tetris
    spec:
      containers:
      - name: tetris
        image: bsord/tetris:latest
        ports:
        - containerPort: 80
```

**service.yaml:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: tetris-service
  namespace: tetris
spec:
  selector:
    app: tetris
  ports:
  - port: 80
    targetPort: 80
    nodePort: 31219
  type: NodePort
```

### 2. Deploy Application to Hub Cluster

```bash
# Create ArgoCD application for hub cluster
cat << 'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tetris-hub-cluster
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-username/tetris-manifest.git
    targetRevision: HEAD
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: tetris
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
```

### 3. Deploy Application to Spoke Cluster

```bash
# Create ArgoCD application for spoke cluster
cat << 'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tetris-spoke-cluster
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-username/tetris-manifest.git
    targetRevision: HEAD
    path: .
  destination:
    server: https://172.20.0.5:6443
    namespace: tetris
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
```

## Verification and Testing

### 1. Check Application Status in ArgoCD

```bash
# List all applications
argocd app list

# Get detailed status
argocd app get tetris-hub-cluster
argocd app get tetris-spoke-cluster

# Check sync status
kubectl get applications -n argocd
```

### 2. Verify Deployments on Hub Cluster

```bash
# Switch to hub cluster
kubectl config use-context kind-hub-cluster

# Check pods
kubectl get pods -n tetris

# Check services
kubectl get svc -n tetris

# Test application
curl http://localhost:8080  # If using port forwarding
```

### 3. Verify Deployments on Spoke Cluster

```bash
# Switch to spoke cluster
kubectl config use-context kind-spoke-cluster

# Check pods
kubectl get pods -n tetris

# Check services
kubectl get svc -n tetris

# Test application
curl http://localhost:8081  # If using port forwarding
```

### 4. Monitor Application Health

```bash
# Watch application sync status
kubectl get applications -n argocd -w

# Check ArgoCD logs if needed
kubectl logs -n argocd deployment/argocd-application-controller
```

## Advanced Configuration

### 1. Project-Based Multi-Tenancy

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: production
  namespace: argocd
spec:
  description: Production applications
  sourceRepos:
  - 'https://github.com/your-org/*'
  destinations:
  - namespace: 'prod-*'
    server: https://172.20.0.5:6443
  clusterResourceWhitelist:
  - group: ''
    kind: Namespace
  namespaceResourceWhitelist:
  - group: 'apps'
    kind: Deployment
  - group: ''
    kind: Service
```

### 2. Application Sets for Multiple Clusters

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tetris-multicluster
  namespace: argocd
spec:
  generators:
  - clusters: {}
  template:
    metadata:
      name: 'tetris-{{name}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/your-username/tetris-manifest.git
        targetRevision: HEAD
        path: .
      destination:
        server: '{{server}}'
        namespace: tetris
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
```

## Troubleshooting

### Common Issues and Solutions

#### 1. Cluster Connection Issues

**Problem:** "the server has asked for the client to provide credentials"

**Solution:**
```bash
# Recreate service account token
kubectl delete secret argocd-manager-token -n kube-system
kubectl apply -f service-account-manifest.yaml

# Update cluster secret with new token
kubectl delete secret spoke-cluster-secret -n argocd
# Recreate with new token
```

#### 2. Network Connectivity Issues

**Problem:** ArgoCD cannot reach spoke cluster

**Solution:**
```bash
# Check Docker network connectivity
docker network ls
docker inspect kind

# Verify cluster IPs
docker inspect spoke-cluster-control-plane | grep IPAddress
docker inspect hub-cluster-control-plane | grep IPAddress

# Test connectivity from hub cluster
kubectl run test-pod --image=curlimages/curl -it --rm -- curl -k https://SPOKE_CLUSTER_IP:6443/healthz
```

#### 3. Application Sync Issues

**Problem:** Application stuck in "Unknown" or "OutOfSync" state

**Solution:**
```bash
# Force refresh
argocd app get tetris-spoke-cluster --refresh

# Manual sync
argocd app sync tetris-spoke-cluster

# Check application events
kubectl describe application tetris-spoke-cluster -n argocd
```

#### 4. RBAC Permission Issues

**Problem:** ArgoCD cannot create resources on spoke cluster

**Solution:**
```bash
# Verify service account permissions
kubectl auth can-i '*' '*' --as=system:serviceaccount:kube-system:argocd-manager

# Update cluster role if needed
kubectl patch clusterrole argocd-manager-role --type='merge' -p='{"rules":[{"apiGroups":["*"],"resources":["*"],"verbs":["*"]}]}'
```

### Monitoring and Logging

#### 1. ArgoCD Metrics

```bash
# Port forward metrics endpoint
kubectl port-forward svc/argocd-metrics -n argocd 8082:8082

# Access metrics
curl http://localhost:8082/metrics
```

#### 2. Application Controller Logs

```bash
# View application controller logs
kubectl logs -n argocd deployment/argocd-application-controller -f

# View server logs
kubectl logs -n argocd deployment/argocd-server -f
```

## Security Best Practices

### 1. Service Account Token Management

- Use dedicated service accounts for each cluster
- Regularly rotate service account tokens
- Apply principle of least privilege for RBAC

### 2. TLS Configuration

```yaml
# Enable TLS for cluster connections
config: |
  {
    "bearerToken": "your-token",
    "tlsClientConfig": {
      "caData": "base64-encoded-ca-cert",
      "insecure": false
    }
  }
```

### 3. Network Policies

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-network-policy
  namespace: argocd
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/part-of: argocd
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: argocd
  egress:
  - to: []
    ports:
    - protocol: TCP
      port: 443
    - protocol: TCP
      port: 6443
```

## Maintenance and Operations

### 1. Backup ArgoCD Configuration

```bash
# Backup ArgoCD resources
kubectl get all,secrets,configmaps -n argocd -o yaml > argocd-backup.yaml

# Backup applications
kubectl get applications -n argocd -o yaml > applications-backup.yaml
```

### 2. Upgrade ArgoCD

```bash
# Check current version
kubectl get deployment argocd-server -n argocd -o jsonpath='{.spec.template.spec.containers[0].image}'

# Upgrade to latest
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Verify upgrade
kubectl rollout status deployment/argocd-server -n argocd
```

### 3. Cluster Maintenance

```bash
# Drain cluster for maintenance
kubectl drain NODE_NAME --ignore-daemonsets --delete-emptydir-data

# Update cluster registration after IP changes
kubectl patch secret spoke-cluster-secret -n argocd --type='merge' -p='{"stringData":{"server":"https://NEW_IP:6443"}}'
```

## Summary

This comprehensive setup provides a robust, scalable multi-cluster GitOps environment using ArgoCD. The centralized ArgoCD instance on the hub cluster can manage applications across multiple spoke clusters, providing consistent deployment practices and centralized observability.

### Key Benefits:
- **Centralized Management**: Single ArgoCD instance manages multiple clusters
- **GitOps Workflow**: Declarative application deployment from Git repositories
- **Multi-Cluster Support**: Deploy applications across different environments
- **Automated Sync**: Continuous deployment with self-healing capabilities
- **Security**: RBAC-based access control and secure cluster communication
- **Scalability**: Easy addition of new clusters and applications

### Architecture Overview:
```
┌─────────────────┐    ┌─────────────────┐
│   Hub Cluster   │    │  Spoke Cluster  │
│                 │    │                 │
│  ┌───────────┐  │    │  ┌───────────┐  │
│  │  ArgoCD   │──┼────┼──│Application│  │
│  │           │  │    │  │           │  │
│  └───────────┘  │    │  └───────────┘  │
│                 │    │                 │
│  ┌───────────┐  │    │                 │
│  │Application│  │    │                 │
│  │           │  │    │                 │
│  └───────────┘  │    │                 │
└─────────────────┘    └─────────────────┘
```

This setup enables you to manage applications across multiple Kubernetes clusters from a single control plane, providing consistency, reliability, and operational efficiency in your GitOps workflow.
