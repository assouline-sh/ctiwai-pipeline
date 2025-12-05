#!/bin/bash
# scripts/deploy-opencti.sh
# Simple deployment script for budget OpenCTI setup

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}OpenCTI Budget Deployment${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v terraform &> /dev/null; then
    echo -e "${RED}Error: Terraform not installed${NC}"
    echo "Install from: https://www.terraform.io/downloads"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not installed${NC}"
    echo "Install from: https://aws.amazon.com/cli/"
    exit 1
fi

if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}Error: AWS credentials not configured${NC}"
    echo "Run: aws configure"
    exit 1
fi

echo -e "${GREEN}✓ All prerequisites met${NC}"
echo ""

# Navigate to terraform directory
TERRAFORM_DIR="infrastructure/terraform/environments/dev"

if [ ! -d "$TERRAFORM_DIR" ]; then
    echo -e "${RED}Error: Terraform directory not found${NC}"
    echo "Expected: $TERRAFORM_DIR"
    exit 1
fi

cd "$TERRAFORM_DIR"

# Check if terraform.tfvars exists
if [ ! -f "terraform.tfvars" ]; then
    echo -e "${RED}Error: terraform.tfvars not found${NC}"
    echo ""
    echo "Create it from the template:"
    echo "  cp terraform.tfvars.example terraform.tfvars"
    echo ""
    echo "Then generate credentials:"
    echo "  Password: openssl rand -base64 32"
    echo "  Token: uuidgen"
    echo "  SSH Key: ssh-keygen -t rsa -b 4096 -f ~/.ssh/opencti-key"
    exit 1
fi

echo -e "${YELLOW}Initializing Terraform...${NC}"
terraform init

echo ""
echo -e "${YELLOW}Planning deployment...${NC}"
terraform plan

echo ""
read -p "Deploy OpenCTI? This will create AWS resources (~$22/month). (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo -e "${RED}Deployment cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Deploying OpenCTI...${NC}"
echo -e "${YELLOW}This takes about 5 minutes...${NC}"
terraform apply -auto-approve

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

PUBLIC_IP=$(terraform output -raw public_ip)
OPENCTI_URL=$(terraform output -raw opencti_url)
SSH_COMMAND=$(terraform output -raw ssh_command)

echo -e "${GREEN}OpenCTI URL:${NC} $OPENCTI_URL"
echo -e "${GREEN}SSH Access:${NC} $SSH_COMMAND"
echo ""
echo -e "${YELLOW}⏱️  OpenCTI is installing (takes 10-15 minutes)${NC}"
echo ""
echo "Monitor installation:"
echo "  ssh -i ~/.ssh/opencti-key ubuntu@$PUBLIC_IP"
echo "  sudo tail -f /var/log/user-data.log"
echo ""
echo "Check when ready:"
echo "  docker ps"
echo ""
echo -e "${GREEN}Once ready, access OpenCTI at: $OPENCTI_URL${NC}"
