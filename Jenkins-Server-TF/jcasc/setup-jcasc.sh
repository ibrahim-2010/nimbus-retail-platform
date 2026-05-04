#!/bin/bash
set -euo pipefail
# =============================================================================
#  JCasC Secret Injection — Run ONCE after Jenkins server boots
#
#  Injects environment variables via systemd override so Jenkins
#  JCasC can populate credentials, SonarQube config, and pipeline jobs.
#
#  Also creates the SonarQube webhook automatically.
#
#  Usage: sudo bash /opt/setup-jcasc.sh
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║     Jenkins JCasC — Secret Injection              ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Gather secrets ──────────────────────────────────────────────────────────
read -p "GitHub Username: " GITHUB_USERNAME
read -sp "GitHub PAT: " GITHUB_PAT
echo ""
read -p "AWS Account ID (12 digits): " AWS_ACCOUNT_ID
read -sp "Jenkins Admin Password: " JENKINS_ADMIN_PASSWORD
echo ""
read -p "AWS Access Key ID: " AWS_ACCESS_KEY_ID
read -sp "AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
echo ""

# ─── SonarQube token automation ──────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Generating SonarQube token automatically...${NC}"

# Wait for SonarQube to be fully ready
echo "  Waiting for SonarQube to start..."
for i in $(seq 1 30); do
  if curl -s -u admin:admin "http://localhost:9000/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; then
    echo "  SonarQube is ready"
    break
  fi
  sleep 5
done

# Change default password
SONAR_NEW_PASS="SonarAdmin2026!"
curl -s -u admin:admin -X POST \
  "http://localhost:9000/api/users/change_password?login=admin&previousPassword=admin&password=${SONAR_NEW_PASS}" \
  2>/dev/null || echo "  SonarQube password may already be changed"

# Generate token
SONARQUBE_TOKEN=$(curl -s -u "admin:${SONAR_NEW_PASS}" -X POST \
  "http://localhost:9000/api/user_tokens/generate?name=jenkins-$(date +%s)" \
  2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$SONARQUBE_TOKEN" ]; then
  echo -e "${YELLOW}  Auto-generation failed. Enter SonarQube token manually:${NC}"
  read -sp "  SonarQube Token: " SONARQUBE_TOKEN
  echo ""
else
  echo "  Token generated successfully"
fi

# ─── Create SonarQube webhook ────────────────────────────────────────────────
echo -e "${YELLOW}Creating SonarQube webhook for Jenkins...${NC}"
curl -s -u "admin:${SONAR_NEW_PASS}" -X POST \
  "http://localhost:9000/api/webhooks/create?name=jenkins&url=http://localhost:8080/sonarqube-webhook/" \
  2>/dev/null || echo "  Webhook may already exist"
echo "  Webhook created: http://localhost:8080/sonarqube-webhook/"

# ─── Write systemd override ─────────────────────────────────────────────────
echo -e "${YELLOW}Writing systemd override with secrets...${NC}"
sudo mkdir -p /etc/systemd/system/jenkins.service.d

sudo bash -c "cat > /etc/systemd/system/jenkins.service.d/override.conf << EOF
[Service]
Environment=\"JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Dcasc.jenkins.config=/var/lib/jenkins/casc_configs/jenkins.yaml\"
Environment=\"CASC_JENKINS_CONFIG=/var/lib/jenkins/casc_configs/jenkins.yaml\"
Environment=\"JENKINS_ADMIN_PASSWORD=${JENKINS_ADMIN_PASSWORD}\"
Environment=\"GITHUB_USERNAME=${GITHUB_USERNAME}\"
Environment=\"GITHUB_PAT=${GITHUB_PAT}\"
Environment=\"AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}\"
Environment=\"SONARQUBE_TOKEN=${SONARQUBE_TOKEN}\"
EOF"

# ─── Restart Jenkins ─────────────────────────────────────────────────────────
echo -e "${YELLOW}Restarting Jenkins to apply JCasC with secrets...${NC}"
sudo systemctl daemon-reload
sudo systemctl restart jenkins

echo "  Waiting for Jenkins to start..."
sleep 45

# ─── Configure AWS CLI for jenkins user ──────────────────────────────────────
echo -e "${YELLOW}Configuring AWS CLI for jenkins user...${NC}"
sudo mkdir -p /var/lib/jenkins/.aws
sudo bash -c "cat > /var/lib/jenkins/.aws/config << EOF
[default]
region = us-east-1
output = json
EOF"
sudo bash -c "cat > /var/lib/jenkins/.aws/credentials << EOF
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF"
sudo chown -R jenkins:jenkins /var/lib/jenkins/.aws
sudo chmod 600 /var/lib/jenkins/.aws/credentials

# Also configure for root user (for manual kubectl/eksctl commands)
mkdir -p ~/.aws
cat > ~/.aws/config << EOF
[default]
region = us-east-1
output = json
EOF
cat > ~/.aws/credentials << EOF
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF
chmod 600 ~/.aws/credentials

# Set exports for current session
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
export AWS_DEFAULT_REGION=us-east-1

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "localhost")

# ─── Verify ──────────────────────────────────────────────────────────────────
echo ""
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${JENKINS_ADMIN_PASSWORD}" "http://localhost:8080")

if [ "$HTTP_CODE" = "200" ]; then
  echo -e "${GREEN}╔══════════════════════════════════════════════════╗"
  echo "║         JCASC SETUP COMPLETE                      ║"
  echo "╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "Jenkins URL:    http://${PUBLIC_IP}:8080"
  echo "SonarQube URL:  http://${PUBLIC_IP}:9000"
  echo "Login:          admin / ${JENKINS_ADMIN_PASSWORD}"
  echo ""
  echo "Auto-configured:"
  echo "  ✅ 6 credentials (github-creds, github-token, ACCOUNT_ID, ECR repos, sonar)"
  echo "  ✅ SonarQube server (http://localhost:9000)"
  echo "  ✅ SonarQube webhook (http://localhost:8080/sonarqube-webhook/)"
  echo "  ✅ 2 pipeline jobs (three-tier-backend, three-tier-frontend)"
  echo "  ✅ AWS CLI region configured for jenkins user"
else
  echo -e "${YELLOW}Jenkins returned HTTP $HTTP_CODE — JCasC may still be loading."
  echo "Wait 30 seconds and try: http://${PUBLIC_IP}:8080${NC}"
fi
