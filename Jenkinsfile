pipeline {
    agent any

    parameters {
        string( name: 'APP_NAME',        defaultValue: 'myapp',
                description: 'Application name' )
        string( name: 'IMAGE_TAG',       defaultValue: '',
                description: 'Image tag (defaults to BUILD_NUMBER)' )
        string( name: 'NAMESPACE',       defaultValue: 'default',
                description: 'Kubernetes namespace' )
        string( name: 'HARBOR_PROJECT',  defaultValue: 'devops',
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
        K8S_CLUSTER  = 'k8s-lab'
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
                    def rhost   = "${params.REMOTE_USER}@${params.REMOTE_HOST}"
                    def liveSvc = "${params.APP_NAME}-svc"
                    def nsOpt   = "-n ${params.NAMESPACE}"

                    def liveVer = sh(
                        script: "ssh ${SSH_OPTS} ${rhost} " +
                                "'docker exec k8s-lab-control-plane kubectl " +
                                "get svc " + liveSvc + " " + nsOpt + " " +
                                "-o jsonpath='\"'\"'{.spec.selector.version}'\"'\"' 2>/dev/null || echo blue'",
                        returnStdout: true
                    ).trim()

                    if (liveVer != 'blue' && liveVer != 'green') { liveVer = 'blue' }
                    env.LIVE_VERSION     = liveVer
                    env.INACTIVE_VERSION = (liveVer == 'blue') ? 'green' : 'blue'

                    echo "Live:     ${env.LIVE_VERSION}"
                    echo "Inactive: ${env.INACTIVE_VERSION}"
                }
            }
        }

        // ── 2. Build → Push → Load into kind ─────────────────
        stage('Build & Push') {
            steps {
                script {
                    def imageTag   = params.IMAGE_TAG ?: env.BUILD_NUMBER
                    def imageFull  = "${HARBOR_HOST}/${params.HARBOR_PROJECT}/${params.APP_NAME}:${imageTag}"
                    def rhost      = "${params.REMOTE_USER}@${params.REMOTE_HOST}"
                    def kcluster   = env.K8S_CLUSTER

                    // Write build script
                    writeFile file: 'build.sh', text: """#!/bin/bash
set -e
export PATH=\$HOME/go/bin:\$PATH

echo '${HARBOR_PASS}' | docker login ${HARBOR_HOST} -u '${HARBOR_USER}' --password-stdin

cd /tmp/jenkins-build
docker build -t '${imageFull}' -f ${params.DOCKERFILE_PATH} .
docker push '${imageFull}'

echo '=== Loading image into kind cluster ==='
kind load docker-image '${imageFull}' --name ${kcluster}

echo 'DONE: ${imageFull}'
"""

                    sh """
                        echo "Syncing code to ${rhost} ..."
                        ssh ${SSH_OPTS} '${rhost}' 'mkdir -p /tmp/jenkins-build'
                        tar czf - . | ssh ${SSH_OPTS} '${rhost}' 'tar xzf - -C /tmp/jenkins-build'

                        scp ${SSH_OPTS} build.sh '${rhost}':/tmp/build.sh
                        ssh ${SSH_OPTS} '${rhost}' 'bash /tmp/build.sh'
                    """
                }
            }
        }

        // ── 3. Deploy to Inactive Track ───────────────────────
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
echo "Deploying ${deployName} (INACTIVE track — no live traffic) ..."
envsubst < ${manifest} \
    | docker exec -i k8s-lab-control-plane kubectl apply ${nsOpt} -f -

docker exec k8s-lab-control-plane kubectl \
    rollout status deployment/${deployName} ${nsOpt} --timeout=120s

