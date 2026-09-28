// Jenkins declarative pipeline for devops-hello.
// All secrets come from Jenkins credentials (no tokens in this file).
// All Docker interaction happens on the Jenkins controller (single-host
// deploy target - the host's docker socket is bind-mounted into the
// Jenkins container, see scripts/start-jenkins.sh).

pipeline {
    agent any

    options {
        // Don't pollute the workspace or job UI with old timers/builds.
        disableConcurrentBuilds()
    }

    environment {
        IMAGE_NAME = 'devops-hello'
        IMAGE_TAG  = "${env.BUILD_NUMBER}-${env.GIT_COMMIT.take(8)}"
        PROD_PORT  = '8888'
        // When Jenkins runs inside a container, the app's published port
        // is reachable only on the host. host.docker.internal maps to the
        // host's docker-internal IP from inside the Jenkins container.
        PROD_HOST  = 'host.docker.internal'
    }

    stages {
        stage('Checkout') {
            steps {
                // The repo URL and credentials are configured on the job
                // (or via a Jenkinsfile scm block at job creation). We
                // fetch here using the credentials binding so secrets
                // stay in the credentials store, not this file.
                checkout scm
                sh 'git rev-parse --short HEAD'
            }
        }

        stage('Test') {
            steps {
                // go toolchain is provided by the jenkins/jenkins:lts image.
                // Failing tests block every later stage.
                sh 'go vet ./...'
                sh 'go test -v ./...'
            }
        }

        stage('Build Image') {
            steps {
                sh """
                    docker build \
                        -t '${IMAGE_NAME}:${IMAGE_TAG}' \
                        --build-arg VERSION='${IMAGE_TAG}' \
                        .
                """
                sh 'docker images | grep "${IMAGE_NAME}"'
            }
        }

        stage('Deploy') {
            steps {
                sh 'chmod +x scripts/*.sh'
                sh './scripts/deploy.sh "${IMAGE_NAME}:${IMAGE_TAG}"'
            }
        }

        stage('Verify') {
            steps {
                sh 'curl -sf http://${PROD_HOST}:${PROD_PORT}/health'
                sh 'curl -s  http://${PROD_HOST}:${PROD_PORT}/version'
            }
        }
    }

    post {
        success {
            echo "pipeline green: ${IMAGE_NAME}:${IMAGE_TAG} is serving on ${PROD_HOST}:${PROD_PORT}"
        }
        failure {
            // Post-failure logs only. Real rollback is handled by
            // scripts/deploy.sh when the deploy stage itself fails -
            // production is never replaced with a known-bad candidate.
            echo "pipeline failed - production container from the previous good build is left untouched"
        }
    }
}
