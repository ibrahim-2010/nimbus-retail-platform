#!/bin/bash
set -uo pipefail
# =============================================================================
#  Cloud-Native EKS — Full Stack Destroy Script
#
#  Handles all teardown issues discovered across 4 deployment cycles:
#    - Helm monitoring uninstall BEFORE namespace deletion
#    - Prometheus/Alertmanager CRD cleanup (prevents namespace finalizer hang)
#    - ExternalDNS Route 53 record cleanup (prevents hosted zone deletion)
#    - VPC dependency cleanup (security groups, ENIs, load balancers)
#    - Namespace finalizer removal (prevents Terraform timeout)
#
#  Usage: bash destroy.sh [--skip-confirmation]
#  Run from the repo root directory on a machine with kubectl + AWS CLI access
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLUSTER_NAME="cloud-native-cluster"
REGION="us-east-1"

echo -e "${RED}"
echo "╔══════════════════════════════════════════════════╗"
echo "║         FULL STACK DESTROY                       ║"
echo "║  This will DELETE all AWS resources.              ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

if [[ "${1:-}" != "--skip-confirmation" ]]; then
  read -p "Are you sure? Type 'destroy' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "destroy" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""

# ──────────────────────────────────────────────
#  Phase 1: ArgoCD Applications
# ──────────────────────────────────────────────
echo -e "${YELLOW}[1/9] Deleting ArgoCD applications...${NC}"
# Remove finalizers first to prevent hanging
for app in $(kubectl get applications -n argocd -o name 2>/dev/null); do
  kubectl patch $app -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
done
kubectl delete applications --all -n argocd --timeout=60s 2>/dev/null || echo "  No ArgoCD apps found"

# ──────────────────────────────────────────────
#  Phase 2: Monitoring Stack (Helm + CRDs)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[2/9] Deleting monitoring stack...${NC}"

# Uninstall Helm release FIRST (removes Prometheus/Alertmanager instances)
helm uninstall monitoring -n monitoring 2>/dev/null || echo "  No monitoring Helm release"

# Delete Prometheus/Alertmanager custom resources
kubectl delete prometheuses --all -n monitoring 2>/dev/null
kubectl delete alertmanagers --all -n monitoring 2>/dev/null

# Delete ALL monitoring CRDs (removes finalizers that block namespace deletion)
echo "  Cleaning up monitoring CRDs..."
for crd in prometheuses.monitoring.coreos.com \
           alertmanagers.monitoring.coreos.com \
           thanosrulers.monitoring.coreos.com \
           prometheusagents.monitoring.coreos.com \
           scrapeconfigs.monitoring.coreos.com \
           servicemonitors.monitoring.coreos.com \
           podmonitors.monitoring.coreos.com \
           prometheusrules.monitoring.coreos.com \
           probes.monitoring.coreos.com; do
  kubectl delete crd "$crd" 2>/dev/null && echo "  Deleted CRD: $crd"
done

# Force delete monitoring namespace if stuck
kubectl patch namespace monitoring -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
kubectl delete namespace monitoring --timeout=30s 2>/dev/null || echo "  Monitoring namespace already gone"
sleep 10

# ──────────────────────────────────────────────
#  Phase 3: ArgoCD
# ──────────────────────────────────────────────
echo -e "${YELLOW}[3/9] Deleting ArgoCD...${NC}"
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --timeout=60s 2>/dev/null || echo "  ArgoCD already removed"
kubectl patch namespace argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
kubectl delete namespace argocd --timeout=30s 2>/dev/null || echo "  ArgoCD namespace already gone"

# ──────────────────────────────────────────────
#  Phase 4: Application Resources
# ──────────────────────────────────────────────
echo -e "${YELLOW}[4/9] Deleting application resources...${NC}"
kubectl delete ingress --all -n three-tier 2>/dev/null || echo "  No ingress found"
kubectl delete ingress --all -n monitoring 2>/dev/null || echo "  No monitoring ingress found"
echo "  Waiting 60s for ALB cleanup..."
sleep 60
kubectl delete all --all -n three-tier 2>/dev/null || echo "  Namespace already clean"
kubectl delete pvc --all -n three-tier 2>/dev/null || echo "  No PVCs found"
kubectl delete secrets --all -n three-tier 2>/dev/null || echo "  No secrets found"

