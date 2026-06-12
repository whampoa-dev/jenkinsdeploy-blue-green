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

        // ── 3. Deploy to K8s ──────────────────────────────────
        stage('Deploy to K8s') {
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
echo "Deploying ${deployName} ..."
envsubst < ${manifest} \
    | docker exec -i k8s-lab-control-plane kubectl apply ${nsOpt} -f -

docker exec k8s-lab-control-plane kubectl \
    rollout status deployment/${deployName} ${nsOpt} --timeout=300s

echo "${deployName} is ready"
"""

                    sh """
                        scp ${SSH_OPTS} deploy.sh '${rhost}':/tmp/deploy.sh
                        ssh ${SSH_OPTS} '${rhost}' 'bash /tmp/deploy.sh'
                    """
                }
            }
        }

    }
}
