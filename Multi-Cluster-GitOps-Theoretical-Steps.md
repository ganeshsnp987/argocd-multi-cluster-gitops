# 🎯 **Multi-Cluster GitOps Setup - Theoretical Steps**

## **Overview**
Set up ArgoCD on a hub cluster to manage applications across multiple Kubernetes clusters (hub + spoke clusters).

---

## **📋 Step-by-Step Process**

### **1. Infrastructure Setup**
- Create multiple Kubernetes clusters (hub-cluster, spoke-cluster)
- Ensure clusters can communicate over network
- Configure kubectl contexts for each cluster

### **2. ArgoCD Installation (Hub Cluster)**
- Install ArgoCD on the hub cluster
- Expose ArgoCD server (NodePort/LoadBalancer/Ingress)
- Get initial admin credentials
- Verify ArgoCD is running and accessible

### **3. Spoke Cluster Preparation**
- Create service account with cluster-admin permissions
- Generate service account token for authentication
- Create ClusterRole and ClusterRoleBinding for ArgoCD access

### **4. Cluster Registration**
- Extract spoke cluster connection details (server URL, CA cert)
- Create cluster secret in ArgoCD namespace on hub cluster
- Configure authentication (token-based or certificate-based)
- Set TLS configuration (secure/insecure based on environment)

### **5. Verification & Testing**
- Deploy test application to spoke cluster via ArgoCD
- Verify resources are created on target cluster
- Check sync status and health in ArgoCD UI
- Test automated sync and self-healing capabilities

### **6. Application Deployment**
- Create ArgoCD Applications pointing to spoke clusters
- Configure sync policies (manual/automated)
- Set up proper RBAC and project isolation
- Monitor application health and sync status

---

## **🔑 Key Components**

| Component | Purpose | Location |
|-----------|---------|----------|
| **ArgoCD Server** | GitOps controller & UI | Hub Cluster |
| **Service Account** | Authentication to spoke | Spoke Cluster |
| **Cluster Secret** | Connection configuration | Hub Cluster (ArgoCD namespace) |
| **Applications** | Deployment definitions | Hub Cluster (ArgoCD namespace) |

---

## **🌐 Architecture Flow**
```
Git Repository → ArgoCD (Hub) → Spoke Clusters → Applications
```

1. **Git** stores application manifests
2. **ArgoCD** monitors Git and manages deployments  
3. **Hub Cluster** runs ArgoCD control plane
4. **Spoke Clusters** receive and run applications
5. **Service Accounts** provide secure access between clusters

---

## **✅ Success Criteria**
- ArgoCD can list and connect to all registered clusters
- Applications deploy successfully to target clusters
- Sync status shows "Synced" and "Healthy"
- Automated sync and pruning work as expected
- Multi-cluster visibility from single ArgoCD instance

This setup enables **centralized GitOps management** across multiple Kubernetes environments from a single control plane.

---

## **🛠️ Practical Implementation Commands**

### **Service Account Creation (Spoke Cluster)**
```yaml
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
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
- nonResourceURLs: ["*"]
  verbs: ["*"]
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
```

### **Cluster Secret Creation (Hub Cluster)**
```yaml
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
  server: https://SPOKE_CLUSTER_IP:6443
  config: |
    {
      "bearerToken": "SERVICE_ACCOUNT_TOKEN",
      "tlsClientConfig": {
        "insecure": true
      }
    }
```

### **Application Example**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app-spoke
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-repo/your-app.git
    targetRevision: HEAD
    path: .
  destination:
    server: https://SPOKE_CLUSTER_IP:6443
    namespace: your-namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

### **Verification Commands**
```bash
# Check cluster registration
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster

# Extract token from spoke cluster
kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.token}' | base64 -d

# Get cluster IP (for Kind clusters)
docker inspect CLUSTER_NAME-control-plane | grep IPAddress

# Access ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8085:443

# ArgoCD CLI login
argocd login localhost:8085 --username admin --password PASSWORD --insecure
```

---

## **🔒 Security Considerations**

### **Production Recommendations**
- Use certificate-based authentication instead of insecure TLS
- Implement least-privilege RBAC instead of cluster-admin
- Use dedicated namespaces for different environments
- Enable audit logging for compliance
- Rotate service account tokens regularly

### **Network Security**
- Ensure secure communication between clusters
- Use private networks where possible
- Implement network policies for pod-to-pod communication
- Consider service mesh for advanced traffic management

---

## **📊 Monitoring & Troubleshooting**

### **Health Checks**
```bash
# ArgoCD application status
kubectl get applications -n argocd

# Application controller logs
kubectl logs -n argocd deployment/argocd-application-controller

# Server logs
kubectl logs -n argocd deployment/argocd-server

# Check cluster connectivity
kubectl logs -n argocd deployment/argocd-application-controller | grep "cluster_name"
```

### **Common Issues**
- **Connection refused**: Check cluster IP and port
- **Authentication failed**: Verify service account token
- **Permission denied**: Check RBAC configuration
- **Sync failed**: Verify Git repository access and manifests

---

## **🚀 Advanced Features**

### **ApplicationSets for Multi-Cluster**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: multi-cluster-app
  namespace: argocd
spec:
  generators:
  - clusters: {}
  template:
    metadata:
      name: 'app-{{name}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/your-repo/app.git
        targetRevision: HEAD
        path: .
      destination:
        server: '{{server}}'
        namespace: app-namespace
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

### **Project-Based Multi-Tenancy**
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
    server: https://spoke-cluster-ip:6443
  clusterResourceWhitelist:
  - group: ''
    kind: Namespace
  namespaceResourceWhitelist:
  - group: 'apps'
    kind: Deployment
  - group: ''
    kind: Service
```

This comprehensive guide provides both theoretical understanding and practical implementation details for setting up a robust multi-cluster GitOps environment with ArgoCD.
