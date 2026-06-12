#!/bin/bash
# ──────────────────────────────────────────────────────────
# Bootstrap — 一键初始化 Blue/Green 基础设施
# 在 kind 集群中创建:
#   - myapp-blue  (1 replica, 接线上流量)
#   - myapp-green (0 replicas, 空闲)
#   - myapp-svc   (Service, 路由到 blue)
#   - harbor-secret (镜像拉取凭证)
# ──────────────────────────────────────────────────────────
set -e

APP_NAME="${APP_NAME:-myapp}"
NAMESPACE="${NAMESPACE:-default}"
HARBOR_HOST="harbor.gujunhuafu.xyz"
HARBOR_USER="admin"
HARBOR_PASS='Zlwloveyou663484$'
K="docker exec k8s-lab-control-plane kubectl"

echo "═══════════════════════════════════════"
echo "  Bootstrap Blue/Green for ${APP_NAME}"
echo "═══════════════════════════════════════"

# ── 1. Harbor pull secret ──
echo "=== Creating harbor-secret ==="
$K delete secret harbor-secret -n ${NAMESPACE} --ignore-not-found
$K create secret docker-registry harbor-secret \
  -n ${NAMESPACE} \
  --docker-server=${HARBOR_HOST} \
  --docker-username=${HARBOR_USER} \
  --docker-password="${HARBOR_PASS}"

# ── 2. Blue Deployment (live, 1 replica) ──
echo "=== Creating ${APP_NAME}-blue ==="
$K delete deployment ${APP_NAME}-blue -n ${NAMESPACE} --ignore-not-found
cat <<YAML | $K apply -n ${NAMESPACE} -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-blue
  namespace: ${NAMESPACE}
  labels: {app: ${APP_NAME}, version: blue}
spec:
  replicas: 1
  revisionHistoryLimit: 3
  selector:
    matchLabels: {app: ${APP_NAME}, version: blue}
  template:
    metadata:
      labels: {app: ${APP_NAME}, version: blue}
    spec:
      imagePullSecrets:
        - name: harbor-secret
      containers:
        - name: ${APP_NAME}
          image: ${HARBOR_HOST}/library/${APP_NAME}:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
YAML

# ── 3. Green Deployment (idle, 0 replicas) ──
echo "=== Creating ${APP_NAME}-green ==="
$K delete deployment ${APP_NAME}-green -n ${NAMESPACE} --ignore-not-found
cat <<YAML | $K apply -n ${NAMESPACE} -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-green
  namespace: ${NAMESPACE}
  labels: {app: ${APP_NAME}, version: green}
spec:
  replicas: 0
  revisionHistoryLimit: 3
  selector:
    matchLabels: {app: ${APP_NAME}, version: green}
  template:
    metadata:
      labels: {app: ${APP_NAME}, version: green}
    spec:
      imagePullSecrets:
        - name: harbor-secret
      containers:
        - name: ${APP_NAME}
          image: ${HARBOR_HOST}/library/${APP_NAME}:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
YAML

# ── 4. Live Service (points to blue) ──
echo "=== Creating ${APP_NAME}-svc ==="
$K delete svc ${APP_NAME}-svc -n ${NAMESPACE} --ignore-not-found
cat <<YAML | $K apply -n ${NAMESPACE} -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-svc
  namespace: ${NAMESPACE}
spec:
  selector: {app: ${APP_NAME}, version: blue}
  ports:
    - port: 80
      targetPort: 8080
YAML

echo ""
echo "═══════════════════════════════════════"
echo "  Bootstrap Complete"
echo "═══════════════════════════════════════"
$K get deploy,svc -n ${NAMESPACE}