# ──────────────────────────────────────────────
#  Phase 5: Route 53 Record Cleanup
# ──────────────────────────────────────────────
echo -e "${YELLOW}[5/9] Cleaning up Route 53 records...${NC}"
ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='platinum-consults.com.'].Id" --output text --region $REGION 2>/dev/null | sed 's|/hostedzone/||')

if [ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ]; then
  echo "  Found hosted zone: $ZONE_ID"
  
  # Get all non-essential records and delete them
  RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Type!='NS' && Type!='SOA']" --output json 2>/dev/null)
  
  RECORD_COUNT=$(echo "$RECORDS" | grep -c '"Name"' 2>/dev/null || echo "0")
  
  if [ "$RECORD_COUNT" -gt 0 ]; then
    echo "  Deleting $RECORD_COUNT records..."
    
    # Build change batch
    CHANGE_BATCH=$(echo "$RECORDS" | python -c "
import json, sys
records = json.load(sys.stdin)
changes = [{'Action':'DELETE','ResourceRecordSet':r} for r in records]
print(json.dumps({'Changes': changes}))
" 2>/dev/null || echo "")
    
    if [ -n "$CHANGE_BATCH" ]; then
      echo "$CHANGE_BATCH" | aws route53 change-resource-record-sets \
        --hosted-zone-id "$ZONE_ID" --change-batch file:///dev/stdin 2>/dev/null \
        && echo "  Records deleted" \
        || echo "  Record deletion failed — may need manual cleanup"
    fi
    sleep 10
  else
    echo "  No extra records to delete"
  fi
else
  echo "  No hosted zone found — skipping"
fi

# ──────────────────────────────────────────────
#  Phase 6: VPC Dependency Cleanup
# ──────────────────────────────────────────────
echo -e "${YELLOW}[6/9] Cleaning up VPC dependencies...${NC}"

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=cloud-native-eks" \
  --query "Vpcs[0].VpcId" --output text --region $REGION 2>/dev/null)

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "  Found VPC: $VPC_ID"
  
  # Delete load balancers
  for ALB_ARN in $(aws elbv2 describe-load-balancers --region $REGION \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do
    echo "  Deleting ALB: $ALB_ARN"
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region $REGION 2>/dev/null
  done
  
  # Wait for ALBs to fully delete
  sleep 30
  
  # Delete ENIs
  for ENI_ID in $(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $REGION 2>/dev/null); do
    echo "  Deleting ENI: $ENI_ID"
    aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region $REGION 2>/dev/null
  done
  
  # Delete non-default security groups
  for SG_ID in $(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region $REGION 2>/dev/null); do
    echo "  Deleting SG: $SG_ID"
    aws ec2 delete-security-group --group-id "$SG_ID" --region $REGION 2>/dev/null
  done
else
  echo "  No project VPC found — skipping"
fi

# ──────────────────────────────────────────────
#  Phase 7: EKS Infrastructure (Terraform)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[7/9] Destroying EKS infrastructure (Terraform)...${NC}"
if [ -d "EKS-Terraform" ]; then
  cd EKS-Terraform
  
  # Remove stuck resources from state
  terraform state rm kubernetes_namespace.monitoring 2>/dev/null
  terraform state rm kubernetes_namespace.argocd 2>/dev/null
  terraform state rm kubernetes_namespace.three_tier 2>/dev/null
  
  terraform init 2>/dev/null
  terraform destroy -auto-approve || echo "  Terraform destroy had errors — check manually"
  cd ..
elif [ -d "../EKS-Terraform" ]; then
  cd ../EKS-Terraform
  terraform state rm kubernetes_namespace.monitoring 2>/dev/null
  terraform state rm kubernetes_namespace.argocd 2>/dev/null
  terraform state rm kubernetes_namespace.three_tier 2>/dev/null
  terraform init 2>/dev/null
  terraform destroy -auto-approve || echo "  Terraform destroy had errors — check manually"
  cd ..
else
  echo "  EKS-Terraform directory not found — skipping"
fi

# ──────────────────────────────────────────────
#  Phase 8: ECR Repositories
# ──────────────────────────────────────────────
echo -e "${YELLOW}[8/9] Deleting ECR repositories...${NC}"
aws ecr delete-repository --repository-name frontend --region $REGION --force 2>/dev/null \
  && echo "  Deleted: frontend" || echo "  frontend already deleted"
aws ecr delete-repository --repository-name backend --region $REGION --force 2>/dev/null \
  && echo "  Deleted: backend" || echo "  backend already deleted"

# ──────────────────────────────────────────────
#  Phase 9: Jenkins Server (Terraform)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[9/9] Destroying Jenkins server (Terraform)...${NC}"
if [ -d "Jenkins-Server-TF" ]; then
  cd Jenkins-Server-TF
  terraform init 2>/dev/null
  terraform destroy -auto-approve || echo "  Terraform destroy had errors — check manually"
  cd ..
elif [ -d "../Jenkins-Server-TF" ]; then
  cd ../Jenkins-Server-TF
  terraform init 2>/dev/null
  terraform destroy -auto-approve || echo "  Terraform destroy had errors — check manually"
  cd ..
else
  echo "  Jenkins-Server-TF directory not found — skipping"
fi

# ──────────────────────────────────────────────
#  Final Cleanup Check
# ──────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Running final verification...${NC}"
echo ""

INSTANCES=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text --region $REGION 2>/dev/null)
CLUSTERS=$(aws eks list-clusters --query "clusters" --output text --region $REGION 2>/dev/null)
VPCS=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=false" \
  --query "Vpcs[].VpcId" --output text --region $REGION 2>/dev/null)
ELBS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[].DNSName" \
  --output text --region $REGION 2>/dev/null)
NATS=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
  --query "NatGateways[].NatGatewayId" --output text --region $REGION 2>/dev/null)
