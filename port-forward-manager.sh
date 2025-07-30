#!/bin/bash

# Port-Forward Manager for Multi-Cluster GitOps Setup
# This script helps manage port-forwards for ArgoCD and applications

echo "🔍 Port-Forward Status Check"
echo "================================"

# Function to check if a port is in use
check_port() {
    local port=$1
    local service=$2
    if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        local pid=$(netstat -tlnp 2>/dev/null | grep ":$port " | awk '{print $7}' | cut -d'/' -f1 | head -1)
        echo "✅ Port $port ($service) - Active (PID: $pid)"
        return 0
    else
        echo "❌ Port $port ($service) - Not active"
        return 1
    fi
}

# Function to test service accessibility
test_service() {
    local url=$1
    local name=$2
    if curl -s -o /dev/null -w "%{http_code}" "$url" | grep -q "200"; then
        echo "✅ $name - Accessible"
    else
        echo "❌ $name - Not accessible"
    fi
}

echo ""
echo "📊 Current Port-Forward Status:"
echo "--------------------------------"

# Check each service
check_port 8085 "ArgoCD Server"
check_port 8091 "Hub Cluster App"
check_port 8092 "Spoke Cluster App"

echo ""
echo "🌐 Service Accessibility Test:"
echo "-------------------------------"

# Test service accessibility
test_service "https://localhost:8085/healthz" "ArgoCD Server"
test_service "http://localhost:8091" "Hub Cluster App"
test_service "http://localhost:8092" "Spoke Cluster App"

echo ""
echo "🔧 Port-Forward Management:"
echo "---------------------------"

# Show current kubectl port-forward processes
echo "Current kubectl port-forward processes:"
ps aux | grep "kubectl.*port-forward" | grep -v grep | while read line; do
    pid=$(echo $line | awk '{print $2}')
    port=$(echo $line | grep -o ':[0-9]*:' | tr -d ':' | head -1)
    service=$(echo $line | awk '{print $NF}')
    echo "  PID: $pid | Port: $port | Service: $service"
done

echo ""
echo "📋 Quick Commands:"
echo "------------------"
echo "Kill all port-forwards:     pkill -f 'kubectl.*port-forward'"
echo "Kill ArgoCD port-forward:   kill \$(ps aux | grep 'port-forward.*argocd-server' | grep -v grep | awk '{print \$2}')"
echo "Kill app port-forwards:     kill \$(ps aux | grep 'port-forward.*tetris-service' | grep -v grep | awk '{print \$2}')"
echo ""
echo "🚀 Restart Commands:"
echo "--------------------"
echo "ArgoCD:      kubectl port-forward svc/argocd-server -n argocd 8085:443 &"
echo "Hub App:     kubectl --context kind-hub-cluster port-forward -n default svc/tetris-service 8091:80 &"
echo "Spoke App:   kubectl --context kind-spoke-cluster port-forward -n tetris svc/tetris-service 8092:80 &"
echo ""
echo "🌐 Access URLs:"
echo "---------------"
echo "ArgoCD UI:        https://localhost:8085"
echo "Hub Cluster App:  http://localhost:8091"
echo "Spoke Cluster App: http://localhost:8092"
