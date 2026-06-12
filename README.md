# jenkinsdeploy-blue-green

Jenkins pipeline for **Blue/Green deployment** to Kubernetes.

## Architecture

```
                  ┌──────────────┐
                  │   Jenkins    │
                  │  Pipeline    │
                  └──────┬───────┘
                         │
  ┌──────────────────────┼──────────────────────┐
  ▼              ▼               ▼              ▼
┌──────┐  ┌──────────────┐  ┌──────────┐  ┌──────────┐
│Bootstrap│ Smoke Test  │  │  Switch  │  │ Cleanup  │
│(first │  │ (K8s Job)   │  │ Traffic  │  │ old      │
│ time) │  └──────────────┘  └──────────┘  └──────────┘
└──────┘         │
                 ▼
        ┌─────────────┐     ┌─────────────┐
        │ app-blue    │     │ app-green   │
        │ (inactive)  │────▶│ (live)      │
        │ v2.0        │swap │ v1.0        │
        └─────────────┘     └─────────────┘
                 │                  │
                 └────────┬─────────┘
                          ▼
                 ┌────────────────┐
                 │  app-svc (SVC) │
                 │  selector:     │
                 │  version: blue │ ← patched on switch
                 └────────────────┘
```

Switching is a single `kubectl patch` on the Service selector — instantaneous, zero-downtime.

## Pipeline Stages

| # | Stage | Description |
|---|---|---|
| 0 | **Bootstrap** * | First-time setup: create namespace, blue/green deployments, live Service |
| 1 | **Detect Live Track** | Read Service selector → determine blue/green |
| 2 | **Registry Login** | `docker login` using Jenkins credentials |
| 3 | **Build & Push** | `docker build` + `docker push` |
| 4 | **Image Scan** * | Trivy vulnerability scan (HIGH/CRITICAL) |
| 5 | **Deploy to Inactive** | Apply new image to inactive Deployment, wait ready |
| 6 | **Smoke Test** * | In-cluster Job curls inactive track via preview Service (5 retries) |
| 7 | **Approve Switch** * | Manual approval gate (skipped if `AUTO_SWITCH=yes`) |
| 8 | **Switch Traffic** | `kubectl patch svc` → flip selector |
| 9 | **Verify Live** | In-cluster Job verifies live Service, auto-rollback on failure |
| 10 | **Cleanup** | Scale old Deployment → 0 (kept for rollback) |

`*` = optional / conditional

## Why In-Cluster Smoke Test?

Instead of fragile `kubectl port-forward + sleep + curl`, smoke tests run as a **Kubernetes Job** inside the cluster:

- No port-forward races
- Native retry + backoff
- Cluster DNS resolution (`app-preview.namespace.svc.cluster.local`)
- Self-cleaning (`ttlSecondsAfterFinished`)

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `APP_NAME` | `myapp` | Application name for K8s resources |
| `IMAGE_TAG` | `BUILD_NUMBER` | Docker image tag |
| `NAMESPACE` | `default` | Kubernetes namespace |
| `DOCKER_REGISTRY` | `registry.example.com` | Docker registry host |
| `DOCKERFILE_PATH` | `Dockerfile` | Path relative to workspace |
| `HEALTH_PATH` | `healthz` | Health check endpoint (no `/`) |
| `KUBE_CONTEXT` | — | kubectl context (empty = current) |
| `REGISTRY_CREDENTIALS` | — | Jenkins credential ID for docker registry |
| `SMOKE_TEST_ENABLED` | `yes` | Run smoke test? |
| `SCAN_IMAGE` | `no` | Run Trivy scan? |
| `AUTO_SWITCH` | `yes` | Auto-switch without approval? |
| `BOOTSTRAP_MODE` | `no` | First-time bootstrap? |

## Files

```
.
├── Jenkinsfile
├── k8s/
│   ├── deployment-blue.yaml
│   ├── deployment-green.yaml
│   ├── service.yaml
│   ├── preview-service.yaml
│   └── smoke-test-job.yaml
└── README.md
```

## Quick Start

### 1. First-Time Bootstrap

```bash
# In Jenkins:
# Build with Parameters → set BOOTSTRAP_MODE = yes
# This creates: namespace, app-blue, app-green (0 replicas), app-svc
```

Or manually:

```bash
APP_NAME=myapp NAMESPACE=default IMAGE_TAG=latest
envsubst < k8s/deployment-blue.yaml  | kubectl apply -n ${NAMESPACE} -f -
envsubst < k8s/deployment-green.yaml | kubectl apply -n ${NAMESPACE} -f -
kubectl scale deployment ${APP_NAME}-green -n ${NAMESPACE} --replicas=0
envsubst < k8s/service.yaml          | kubectl apply -n ${NAMESPACE} -f -
```

### 2. Deploy New Version

```
Jenkins → Build with Parameters:
  APP_NAME         = myapp
  IMAGE_TAG        = v2.0
  NAMESPACE        = default
  DOCKER_REGISTRY  = registry.example.com
  HEALTH_PATH      = healthz
```

### 3. Setup Slack Notifications

Set Jenkins global environment variable:

```
SLACK_WEBHOOK_URL = https://hooks.slack.com/services/xxx/yyy/zzz
```

## Rollback

| Method | Command |
|---|---|
| **Auto** | Pipeline auto-rolls back in Stage 9 if live verification fails |
| **Manual** | `kubectl patch svc <app>-svc -n <ns> -p '{"spec":{"selector":{"version":"<old>"}}}'` |
| **Restore old** | `kubectl scale deployment <app>-<old> -n <ns> --replicas=2` |

## Prerequisites

- Jenkins agent with: `docker`, `kubectl`, `envsubst` (gettext)
- Docker registry accessible from Jenkins AND K8s cluster
- kubeconfig on Jenkins agent (or set `KUBE_CONTEXT`)
- (optional) `SLACK_WEBHOOK_URL` in Jenkins global env
