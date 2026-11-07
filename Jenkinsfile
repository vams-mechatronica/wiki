// Jenkins pipeline to deploy Docmost (open-source wiki) with Docker Compose.
//
// Required Jenkins credentials (Manage Jenkins -> Credentials):
//   docmost-app-secret   Secret text  - long random string (openssl rand -hex 32)
//   docmost-db-password  Secret text  - PostgreSQL password
//   docmost-ssh          SSH key      - only for DEPLOY_TARGET=remote
// Optional:
//   docmost-smtp         Username/password - only when ENABLE_SMTP is checked
//
// Required plugins: Pipeline, Credentials Binding, SSH Agent (for remote target).
// The node running it needs: docker CLI with the compose plugin, curl, gzip.

def previousVersion = ''

// Runs `body` with DOCKER_HOST pointing at the chosen target.
def onTarget(Closure body) {
    if (params.DEPLOY_TARGET == 'remote') {
        sshagent(credentials: ['docmost-ssh']) {
            withEnv(["DOCKER_HOST=ssh://${params.REMOTE_HOST}"]) { body() }
        }
    } else {
        body()
    }
}

pipeline {
    // Runs on any node -- on the shared server that's the built-in node of the
    // Jenkins container (api-services/jenkins), which has the docker CLI +
    // compose plugin and talks to the host daemon via /var/run/docker.sock.
    // The stack uses only named volumes, so the workspace path doesn't matter.
    agent any

    options {
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 30, unit: 'MINUTES')
    }

    parameters {
        choice(name: 'ACTION', choices: ['deploy', 'backup', 'restart', 'stop', 'status'],
               description: 'What to do with the Docmost stack')
        string(name: 'DOCMOST_VERSION', defaultValue: 'latest',
               description: 'docmost/docmost image tag (pin a release in production, e.g. a version from Docker Hub)')
        choice(name: 'DEPLOY_TARGET', choices: ['local', 'remote'],
               description: 'local = Docker on the Jenkins agent; remote = Docker over SSH on REMOTE_HOST')
        string(name: 'REMOTE_HOST', defaultValue: 'deploy@wiki.example.com',
               description: 'user@host for remote deployments (user must be in the docker group)')
        string(name: 'APP_URL', defaultValue: 'https://wiki.thenearbyshop.com',
               description: 'Public URL of the wiki (used by Docmost for links)')
        string(name: 'DOCMOST_PORT', defaultValue: '3000', description: 'Host port to publish Docmost on')
        string(name: 'HEALTHCHECK_URL', defaultValue: 'http://docmost-wiki:3000',
               description: 'URL the agent can reach for health checks (Jenkins is on webnet, so the container alias works; empty = APP_URL)')
        booleanParam(name: 'SKIP_BACKUP', defaultValue: false, description: 'Skip the pre-deploy backup')
        booleanParam(name: 'ENABLE_SMTP', defaultValue: false, description: 'Inject SMTP settings from docmost-smtp credential')
        string(name: 'SMTP_HOST', defaultValue: '', description: 'SMTP server (when ENABLE_SMTP)')
        string(name: 'SMTP_PORT', defaultValue: '587', description: 'SMTP port (when ENABLE_SMTP)')
        string(name: 'MAIL_FROM_ADDRESS', defaultValue: '', description: 'Sender address (when ENABLE_SMTP)')
    }

    environment {
        COMPOSE_PROJECT_NAME = 'docmost'
        BACKUP_DIR           = "${env.JENKINS_HOME ?: '/var/lib/jenkins'}/backups/docmost"
        BACKUP_KEEP          = '7'
    }

    stages {
        stage('Prepare .env') {
            steps {
                script {
                    def creds = [
                        string(credentialsId: 'docmost-app-secret', variable: 'APP_SECRET'),
                        string(credentialsId: 'docmost-db-password', variable: 'POSTGRES_PASSWORD')
                    ]
                    if (params.ENABLE_SMTP) {
                        creds << usernamePassword(credentialsId: 'docmost-smtp',
                                usernameVariable: 'SMTP_USERNAME', passwordVariable: 'SMTP_PASSWORD')
                    }
                    // Secrets reach the script as env vars, never through Groovy strings.
                    // It quotes every value and URL-encodes the DB password for DATABASE_URL.
                    withCredentials(creds) {
                        sh 'bash scripts/write_env.sh .env'
                    }
                }
                sh 'chmod +x scripts/*.sh'
            }
        }

        stage('Validate') {
            steps {
                sh 'docker compose version'
                sh 'docker compose config --quiet'
                script { onTarget { sh 'docker info --format "Docker {{.ServerVersion}} on {{.Name}}"' } }
            }
        }

        stage('Pull images') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                script { onTarget { sh 'docker compose pull' } }
            }
        }

        stage('Backup') {
            when {
                anyOf {
                    expression { params.ACTION == 'backup' }
                    expression { params.ACTION == 'deploy' && !params.SKIP_BACKUP }
                }
            }
            steps {
                script { onTarget { sh './scripts/backup.sh "$BACKUP_DIR" "$BACKUP_KEEP"' } }
            }
        }

        stage('Deploy') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                script {
                    onTarget {
                        previousVersion = sh(returnStdout: true, script: '''
                            id=$(docker compose ps -q docmost 2>/dev/null || true)
                            [ -n "$id" ] && docker inspect --format '{{.Config.Image}}' "$id" | sed 's/^.*://' || true
                        ''').trim()
                        echo "Previously running Docmost version: ${previousVersion ?: '(none)'}"
                        sh 'docker compose up -d --remove-orphans'
                    }
                }
            }
        }

        stage('Restart') {
            when { expression { params.ACTION == 'restart' } }
            steps {
                script { onTarget { sh 'docker compose restart docmost' } }
            }
        }

        stage('Health check') {
            when { expression { params.ACTION in ['deploy', 'restart'] } }
            steps {
                script {
                    def url = params.HEALTHCHECK_URL?.trim() ?: params.APP_URL
                    try {
                        sh "./scripts/healthcheck.sh '${url}' 30 5"
                    } catch (err) {
                        onTarget { sh 'docker compose logs --tail=200 docmost || true' }
                        if (params.ACTION == 'deploy' && previousVersion && previousVersion != params.DOCMOST_VERSION) {
                            echo "Rolling back to docmost/docmost:${previousVersion}"
                            echo 'NOTE: if the new version ran DB migrations, restore the pre-deploy backup with scripts/restore.sh.'
                            onTarget {
                                withEnv(["DOCMOST_VERSION=${previousVersion}"]) {
                                    sh 'sed -i "s/^DOCMOST_VERSION=.*/DOCMOST_VERSION=${DOCMOST_VERSION}/" .env'
                                    sh 'docker compose up -d docmost'
                                }
                            }
                            sh "./scripts/healthcheck.sh '${url}' 30 5"
                        }
                        throw err
                    }
                }
            }
        }

        stage('Stop') {
            when { expression { params.ACTION == 'stop' } }
            steps {
                // Stops containers but keeps volumes (data is preserved).
                script { onTarget { sh 'docker compose stop' } }
            }
        }

        stage('Status') {
            steps {
                script { onTarget { sh 'docker compose ps' } }
            }
        }
    }

    post {
        always {
            // Never leave secrets on the agent.
            sh 'rm -f .env'
        }
        success {
            echo "Docmost ${params.ACTION} succeeded (version ${params.DOCMOST_VERSION}) -> ${params.APP_URL}"
        }
        failure {
            echo "Docmost ${params.ACTION} FAILED - check the logs above."
        }
    }
}
