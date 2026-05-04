#!/bin/bash
set -euo pipefail
# =============================================================================
# Tools Installation Script for Jenkins Server (Ubuntu 22.04)
#
# Installs: Java, Jenkins, Docker, SonarQube, Sonar-Scanner, AWS CLI,
#           kubectl, eksctl, Terraform, Trivy, Helm
#
# Configures: JCasC (Jenkins Configuration as Code)
#   - Plugins downloaded BEFORE Jenkins first boot (no CLI needed)
#   - JCasC YAML placed in Jenkins home before startup
#   - systemd override used for environment variables (not /etc/default/jenkins)
#   - Setup wizard disabled so JCasC takes full control
#
# After boot, run setup-jcasc.sh to inject secrets and restart Jenkins.
# =============================================================================

exec > /var/log/tools-install.log 2>&1
echo "========== Starting tools installation =========="

# ─── Java 21 ─────────────────────────────────────────────────────────────────
echo "===> Installing Java 21"
sudo apt update -y
sudo apt install -y fontconfig openjdk-21-jdk curl gnupg unzip wget
java --version

# ─── Jenkins (install but DO NOT start yet) ──────────────────────────────────
echo "===> Installing Jenkins"
sudo mkdir -p /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y jenkins

# STOP Jenkins immediately — we need to configure it before first real boot
sudo systemctl stop jenkins
sleep 5

# ─── Download Jenkins Plugins BEFORE First Boot ──────────────────────────────
echo "===> Downloading Jenkins plugins to filesystem"
PLUGIN_DIR="/var/lib/jenkins/plugins"
sudo mkdir -p "$PLUGIN_DIR"

PLUGINS=(
  configuration-as-code
  job-dsl
  workflow-aggregator
  pipeline-stage-view
  git
  git-client
  docker-pipeline
  docker-commons
  sonar
  pipeline-aws
  kubernetes-cli
  credentials
  credentials-binding
  plain-credentials
  ws-cleanup
  timestamper
  antisamy-markup-formatter
  build-timeout
  cloudbees-folder
  pipeline-github-lib
  pipeline-graph-analysis
  pipeline-model-definition
  pipeline-model-extensions
  pipeline-stage-step
  workflow-cps
  workflow-durable-task-step
  workflow-job
  workflow-multibranch
  workflow-scm-step
  workflow-step-api
  workflow-support
  ssh-credentials
  matrix-auth
  script-security
  structs
  scm-api
  branch-api
  token-macro
  mailer
  display-url-api
  jackson2-api
  jaxb
  snakeyaml-api
  json-path-api
  commons-lang3-api
  commons-text-api
  caffeine-api
  bootstrap5-api
  jquery3-api
  font-awesome-api
  echarts-api
  plugin-util-api
  checks-api
  junit
  matrix-project
  apache-httpcomponents-client-4-api
  apache-httpcomponents-client-5-api
  instance-identity
  ionicons-api
  jakarta-activation-api
  jakarta-mail-api
  javax-activation-api
  joda-time-api
  mina-sshd-api-common
  mina-sshd-api-core
  asm-api
  json-api
  variant
  durable-task
  trilead-api
  bouncycastle-api
  eddsa-api
  gson-api
  workflow-api
  pipeline-input-step
  pipeline-milestone-step
  pipeline-build-step
  plain-credentials
  ssh-slaves
  resource-disposer
  prism-api
)

for plugin in "${PLUGINS[@]}"; do
  echo "  Downloading: $plugin"
  sudo wget -q -O "$PLUGIN_DIR/${plugin}.hpi" \
    "https://updates.jenkins.io/latest/${plugin}.hpi" 2>/dev/null \
    || echo "  WARNING: Failed to download $plugin"
done

sudo chown -R jenkins:jenkins "$PLUGIN_DIR"

# ─── Configure JCasC (before Jenkins starts) ─────────────────────────────────
echo "===> Setting up JCasC"
sudo mkdir -p /var/lib/jenkins/casc_configs

# Get the public IP for Jenkins URL
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "localhost")

# Create the JCasC config with the actual IP baked in
cat > /tmp/jenkins-casc.yaml << CASC_EOF
jenkins:
  systemMessage: "Cloud-Native EKS Project — Configured via JCasC"
  numExecutors: 2
  securityRealm:
    local:
      allowsSignup: false
      users:
        - id: "admin"
          password: "\${JENKINS_ADMIN_PASSWORD:-admin123}"
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false

unclassified:
  location:
    url: "http://${PUBLIC_IP}:8080/"
  sonarGlobalConfiguration:
    buildWrapperEnabled: true
    installations:
      - name: "sonar"
        serverUrl: "http://localhost:9000"
        credentialsId: "sonar"
        triggers:
          skipScmCause: false
          skipUpstreamCause: false

credentials:
  system:
    domainCredentials:
      - credentials:
          - usernamePassword:
              scope: GLOBAL
              id: "github-creds"
              description: "GitHub credentials for SCM checkout"
              username: "\${GITHUB_USERNAME}"
              password: "\${GITHUB_PAT}"
          - string:
              scope: GLOBAL
              id: "github-token"
              description: "GitHub PAT for pipeline git push"
              secret: "\${GITHUB_PAT}"
          - string:
              scope: GLOBAL
              id: "ACCOUNT_ID"
              description: "AWS Account ID"
              secret: "\${AWS_ACCOUNT_ID}"
          - string:
              scope: GLOBAL
              id: "ECR_REPO1"
              description: "Frontend ECR repository name"
              secret: "frontend"
          - string:
              scope: GLOBAL
              id: "ECR_REPO2"
              description: "Backend ECR repository name"
              secret: "backend"
          - string:
              scope: GLOBAL
              id: "sonar"
              description: "SonarQube authentication token"
              secret: "\${SONARQUBE_TOKEN}"

