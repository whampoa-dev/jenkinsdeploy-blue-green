# jenkinsdeploy-blue-green

Jenkins pipeline for **Blue/Green deployment** to Kubernetes.

## How It Works

```
                  ┌──────────────┐
                  │   Jenkins    │
                  │  Pipeline    │
                  └──────┬───────┘
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   ┌──────────┐  ┌──────────────┐  ┌──────────┐
   │  Build   │  │  Smoke Test  │  │  Switch  │
   │  & Push  │  │  (preview)   │  │  Traffic │
   └──────────┘  └──────────────┘  └──────────┘
                         │
          ┌──────────────┴──────────────┐
          ▼                             ▼
   ┌─────────────┐              ┌─────────────┐
   │ app-blue    │              │ app-green   │
   │ (inactive)  │              │ (live)      │
   │ v2.0  ◄─────│──── switch ──│ v1.0        │
   └──────┬──────┘              └──────┬──────┘
          │                            │
          └────────────┬───────────────┘
                       ▼
              ┌────────────────┐
              │  app-svc (SVC) │
              │  selector:     │
              │  version: green│  ← patched on switch
              └────────────────┘
```

The Service selector's `version` field determines which Deployment receives traffic. Switching is a single `kubectl patch` — instantaneous, no pod restarts.

## Pipeline Stages

| # | Stage | Description |
|---|---|---|
| 1 | **Detect Live Track** | Read current Service selector → determine blue/green |
| 2 | **Build & Push** | `docker build` + `docker push` |
| 3 | **Deploy to Inactive** | Apply new image to the inactive Deployment, wait ready |
| 4 | **Smoke Test** | Create preview Service → curl `/healthz` → delete preview |
| 5 | **Approve Switch** | Manual approval gate (skipped if `AUTO_SWITCH=yes`) |
| 6 | **Switch Traffic** | `kubectl patch svc` → flip selector to new version |
| 7 | **Verify Live** | Health check against live Service, auto-rollback on failure |
| 8 | **Cleanup** | Scale old Deployment to 0 (kept for rollback) |

## Files

```
.
├── Jenkinsfile                   # Pipeline definition
├── k8s/
│   ├── deployment-blue.yaml      # Blue deployment (envsubst template)
│   ├── deployment-green.yaml     # Green deployment (envsubst template)
│   ├── service.yaml              # Live Service (selector patched on switch)
│   └── preview-service.yaml      # Ephemeral smoke-test Service
└── README.md
```

## Prerequisites

- Jenkins with `kubectl` and `docker` on the agent
- kubeconfig configured on the Jenkins agent (`~/.kube/config`)
- `envsubst` (from `gettext`) for manifest variable substitution
- Docker registry accessible from Jenkins agent **and** from K8s cluster

## Quick Start

### 1. Initial Deploy (once)

```bash
# Set your app name
APP_NAME=myapp
NAMESPACE=default
DOCKER_REGISTRY=registry.example.com
IMAGE_TAG=v1.0

# Deploy both tracks + service
envsubst < k8s/deployment-blue.yaml  | kubectl apply -n ${NAMESPACE} -f -
envsubst < k8s/deployment-green.yaml | kubectl apply -n ${NAMESPACE} -f -
envsubst < k8s/service.yaml          | kubectl apply -n ${NAMESPACE} -f -

# Green starts as live by copying blue's image; scale green to 0 initially
kubectl scale deployment ${APP_NAME}-green -n ${NAMESPACE} --replicas=0
```

### 2. Run Pipeline

```
Jenkins → Build with Parameters:
  APP_NAME         = myapp
  IMAGE_TAG        = v2.0
  NAMESPACE        = default
  DOCKER_REGISTRY  = registry.example.com
```

### 3. Manual Rollback

```bash
# If verification fails, the pipeline auto-rolls back.
# Manual rollback:
kubectl patch svc myapp-svc -n default \
  --type=merge \
  -p '{"spec":{"selector":{"version":"blue"}}}'
```

## Rollback

- Pipeline auto-rolls back in **Stage 7 (Verify Live)** if health check fails
- Old Deployment is scaled to 0, not deleted — re-scale to restore
- Manual: `kubectl patch svc <APP_NAME>-svc -n <NS> -p '{"spec":{"selector":{"version":"<old-version>"}}}'`