echo "${deployName} is ready (NOT receiving live traffic)"
"""

                    sh """
                        scp ${SSH_OPTS} deploy.sh '${rhost}':/tmp/deploy.sh
                        ssh ${SSH_OPTS} '${rhost}' 'bash /tmp/deploy.sh'
                    """
                }
            }
        }

        // ── 4. 🔵🟢 Switch Traffic ─────────────────────────────
        stage('Switch Traffic') {
            steps {
                script {
                    def liveSvc = "${params.APP_NAME}-svc"
                    def oldVer  = env.LIVE_VERSION
                    def newVer  = env.INACTIVE_VERSION
                    def nsOpt   = "-n ${params.NAMESPACE}"
                    def rhost   = "${params.REMOTE_USER}@${params.REMOTE_HOST}"

                    sh """
                        ssh ${SSH_OPTS} '${rhost}' '
                            echo "═══════════════════════════════════"
                            echo "  BLUE/GREEN SWITCH"
                            echo "  ${oldVer} ─────▶ ${newVer}"
                            echo "═══════════════════════════════════"

                            BEFORE=\$(docker exec k8s-lab-control-plane kubectl \
                                get svc ${liveSvc} ${nsOpt} -o jsonpath="{.spec.selector.version}")
                            echo "Before: selector.version = \${BEFORE}"

                            docker exec k8s-lab-control-plane kubectl \
                                patch svc ${liveSvc} ${nsOpt} --type=merge \
                                -p "{\\"spec\\":{\\"selector\\":{\\"version\\":\\"${newVer}\\"}}}"

                            AFTER=\$(docker exec k8s-lab-control-plane kubectl \
                                get svc ${liveSvc} ${nsOpt} -o jsonpath="{.spec.selector.version}")
                            echo "After:  selector.version = \${AFTER}"

                            echo "✅ Traffic switched: ${oldVer} → ${newVer}"
                        '
                    """
                }
            }
        }

        // ── 5. Verify Live ────────────────────────────────────
        stage('Verify Live') {
            steps {
                script {
                    def liveSvc = "${params.APP_NAME}-svc"
                    def nsOpt   = "-n ${params.NAMESPACE}"
                    def oldVer  = env.LIVE_VERSION
                    def newVer  = env.INACTIVE_VERSION
                    def rhost   = "${params.REMOTE_USER}@${params.REMOTE_HOST}"

                    sh """
                        ssh ${SSH_OPTS} '${rhost}' '
                            echo "Verifying live traffic on ${newVer} ..."

                            READY=\$(docker exec k8s-lab-control-plane kubectl \
                                get deployment ${params.APP_NAME}-${newVer} ${nsOpt} \
                                -o jsonpath="{.status.readyReplicas}")
                            echo "Ready replicas (${newVer}): \${READY}"

                            for i in 1 2 3; do
                                CODE=\$(docker exec k8s-lab-control-plane kubectl \
                                    run verify-\$\$ --rm -i --restart=Never --image=harbor.gujunhuafu.xyz/devops/curl:latest -- \
                                    curl -s -o /dev/null -w "%{http_code}" \
                                    "http://${liveSvc}.${params.NAMESPACE}.svc.cluster.local:80/healthz" 2>/dev/null || echo "000")
                                echo "  attempt \$i → HTTP \${CODE}"
                                if [ "\${CODE}" = "200" ]; then
                                    echo "✅ Verification PASSED"
                                    exit 0
                                fi
                                sleep 3
                            done

                            echo "❌ FAILED — rolling back..."
                            docker exec k8s-lab-control-plane kubectl \
                                patch svc ${liveSvc} ${nsOpt} --type=merge \
                                -p "{\\"spec\\":{\\"selector\\":{\\"version\\":\\"${oldVer}\\"}}}"
                            exit 1
                        '
                    """
                }
            }
        }

        // ── 6. Cleanup Old Track ──────────────────────────────
        stage('Cleanup') {
            steps {
                script {
                    def oldDeploy = "${params.APP_NAME}-${env.LIVE_VERSION}"
                    def nsOpt     = "-n ${params.NAMESPACE}"
                    def rhost     = "${params.REMOTE_USER}@${params.REMOTE_HOST}"

                    sh """
                        ssh ${SSH_OPTS} '${rhost}' "
                            echo 'Scaling down old track: ${oldDeploy} → 0'
                            docker exec k8s-lab-control-plane kubectl \
                                scale deployment ${oldDeploy} ${nsOpt} --replicas=0
                            echo '✅ Old track ${env.LIVE_VERSION} scaled to 0 (kept for rollback)'
                        "
                    """
                }
            }
        }

    }

    post {
        success {
            echo """
            ╔═══════════════════════════════════╗
            ║  Blue/Green Deploy SUCCESS      ║
            ║  App:   ${params.APP_NAME}      ║
            ║  Tag:   ${params.IMAGE_TAG ?: env.BUILD_NUMBER}  ║
            ║  Live:  ${env.INACTIVE_VERSION} ║
            ╚═══════════════════════════════════╝
            """
        }
        failure {
            echo "❌ Pipeline FAILED — check logs above"
        }
    }
}
