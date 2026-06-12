pipeline {
    agent any

    parameters {
        string( name: 'APP_NAME',        defaultValue: 'myapp',
                description: 'Application name' )
        string( name: 'IMAGE_TAG',       defaultValue: '',
                description: 'Image tag (defaults to BUILD_NUMBER)' )
        string( name: 'NAMESPACE',       defaultValue: 'default',
                description: 'Kubernetes namespace' )
        string( name: 'HARBOR_PROJECT',  defaultValue: 'library',
                description: 'Harbor project name' )
        string( name: 'DOCKERFILE_PATH', defaultValue: 'Dockerfile',
                description: 'Path to Dockerfile relative to workspace' )
        string( name: 'REMOTE_HOST',     defaultValue: '192.168.0.4',
                description: 'Remote Docker/K8s host IP' )
        string( name: 'REMOTE_USER',     defaultValue: 'steven',
                description: 'SSH user on remote host' )
    }

    environment {
        GIT_REPO     = 'https://github.com/whampoa-dev/jenkinsdeploy-blue-green.git'
        GIT_BRANCH   = 'feature20260611'
        HARBOR_HOST  = 'harbor.gujunhuafu.xyz'
        HARBOR_USER  = 'admin'
        HARBOR_PASS  = 'Zlwloveyou663484$'
        SSH_OPTS     = '-o StrictHostKeyChecking=no'
    }

    stages {

        // ── 0. Checkout ───────────────────────────────────────
        stage('Checkout') {
            steps {
                checkout([$class: 'GitSCM',
                    branches: [[name: "${GIT_BRANCH}"]],
                    userRemoteConfigs: [[url: "${GIT_REPO}"]]
                ])
            }
        }

        // ── 1. Detect Live Track ──────────────────────────────
        stage('Detect Live Track') {
            steps {
                script {
                    def liveSvc = "${params.APP_NAME}-svc"
                    def nsOpt   = "-n ${params.NAMESPACE}"

                    def liveVer = sh(
                        script: "ssh ${SSH_OPTS} ${params.REMOTE_USER}@${params.REMOTE_HOST} " +
                                "'docker exec k8s-lab-control-plane kubectl " +
                                "get svc " + liveSvc + " " + nsOpt + " " +
                                "-o jsonpath='\"'\"'{.spec.selector.version}'\"'\"' 2>/dev/null || echo blue'",
                        returnStdout: true
                    ).trim()

                    if (liveVer != 'blue' && liveVer != 'green') { liveVer = 'blue' }
                    env.LIVE_VERSION     = liveVer
                    env.INACTIVE_VERSION = (liveVer == 'blue') ? 'green' : 'blue'

                    echo "Current live:  ${env.LIVE_VERSION}"
                    echo "Will deploy to: ${env.INACTIVE_VERSION}"
                }
            }
        }

        // ── 2. Build & Push (via SSH to Docker host) ──────────
        stage('Build & Push') {
            steps {
                script {
                    def imageTag  = params.IMAGE_TAG ?: env.BUILD_NUMBER
                    def imageFull = "${HARBOR_HOST}/${params.HARBOR_PROJECT}/${params.APP_NAME}:${imageTag}"
                    def rhost     = "${params.REMOTE_USER}@${params.REMOTE_HOST}"

                    // Write a shell script with all vars baked in, then run remotely
                    writeFile file: 'build-push.sh', text: """#!/bin/bash
set -e
cd /tmp/jenkins-build
echo '${HARBOR_PASS}' | docker login ${HARBOR_HOST} -u '${HARBOR_USER}' --password-stdin
docker build -t '${imageFull}' -f ${params.DOCKERFILE_PATH} .
docker push '${imageFull}'
echo "Pushed: ${imageFull}"
"""

                    sh """
                        echo "Syncing code to ${rhost} ..."
                        ssh ${SSH_OPTS} '${rhost}' 'mkdir -p /tmp/jenkins-build'
                        tar czf - . | ssh ${SSH_OPTS} '${rhost}' 'tar xzf - -C /tmp/jenkins-build'

                        echo "Building ${imageFull} on remote ..."
                        scp ${SSH_OPTS} build-push.sh '${rhost}':/tmp/build-push.sh
                        ssh ${SSH_OPTS} '${rhost}' 'bash /tmp/build-push.sh'
                    """
                }
            }
        }

        // ── 3. Deploy new version to INACTIVE track ────────────
        stage('Deploy to Inactive') {
            steps {
                script {
                    def imageTag       = params.IMAGE_TAG ?: env.BUILD_NUMBER
                    def dockerRegistry = "${HARBOR_HOST}/${params.HARBOR_PROJECT}"
                    def deployName     = "${params.APP_NAME}-${env.INACTIVE_VERSION}"
                    def manifest       = "k8s/deployment-${env.INACTIVE_VERSION}.yaml"
                    def nsOpt          = "-n ${params.NAMESPACE}"
                    def rhost          = "${params.REMOTE_USER}@${params.REMOTE_HOST}"

                    writeFile file: 'deploy.sh', text: """#!/bin/bash
set -e
export APP_NAME='${params.APP_NAME}'
export NAMESPACE='${params.NAMESPACE}'
export DOCKER_REGISTRY='${dockerRegistry}'
export IMAGE_TAG='${imageTag}'

cd /tmp/jenkins-build
echo "Deploying ${deployName} (inactive track) ..."
envsubst < ${manifest} \
    | docker exec -i k8s-lab-control-plane kubectl apply ${nsOpt} -f -

docker exec k8s-lab-control-plane kubectl \
    rollout status deployment/${deployName} ${nsOpt} --timeout=300s

echo "${deployName} is ready (NOT receiving live traffic yet)"
"""

                    sh """
                        scp ${SSH_OPTS} deploy.sh '${rhost}':/tmp/deploy.sh
                        ssh ${SSH_OPTS} '${rhost}' 'bash /tmp/deploy.sh'
                    """
                }
            }
        }

        // ── 4. 🔵🟢 SWITCH TRAFFIC (the blue/green moment) ────
        stage('Switch Traffic') {
            steps {
                script {
                    def liveSvc     = "${params.APP_NAME}-svc"
                    def oldVer      = env.LIVE_VERSION
                    def newVer      = env.INACTIVE_VERSION
                    def nsOpt       = "-n ${params.NAMESPACE}"
                    def rhost       = "${params.REMOTE_USER}@${params.REMOTE_HOST}"

                    writeFile file: 'switch.sh', text: """#!/bin/bash
set -e
echo "═══════════════════════════════════"
echo "  BLUE/GREEN SWITCH"
echo "  ${oldVer} ─────▶ ${newVer}"
echo "═══════════════════════════════════"

BEFORE=\$(docker exec k8s-lab-control-plane kubectl get svc ${liveSvc} ${nsOpt} \
    -o jsonpath='{.spec.selector.version}')
echo "Before: selector.version = \${BEFORE}"

docker exec k8s-lab-control-plane kubectl \
    patch svc ${liveSvc} ${nsOpt} \
    --type=merge \
    -p '{"spec":{"selector":{"version":"${newVer}"}}}'

AFTER=\$(docker exec k8s-lab-control-plane kubectl get svc ${liveSvc} ${nsOpt} \
    -o jsonpath='{.spec.selector.version}')
echo "After:  selector.version = \${AFTER}"

echo "✅ Traffic switched: ${oldVer} → ${newVer}"
"""

                    sh """
                        scp ${SSH_OPTS} switch.sh '${rhost}':/tmp/switch.sh
                        ssh ${SSH_OPTS} '${rhost}' 'bash /tmp/switch.sh'
                    """
                }
            }
        }

        // ── 5. Verify live traffic after switch ───────────────
        stage('Verify Live') {
            steps {
                script {
                    def liveSvc = "${params.APP_NAME}-svc"
                    def nsOpt   = "-n ${params.NAMESPACE}"
                    def newVer  = env.INACTIVE_VERSION
                    def rhost   = "${params.REMOTE_USER}@${params.REMOTE_HOST}"

                    writeFile file: 'verify.sh', text: """#!/bin/bash
echo "Verifying live traffic on ${newVer} ..."

# Check pod count for new track
READY=\$(docker exec k8s-lab-control-plane kubectl \
    get deployment ${params.APP_NAME}-${newVer} ${nsOpt} \
    -o jsonpath='{.status.readyReplicas}')
echo "Ready replicas (${newVer}): \${READY}"

# Quick health check via cluster IP
for i in 1 2 3; do
    CODE=\$(docker exec k8s-lab-control-plane kubectl \
        run verify-\$\$ --rm -i --restart=Never --image=curlimages/curl -- \
        curl -s -o /dev/null -w '%{http_code}' \
        "http://${liveSvc}.${params.NAMESPACE}.svc.cluster.local:80/healthz" 2>/dev/null || echo "000")
    echo "  attempt \$i → HTTP \${CODE}"
    if [ "\${CODE}" = "200" ]; then
        echo "✅ Verification PASSED"
        exit 0
    fi
    sleep 3
done

echo "❌ Verification FAILED — rolling back..."
docker exec k8s-lab-control-plane kubectl \
    patch svc ${liveSvc} ${nsOpt} \
    --type=merge \
    -p '{"spec":{"selector":{"version":"${env.LIVE_VERSION}"}}}'
exit 1
"""

                    sh """
                        scp ${SSH_OPTS} verify.sh '${rhost}':/tmp/verify.sh
                        ssh ${SSH_OPTS} '${rhost}' 'bash /tmp/verify.sh'
                    """
                }
            }
        }

        // ── 6. Cleanup old track ──────────────────────────────
        stage('Cleanup') {
            steps {
                script {
                    def oldDeploy = "${params.APP_NAME}-${env.LIVE_VERSION}"
                    def nsOpt     = "-n ${params.NAMESPACE}"
                    def rhost     = "${params.REMOTE_USER}@${params.REMOTE_HOST}"

                    writeFile file: 'cleanup.sh', text: """#!/bin/bash
echo "Scaling down old track: ${oldDeploy} → 0 replicas"
docker exec k8s-lab-control-plane kubectl \
    scale deployment ${oldDeploy} ${nsOpt} --replicas=0
echo "✅ Old track ${env.LIVE_VERSION} scaled to 0 (kept for rollback)"
"""

                    sh """
                        scp ${SSH_OPTS} cleanup.sh '${rhost}':/tmp/cleanup.sh
                        ssh ${SSH_OPTS} '${rhost}' 'bash /tmp/cleanup.sh'
                    """
                }
            }
        }

    }
}
