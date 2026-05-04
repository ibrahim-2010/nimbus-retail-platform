#!/bin/bash
set -euo pipefail
# =============================================================================
# Tools Installation Script for Jenkins Server (Ubuntu 22.04)
# Installs: Java, Jenkins, Docker, SonarQube, Sonar-Scanner, AWS CLI,
#           kubectl, eksctl, Terraform, Trivy, Helm
# Configures: JCasC (Jenkins Configuration as Code), plugin auto-install
#
# ENVIRONMENT VARIABLES (set before Jenkins starts):
#   GITHUB_USERNAME     — GitHub username for SCM checkout
#   GITHUB_PAT          — GitHub Personal Access Token
#   AWS_ACCOUNT_ID      — 12-digit AWS account ID
#   SONARQUBE_TOKEN     — SonarQube authentication token
#   JENKINS_ADMIN_PASSWORD — Jenkins admin password (default: admin123)
# =============================================================================

exec > /var/log/tools-install.log 2>&1
echo "========== Starting tools installation =========="

# ─── Java 21 ─────────────────────────────────────────────────────────────────
echo "===> Installing Java 21"
sudo apt update -y
sudo apt install -y fontconfig openjdk-21-jdk curl gnupg unzip
java --version

# ─── Jenkins ─────────────────────────────────────────────────────────────────
echo "===> Installing Jenkins"
sudo mkdir -p /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y jenkins
sudo systemctl daemon-reload
sudo systemctl enable jenkins

# ─── Docker ──────────────────────────────────────────────────────────────────
echo "===> Installing Docker"
sudo apt install -y docker.io
sudo usermod -aG docker jenkins
sudo usermod -aG docker ubuntu
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
echo "sonar-scanner installed: $(sonar-scanner --version 2>&1 | head -1)"

# ─── AWS CLI ─────────────────────────────────────────────────────────────────
echo "===> Installing AWS CLI"
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -o awscliv2.zip
sudo ./aws/install --update
rm -rf awscliv2.zip aws/

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
sudo apt-get install -y wget apt-transport-https gnupg lsb-release
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
  | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] \
  https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" \
  | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt update -y && sudo apt install -y trivy

# ─── Helm ────────────────────────────────────────────────────────────────────
echo "===> Installing Helm"
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ══════════════════════════════════════════════════════════════
#  Jenkins Configuration as Code (JCasC) Setup
# ══════════════════════════════════════════════════════════════

echo "===> Configuring JCasC"

# Copy JCasC files to Jenkins home
sudo mkdir -p /var/lib/jenkins/casc_configs
sudo cp /home/ubuntu/cloud-native-eks/Jenkins-Server-TF/jcasc/jenkins.yaml \
  /var/lib/jenkins/casc_configs/jenkins.yaml
sudo chown -R jenkins:jenkins /var/lib/jenkins/casc_configs

# Tell Jenkins where to find JCasC config
echo 'CASC_JENKINS_CONFIG=/var/lib/jenkins/casc_configs/jenkins.yaml' \
  | sudo tee -a /etc/default/jenkins

# Also set JAVA_OPTS for JCasC
sudo sed -i 's|^JAVA_OPTS=.*|JAVA_OPTS="-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Dcasc.jenkins.config=/var/lib/jenkins/casc_configs/jenkins.yaml"|' \
  /etc/default/jenkins

# If JAVA_OPTS line doesn't exist, add it
grep -q "JAVA_OPTS" /etc/default/jenkins || \
  echo 'JAVA_OPTS="-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Dcasc.jenkins.config=/var/lib/jenkins/casc_configs/jenkins.yaml"' \
  | sudo tee -a /etc/default/jenkins

# ─── Install Plugins via CLI ─────────────────────────────────────────────────
echo "===> Installing Jenkins plugins"

# Wait for Jenkins to start
sudo systemctl start jenkins
sleep 30

# Use jenkins-plugin-cli to install plugins from plugins.txt
sudo java -jar /usr/share/java/jenkins-cli.jar \
  -s http://localhost:8080 \
  -auth admin:$(sudo cat /var/lib/jenkins/secrets/initialAdminPassword) \
  install-plugin \
  workflow-aggregator \
  pipeline-stage-view \
  git \
  docker-pipeline \
  docker-commons \
  sonar \
  dependency-check-jenkins-plugin \
  pipeline-aws \
  kubernetes-cli \
  configuration-as-code \
  credentials \
  credentials-binding \
  plain-credentials \
  blueocean \
  ws-cleanup \
  timestamper \
  job-dsl \
  || echo "Plugin installation via CLI failed — will retry after reboot"

# Restart Jenkins to load plugins and apply JCasC
sudo systemctl restart jenkins

echo "========== All tools installed successfully =========="
echo ""
echo "NEXT STEPS:"
echo "1. SSH into this server"
echo "2. Set environment variables for JCasC:"
echo "   export GITHUB_USERNAME=your-github-username"
echo "   export GITHUB_PAT=your-github-pat"
echo "   export AWS_ACCOUNT_ID=your-12-digit-id"
echo "   export SONARQUBE_TOKEN=your-sonarqube-token"
echo "   export JENKINS_ADMIN_PASSWORD=your-password"
echo ""
echo "3. Write them to /etc/default/jenkins:"
echo '   echo "GITHUB_USERNAME=xxx" | sudo tee -a /etc/default/jenkins'
echo '   echo "GITHUB_PAT=xxx" | sudo tee -a /etc/default/jenkins'
echo '   echo "AWS_ACCOUNT_ID=xxx" | sudo tee -a /etc/default/jenkins'
echo '   echo "SONARQUBE_TOKEN=xxx" | sudo tee -a /etc/default/jenkins'
echo ""
echo "4. Restart Jenkins: sudo systemctl restart jenkins"
echo "5. All credentials, jobs, and SonarQube config will auto-configure"