EIPS=$(aws ec2 describe-addresses --query "Addresses[].AllocationId" \
  --output text --region $REGION 2>/dev/null)

ALL_CLEAN=true

if [ -n "$INSTANCES" ]; then
  echo -e "  ${RED}⚠ Running instances found: $INSTANCES${NC}"
  ALL_CLEAN=false
else
  echo -e "  ${GREEN}✅ No running instances${NC}"
fi

if [ -n "$CLUSTERS" ]; then
  echo -e "  ${RED}⚠ EKS clusters found: $CLUSTERS${NC}"
  ALL_CLEAN=false
else
  echo -e "  ${GREEN}✅ No EKS clusters${NC}"
fi

if [ -n "$VPCS" ]; then
  echo -e "  ${RED}⚠ Non-default VPCs found: $VPCS${NC}"
  ALL_CLEAN=false
else
  echo -e "  ${GREEN}✅ No custom VPCs${NC}"
fi

if [ -n "$ELBS" ]; then
  echo -e "  ${RED}⚠ Load balancers found: $ELBS${NC}"
  ALL_CLEAN=false
else
  echo -e "  ${GREEN}✅ No load balancers${NC}"
fi

if [ -n "$NATS" ]; then
  echo -e "  ${RED}⚠ NAT gateways found: $NATS${NC}"
  ALL_CLEAN=false
else
  echo -e "  ${GREEN}✅ No NAT gateways${NC}"
fi

if [ -n "$EIPS" ]; then
  echo -e "  ${RED}⚠ Elastic IPs found: $EIPS${NC}"
  ALL_CLEAN=false
else
  echo -e "  ${GREEN}✅ No Elastic IPs${NC}"
fi

echo ""
if [ "$ALL_CLEAN" = true ]; then
  echo -e "${GREEN}╔══════════════════════════════════════════════════╗"
  echo "║         DESTROY COMPLETE — ALL CLEAN              ║"
  echo "╚══════════════════════════════════════════════════╝${NC}"
else
  echo -e "${RED}╔══════════════════════════════════════════════════╗"
  echo "║   DESTROY COMPLETE — SOME RESOURCES REMAIN       ║"
  echo "║   Check items marked with ⚠ above                ║"
  echo "╚══════════════════════════════════════════════════╝${NC}"
fi

echo ""
echo "Note: S3 bucket and DynamoDB table are preserved for future deployments."
echo "To delete them permanently:"
echo "  aws s3 rb s3://ibrahim-cloud-native-tf-state --force"
echo "  aws dynamodb delete-table --table-name ibrahim-cloud-native-tf-lock --region $REGION"