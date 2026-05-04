#!/bin/bash
# =============================================================================
# JCasC Environment Setup — Run this ONCE after Jenkins server boots
# Sets the environment variables that JCasC uses to populate credentials
# =============================================================================

echo "=================================="
echo "  Jenkins JCasC Environment Setup"
echo "=================================="
echo ""

# Prompt for values
read -p "GitHub Username: " GITHUB_USERNAME
read -sp "GitHub PAT: " GITHUB_PAT
echo ""
read -p "AWS Account ID (12 digits): " AWS_ACCOUNT_ID
read -sp "SonarQube Token: " SONARQUBE_TOKEN
echo ""
read -sp "Jenkins Admin Password: " JENKINS_ADMIN_PASSWORD
echo ""

# Write to Jenkins environment file
sudo bash -c "cat >> /etc/default/jenkins << EOF
GITHUB_USERNAME=${GITHUB_USERNAME}
GITHUB_PAT=${GITHUB_PAT}
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}
SONARQUBE_TOKEN=${SONARQUBE_TOKEN}
JENKINS_ADMIN_PASSWORD=${JENKINS_ADMIN_PASSWORD}
EOF"

echo ""
echo "Environment variables written to /etc/default/jenkins"
echo "Restarting Jenkins to apply JCasC..."

sudo systemctl restart jenkins

echo ""
echo "Done! Jenkins will configure itself with:"
echo "  - 6 credentials (github-creds, github-token, ACCOUNT_ID, ECR repos, sonar)"
echo "  - SonarQube server (http://localhost:9000)"
echo "  - 2 pipeline jobs (three-tier-backend, three-tier-frontend)"
echo ""
echo "Access Jenkins at: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):8080"
echo "Login: admin / ${JENKINS_ADMIN_PASSWORD}"
