#!/bin/bash

# ==================================================================
# Validation script for rds-snapshots-share
# ==================================================================

# Function to print error messages and exit
error_exit() {
    echo "❌ ERROR: $1"
    exit 1
}

# Source the configuration file
if [ -f ".env" ]; then
    source .env
else
    error_exit "Configuration file '.env' not found."
fi

echo "🔍 Starting configuration validation..."

# 1. Validate AWS Profiles and Account IDs
echo "[1/5] Validating AWS profiles and account IDs..."
FROM_ID=$(aws sts get-caller-identity --profile "$FROM_ACCOUNT_PROFILE" --region "$FROM_REGION" --query Account --output text 2>/dev/null | tr -d '[:space:]')
if [ -z "$FROM_ID" ]; then
    error_exit "Profile '$FROM_ACCOUNT_PROFILE' is not valid or not logged in."
fi
if [ "$FROM_ID" != "$FROM_ACCOUNT_ID" ]; then
    error_exit "Account ID for profile '$FROM_ACCOUNT_PROFILE' ('$FROM_ID') does not match expected FROM_ACCOUNT_ID ('$FROM_ACCOUNT_ID')."
fi
echo "  ✅ Source profile and account ID are valid."

TO_ID=$(aws sts get-caller-identity --profile "$TO_ACCOUNT_PROFILE" --region "$TO_REGION" --query Account --output text 2>/dev/null | tr -d '[:space:]')
if [ -z "$TO_ID" ]; then
    error_exit "Profile '$TO_ACCOUNT_PROFILE' is not valid or not logged in."
fi
if [ "$TO_ID" != "$TO_ACCOUNT_ID" ]; then
    error_exit "Account ID for profile '$TO_ACCOUNT_PROFILE' ('$TO_ID') does not match expected TO_ACCOUNT_ID ('$TO_ACCOUNT_ID')."
fi
echo "  ✅ Destination profile and account ID are valid."

# 2. Validate RDS Clusters in Source Account
echo "[2/5] Validating source RDS clusters..."
for db in "${RDS[@]}"; do
    if ! aws rds describe-db-clusters --profile "$FROM_ACCOUNT_PROFILE" --region "$FROM_REGION" --db-cluster-identifier "$db" >/dev/null 2>&1; then
        error_exit "RDS cluster '$db' not found in region '$FROM_REGION' for profile '$FROM_ACCOUNT_PROFILE'."
    fi
done
echo "  ✅ All source RDS clusters were found."

# 3. Validate Destination Security Group and Subnet Group
echo "[3/5] Validating destination Security Group and DB Subnet Group..."
SG_DETAILS=$(aws ec2 describe-security-groups --profile "$TO_ACCOUNT_PROFILE" --region "$TO_REGION" --group-ids "$TO_SG_ID" --output json 2>/dev/null)
if [ -z "$SG_DETAILS" ] || [ "$(echo "$SG_DETAILS" | jq '.SecurityGroups | length')" -eq 0 ]; then
    error_exit "Security Group '$TO_SG_ID' not found in region '$TO_REGION'."
fi
SG_VPC_ID=$(echo "$SG_DETAILS" | jq -r '.SecurityGroups[0].VpcId')
echo "  ✅ Security Group '$TO_SG_ID' found in VPC '$SG_VPC_ID'."

SUBNET_GROUP_DETAILS=$(aws rds describe-db-subnet-groups --profile "$TO_ACCOUNT_PROFILE" --region "$TO_REGION" --db-subnet-group-name "$DB_SUBNET_GROUP" --output json 2>/dev/null)
if [ -z "$SUBNET_GROUP_DETAILS" ] || [ "$(echo "$SUBNET_GROUP_DETAILS" | jq '.DBSubnetGroups | length')" -eq 0 ]; then
    error_exit "DB Subnet Group '$DB_SUBNET_GROUP' not found in region '$TO_REGION'."
fi
SUBNET_GROUP_VPC_ID=$(echo "$SUBNET_GROUP_DETAILS" | jq -r '.DBSubnetGroups[0].VpcId')
echo "  ✅ DB Subnet Group '$DB_SUBNET_GROUP' found in VPC '$SUBNET_GROUP_VPC_ID'."

# 4. Validate VPC and Subnet Consistency
echo "[4/5] Validating VPC and subnet consistency..."
if [ "$SG_VPC_ID" != "$SUBNET_GROUP_VPC_ID" ]; then
    error_exit "VPC mismatch: Security Group is in VPC '$SG_VPC_ID' but DB Subnet Group is in VPC '$SUBNET_GROUP_VPC_ID'."
fi
echo "  ✅ Security Group and DB Subnet Group are in the same VPC."

# 5. Validate Security Group Inbound Rule for PostgreSQL
echo "[5/5] Validating Security Group inbound rules for PostgreSQL (port 5432)..."
VPC_CIDR=$(aws ec2 describe-vpcs --profile "$TO_ACCOUNT_PROFILE" --region "$TO_REGION" --vpc-ids "$SG_VPC_ID" --query "Vpcs[0].CidrBlock" --output text)

RULE_FOUND=$(echo "$SG_DETAILS" | jq -r --arg vpc_cidr "$VPC_CIDR" '.SecurityGroups[0].IpPermissions[] | select(.FromPort == 5432 and .ToPort == 5432 and (.IpRanges[].CidrIp == $vpc_cidr)) | .FromPort')

if [ "$RULE_FOUND" != "5432" ]; then
    error_exit "No inbound rule found in Security Group '$TO_SG_ID' allowing TCP traffic on port 5432 from the VPC CIDR '$VPC_CIDR'."
fi
echo "  ✅ Inbound rule for port 5432 from VPC CIDR '$VPC_CIDR' is correctly configured."

echo -e "\n\033[1;32m✅ All configurations validated successfully!\033[0m"
