pipeline {
    agent any

    // ── Parameters ──────────────────────────────────────────────
    parameters {
        string(
            name: 'APP_NAME',
            defaultValue: 'myapp',
            description: 'Application name (used for K8s resource naming)'
        )
        string(
            name: 'IMAGE_TAG',
            defaultValue: '',
            description: 'Docker image tag to deploy (defaults to BUILD_NUMBER)'
        )
        string(
            name: 'NAMESPACE',
            defaultValue: 'default',
            description: 'Kubernetes namespace'
        )
        string(
            name: 'DOCKER_REGISTRY',
            defaultValue: 'registry.example.com',
            description: 'Docker registry host'
        )
        string(
            name: 'DOCKERFILE_PATH',
            defaultValue: 'Dockerfile',
            description: 'Path to Dockerfile relative to workspace'
        )
        choice(
            name: 'SMOKE_TEST_ENABLED',
            choices: ['yes', 'no'],
            description: 'Run smoke test against inactive track before switch?'
        )
        choice(
            name: 'AUTO_SWITCH',
            choices: ['yes', 'no'],
            description: 'Automatically switch traffic after smoke test? (no = manual approval)'
        )
    }

    environment {
        // Derive IMAGE_TAG from BUILD_NUMBER if not explicitly set
        IMAGE_TAG        = "${params.IMAGE_TAG ? params.IMAGE_TAG : env.BUILD_NUMBER}"
        LIVE_SVC         = "${params.APP_NAME}-svc"
        PREVIEW_SVC      = "${params.APP_NAME}-preview"
        DEPLOY_BLUE      = "${params.APP_NAME}-blue"
        DEPLOY_GREEN     = "${params.APP_NAME}-green"
        K8S_MANIFEST_DIR = "k8s"
    }

    stages {

        // ── Stage 1: Detect current live track ────────────────────
        stage('Detect Live Track') {
            steps {
                script {
                    sh '''
                        echo "=== Detecting current live track ==="
                        LIVE_VERSION=$(kubectl get svc ${LIVE_SVC} -n ${NAMESPACE} \
                            -o jsonpath='{.spec.selector.version}' 2>/dev/null || echo "blue")

                        if [ "${LIVE_VERSION}" != "blue" ] && [ "${LIVE_VERSION}" != "green" ]; then
                            LIVE_VERSION="blue"
                        fi

                        if [ "${LIVE_VERSION}" = "blue" ]; then
                            INACTIVE_VERSION="green"
                        else
                            INACTIVE_VERSION="blue"
                        fi

                        echo "LIVE_VERSION=${LIVE_VERSION}"      >  track.env
                        echo "INACTIVE_VERSION=${INACTIVE_VERSION}" >> track.env
                        echo "→ Current live: ${LIVE_VERSION}"
                        echo "→ Inactive:     ${INACTIVE_VERSION}"
                    '''
                    stash name: 'track', includes: 'track.env'
                }
            }
        }

        // ── Stage 2: Build & Push Docker image ───────────────────
        stage('Build & Push') {
            steps {
                script {
                    sh '''
                        IMAGE_FULL="${DOCKER_REGISTRY}/${APP_NAME}:${IMAGE_TAG}"
                        echo "=== Building ${IMAGE_FULL} ==="
                        docker build -t "${IMAGE_FULL}" -f "${DOCKERFILE_PATH}" .
                        docker push "${IMAGE_FULL}"
                        echo "→ Pushed: ${IMAGE_FULL}"
                    '''
                }
            }
        }

        // ── Stage 3: Deploy to INACTIVE track ────────────────────
        stage('Deploy to Inactive') {
            steps {
                script {
                    unstash 'track'
                    sh '''
                        # Load track info
                        . ./track.env

                        DEPLOYMENT="${APP_NAME}-${INACTIVE_VERSION}"
                        MANIFEST="${K8S_MANIFEST_DIR}/deployment-${INACTIVE_VERSION}.yaml"

                        echo "=== Deploying to ${DEPLOYMENT} (${INACTIVE_VERSION}) ==="

                        # Substitute variables in manifest and apply
                        envsubst < "${MANIFEST}" | kubectl apply -n "${NAMESPACE}" -f -

                        echo "→ Waiting for rollout of ${DEPLOYMENT}..."
                        kubectl rollout status deployment/"${DEPLOYMENT}" \
                            -n "${NAMESPACE}" --timeout=300s

                        echo "→ ${DEPLOYMENT} is ready"
                    '''
                }
            }
        }

        // ── Stage 4: Smoke test the INACTIVE track ────────────────
        stage('Smoke Test') {
            when { expression { params.SMOKE_TEST_ENABLED == 'yes' } }
            steps {
                script {
                    unstash 'track'
                    sh '''
                        . ./track.env
                        echo "=== Smoke testing ${INACTIVE_VERSION} track ==="

                        # Create ephemeral preview service pointing to inactive pods
                        envsubst < "${K8S_MANIFEST_DIR}/preview-service.yaml" \
                            | kubectl apply -n "${NAMESPACE}" -f -

                        # Port-forward to the preview service for local curl
                        kubectl port-forward svc/"${PREVIEW_SVC}" -n "${NAMESPACE}" 18080:8080 &
                        PF_PID=$!
                        sleep 3

                        # ── Health check
                        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                            http://localhost:18080/healthz || echo "000")

                        # Kill port-forward
                        kill ${PF_PID} 2>/dev/null || true

                        echo "→ Health check HTTP ${HTTP_CODE}"

                        if [ "${HTTP_CODE}" != "200" ]; then
                            echo "!!! Smoke test FAILED — aborting"
                            kubectl delete svc "${PREVIEW_SVC}" -n "${NAMESPACE}" --ignore-not-found
                            exit 1
                        fi
                        echo "→ Smoke test PASSED"
                    '''
                }
            }
            post {
                always {
                    sh "kubectl delete svc ${PREVIEW_SVC} -n ${NAMESPACE} --ignore-not-found"
                }
            }
        }

        // ── Stage 5: Approval gate (if AUTO_SWITCH = no) ──────────
        stage('Approve Switch') {
            when { expression { params.AUTO_SWITCH == 'no' } }
            steps {
                script {
                    unstash 'track'
                    def trackProps = readProperties file: 'track.env'
                    input message: "Switch traffic from ${trackProps.LIVE_VERSION} → ${trackProps.INACTIVE_VERSION}?",
                          ok: 'Switch Now'
                }
            }
        }

        // ── Stage 6: Switch traffic ───────────────────────────────
        stage('Switch Traffic') {
            steps {
                script {
                    unstash 'track'
                    sh '''
                        . ./track.env
                        echo "=== Switching traffic: ${LIVE_VERSION} → ${INACTIVE_VERSION} ==="

                        kubectl patch svc "${LIVE_SVC}" -n "${NAMESPACE}" \
                            --type=merge \
                            -p "{\"spec\":{\"selector\":{\"version\":\"${INACTIVE_VERSION}\"}}}"

                        echo "→ Traffic now routed to ${INACTIVE_VERSION}"
                    '''
                }
            }
        }

        // ── Stage 7: Verify live after switch ─────────────────────
        stage('Verify Live') {
            steps {
                script {
                    unstash 'track'
                    sh '''
                        . ./track.env
                        echo "=== Verifying live traffic on ${INACTIVE_VERSION} ==="

                        # Quick health check via port-forward to the live service
                        kubectl port-forward svc/"${LIVE_SVC}" -n "${NAMESPACE}" 18081:80 &
                        PF_PID=$!
                        sleep 3

                        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                            http://localhost:18081/healthz || echo "000")

                        kill ${PF_PID} 2>/dev/null || true

                        if [ "${HTTP_CODE}" = "200" ]; then
                            echo "→ Live verification PASSED (HTTP ${HTTP_CODE})"
                        else
                            echo "!!! Live verification returned HTTP ${HTTP_CODE}"
                            echo "!!! Rolling back..."
                            kubectl patch svc "${LIVE_SVC}" -n "${NAMESPACE}" \
                                --type=merge \
                                -p "{\"spec\":{\"selector\":{\"version\":\"${LIVE_VERSION}\"}}}"
                            exit 1
                        fi
                    '''
                }
            }
        }

        // ── Stage 8: Cleanup old track ────────────────────────────
        stage('Cleanup') {
            steps {
                script {
                    unstash 'track'
                    sh '''
                        . ./track.env
                        echo "=== Scaling down old ${LIVE_VERSION} track ==="
                        kubectl scale deployment "${APP_NAME}-${LIVE_VERSION}" \
                            -n "${NAMESPACE}" --replicas=0 2>/dev/null || true
                        echo "→ Old track ${LIVE_VERSION} scaled to 0 (kept for rollback)"
                    '''
                }
            }
        }
    }

    // ── Post actions ──────────────────────────────────────────────
    post {
        success {
            script {
                unstash 'track'
                def trackProps = readProperties file: 'track.env'
                echo """
                ╔══════════════════════════════════════════════╗
                ║  Blue/Green Deployment SUCCESS            ║
                ║  App:      ${params.APP_NAME}             ║
                ║  Image:    ${env.IMAGE_TAG}               ║
                ║  Live:     ${trackProps.INACTIVE_VERSION} ║
                ╚══════════════════════════════════════════════╝
                """
            }
        }
        failure {
            echo "Pipeline FAILED — check logs above"
        }
    }
}