jobs:
  - script: >
      pipelineJob('three-tier-backend') {
        description('Backend CI/CD Pipeline — SonarQube + Trivy + ECR + GitOps')
        definition {
          cpsScm {
            scm {
              git {
                remote {
                  url('https://github.com/ibrahim-2010/cloud-native-eks.git')
                  credentials('github-creds')
                }
                branches('*/main')
              }
            }
            scriptPath('Jenkins-Pipeline-Code/Jenkinsfile-Backend')
          }
        }
      }
  - script: >
      pipelineJob('three-tier-frontend') {
        description('Frontend CI/CD Pipeline — SonarQube + Trivy + ECR + GitOps')
        definition {
          cpsScm {
            scm {
              git {
                remote {
                  url('https://github.com/ibrahim-2010/cloud-native-eks.git')
                  credentials('github-creds')
                }
                branches('*/main')
              }
            }
            scriptPath('Jenkins-Pipeline-Code/Jenkinsfile-Frontend')
          }
        }
      }
CASC_EOF

sudo cp /tmp/jenkins-casc.yaml /var/lib/jenkins/casc_configs/jenkins.yaml
sudo chown -R jenkins:jenkins /var/lib/jenkins/casc_configs

# ─── Configure systemd override for JCasC ────────────────────────────────────
echo "===> Configuring systemd override for JCasC"
sudo mkdir -p /etc/systemd/system/jenkins.service.d

cat > /tmp/jenkins-override.conf << 'OVERRIDE_EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Dcasc.jenkins.config=/var/lib/jenkins/casc_configs/jenkins.yaml"
Environment="CASC_JENKINS_CONFIG=/var/lib/jenkins/casc_configs/jenkins.yaml"
OVERRIDE_EOF

sudo cp /tmp/jenkins-override.conf /etc/systemd/system/jenkins.service.d/override.conf
sudo systemctl daemon-reload

# ─── Docker ──────────────────────────────────────────────────────────────────
echo "===> Installing Docker"
sudo apt install -y docker.io
sudo usermod -aG docker jenkins
sudo usermod -aG docker ubuntu
sudo systemctl enable docker
sudo systemctl restart docker
sudo chmod 777 /var/run/docker.sock

# ─── SonarQube (Docker container) ────────────────────────────────────────────
echo "===> Starting SonarQube container"
docker run -d --name sonar --restart unless-stopped \
  -p 9000:9000 \
  -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  sonarqube:lts-community

# ─── Sonar-Scanner ───────────────────────────────────────────────────────────
echo "===> Installing Sonar-Scanner"
cd /tmp
wget -q https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-5.0.1.3006-linux.zip
unzip -o sonar-scanner-cli-5.0.1.3006-linux.zip
sudo mv sonar-scanner-5.0.1.3006-linux /opt/sonar-scanner
sudo ln -sf /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner
rm -f sonar-scanner-cli-5.0.1.3006-linux.zip

# ─── AWS CLI ─────────────────────────────────────────────────────────────────
echo "===> Installing AWS CLI"
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -o /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install --update
rm -rf /tmp/awscliv2.zip /tmp/aws

# ─── kubectl ─────────────────────────────────────────────────────────────────
echo "===> Installing kubectl"
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

# ─── eksctl ──────────────────────────────────────────────────────────────────
echo "===> Installing eksctl"
ARCH=amd64 && PLATFORM=$(uname -s)_${ARCH}
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz"
tar -xzf "eksctl_${PLATFORM}.tar.gz" -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
rm -f "eksctl_${PLATFORM}.tar.gz"

# ─── Terraform ───────────────────────────────────────────────────────────────
echo "===> Installing Terraform"
wget -O- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update -y && sudo apt install -y terraform

# ─── Trivy ───────────────────────────────────────────────────────────────────
echo "===> Installing Trivy"
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
  | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] \
  https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" \
  | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt update -y && sudo apt install -y trivy

# ─── Helm ────────────────────────────────────────────────────────────────────
echo "===> Installing Helm"
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ─── NOW Start Jenkins (plugins + JCasC all in place) ────────────────────────
echo "===> Starting Jenkins with JCasC and pre-installed plugins"
sudo systemctl enable jenkins
sudo systemctl start jenkins

echo "========== All tools installed successfully =========="
echo ""
echo "NEXT STEPS:"
echo "  1. SSH into this server"
echo "  2. Generate a SonarQube token at http://<ip>:9000"
echo "  3. Run: sudo bash /opt/setup-jcasc.sh"
echo "  4. Jenkins will auto-configure with all credentials, jobs, and SonarQube"

# ─── Download setup-jcasc.sh from GitHub ─────────────────────────────────────
echo "===> Downloading setup-jcasc.sh"
sudo wget -q -O /opt/setup-jcasc.sh \
  "https://raw.githubusercontent.com/ibrahim-2010/cloud-native-eks/main/Jenkins-Server-TF/jcasc/setup-jcasc.sh"
sudo chmod +x /opt/setup-jcasc.sh
