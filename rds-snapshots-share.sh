#!/bin/bash

# ================================================================== 
# Script to share and restore RDS snapshots between AWS accounts
# ==================================================================

# Configuration - MUST BE DEFINED BEFORE RUNNING
RDS=()

FROM_ACCOUNT_PROFILE=""
FROM_ACCOUNT_ID=""
FROM_REGION=""

TO_ACCOUNT_PROFILE=""
TO_ACCOUNT_ID=""
TO_REGION=""
TO_SG_ID=""
DB_SUBNET_GROUP=""

MASTER_PASSWORD=""

# Validate required variables
if [ -z "$FROM_ACCOUNT_PROFILE" ] || [ -z "$FROM_ACCOUNT_ID" ] || [ -z "$FROM_REGION" ] || \
   [ -z "$TO_ACCOUNT_PROFILE" ] || [ -z "$TO_ACCOUNT_ID" ] || [ -z "$TO_REGION" ] || \
   [ -z "$TO_SG_ID" ] || [ -z "$DB_SUBNET_GROUP" ] || [ -z "$MASTER_PASSWORD" ] || \
   [ ${#RDS[@]} -eq 0 ]; then
    echo "❌ ERROR: Required variables not configured"
    echo ""
    echo "Please define the following variables before running:"
    echo "  • RDS=(\"db1\" \"db2\" \"db3\")"
    echo "  • FROM_ACCOUNT_PROFILE=\"source-profile\""
    echo "  • FROM_ACCOUNT_ID=\"123456789012\""
    echo "  • FROM_REGION=\"us-east-1\""
    echo "  • TO_ACCOUNT_PROFILE=\"destination-profile\""
    echo "  • TO_ACCOUNT_ID=\"210987654321\""
    echo "  • TO_REGION=\"us-east-2\""
    echo "  • TO_SG_ID=\"sg-xxxxxxxxx\""
    echo "  • DB_SUBNET_GROUP=\"subnet-group-name\""
    echo "  • MASTER_PASSWORD=\"secure-password\""
    echo ""
    exit 1
fi

# Function to check snapshots in progress
check_snapshots_in_progress() {
    local profile=$1
    local region=$2
    
    echo "🔍 Checking snapshots in progress in account $profile ($region)..."
    
    local creating_snapshots
    creating_snapshots=$(aws rds --no-cli-pager describe-db-cluster-snapshots --profile "$profile" --region "$region" \
        --query "DBClusterSnapshots[?Status=='creating' || Status=='copying'].{ID:DBClusterSnapshotIdentifier,Status:Status,Progress:PercentProgress,Engine:Engine}" \
        --output table 2>/dev/null || true)
    
    if [[ -n "$creating_snapshots" && "$creating_snapshots" != *"None"* ]]; then
        echo "📸 Cluster snapshots in progress:"
        echo "$creating_snapshots"
        echo ""
    fi
    
    local creating_db_snapshots
    creating_db_snapshots=$(aws rds --no-cli-pager describe-db-snapshots --profile "$profile" --region "$region" \
        --query "DBSnapshots[?Status=='creating' || Status=='copying'].{ID:DBSnapshotIdentifier,Status:Status,Progress:PercentProgress,Engine:Engine}" \
        --output table 2>/dev/null || true)
    
    if [[ -n "$creating_db_snapshots" && "$creating_db_snapshots" != *"None"* ]]; then
        echo "📸 Instance snapshots in progress:"
        echo "$creating_db_snapshots"
        echo ""
    fi
}

# Function to configure KMS permissions temporarily
configure_kms_permissions() {
    local kms_key_id="$1"
    
    echo "🔐 Configuring temporary KMS permissions..."
    
    echo "Saving current KMS policy..."
    aws kms --no-cli-pager get-key-policy \
        --key-id "$kms_key_id" \
        --policy-name default \
        --profile "$FROM_ACCOUNT_PROFILE" \
        --region "$FROM_REGION" \
        --output json > /tmp/kms-policy-backup.json
    
    if [ $? -ne 0 ]; then
        echo "❌ Error saving current KMS policy"
        return 1
    fi
    
    cat > /tmp/kms-policy-temp.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::$FROM_ACCOUNT_ID:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowCrossAccountAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::$TO_ACCOUNT_ID:root"
      },
      "Action": [
        "kms:Decrypt",
        "kms:CreateGrant",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    }
  ]
}
EOF
    
    echo "Applying temporary KMS policy..."
    aws kms --no-cli-pager put-key-policy \
        --key-id "$kms_key_id" \
        --policy-name default \
        --policy file:///tmp/kms-policy-temp.json \
        --profile "$FROM_ACCOUNT_PROFILE" \
        --region "$FROM_REGION"
    
    if [ $? -eq 0 ]; then
        echo "✅ Temporary KMS policy configured"
        return 0
    else
        echo "❌ Error configuring temporary KMS policy"
        return 1
    fi
}

# Function to restore original KMS permissions
restore_kms_permissions() {
    local kms_key_id="$1"
    
    echo "🔐 Restoring original KMS policy..."
    
    if [ -f "/tmp/kms-policy-backup.json" ]; then
        jq -r '.Policy' /tmp/kms-policy-backup.json > /tmp/kms-policy-restore.json
        
        aws kms --no-cli-pager put-key-policy \
            --key-id "$kms_key_id" \
            --policy-name default \
            --policy file:///tmp/kms-policy-restore.json \
            --profile "$FROM_ACCOUNT_PROFILE" \
            --region "$FROM_REGION"
        
        if [ $? -eq 0 ]; then
            echo "✅ Original KMS policy restored"
        else
            echo "⚠️  Error restoring original KMS policy"
            echo "⚠️  Backup saved at: /tmp/kms-policy-backup.json"
        fi
        
        rm -f /tmp/kms-policy-temp.json /tmp/kms-policy-restore.json
    else
        echo "⚠️  KMS policy backup file not found"
    fi
}

# Basic validations
echo "Checking dependencies..."
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI not found. Please install AWS CLI."
    exit 1
fi

echo "Checking AWS profiles..."
if ! aws configure list --profile "$FROM_ACCOUNT_PROFILE" &> /dev/null; then
    echo "❌ Profile '$FROM_ACCOUNT_PROFILE' not found. Configure the profile first."
    echo "   Run: aws configure --profile $FROM_ACCOUNT_PROFILE"
    exit 1
fi

if ! aws configure list --profile "$TO_ACCOUNT_PROFILE" &> /dev/null; then
    echo "❌ Profile '$TO_ACCOUNT_PROFILE' not found. Configure the profile first."
    echo "   Run: aws configure --profile $TO_ACCOUNT_PROFILE"
    exit 1
fi

echo "✅ Dependencies verified."
echo "⚠️  This script will process ${#RDS[@]} databases."
echo "⚠️  Source account: $FROM_ACCOUNT_PROFILE ($FROM_REGION)"
echo "⚠️  Destination account: $TO_ACCOUNT_PROFILE ($TO_REGION)"
echo ""

check_snapshots_in_progress "$FROM_ACCOUNT_PROFILE" "$FROM_REGION"
check_snapshots_in_progress "$TO_ACCOUNT_PROFILE" "$TO_REGION"

echo "💡 For large clusters (>100GB), the process may take several hours"
echo "💡 You can monitor progress in AWS Console: RDS > Snapshots"
echo ""
echo "ℹ️  The script automatically skips already migrated databases"
echo ""
read -p "Do you want to continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

echo "🔍 Discovering cluster KMS key..."
FIRST_DB="${RDS[0]}"
KMS_KEY_ID=$(aws rds --no-cli-pager describe-db-clusters \
    --db-cluster-identifier "$FIRST_DB" \
    --profile "$FROM_ACCOUNT_PROFILE" \
    --region "$FROM_REGION" \
    --query 'DBClusters[0].KmsKeyId' \
    --output text \
    --no-cli-pager)

if [ -z "$KMS_KEY_ID" ] || [ "$KMS_KEY_ID" = "None" ]; then
    echo "❌ Could not discover cluster KMS key"
    exit 1
fi

echo "KMS key found: $KMS_KEY_ID"

if ! configure_kms_permissions "$KMS_KEY_ID"; then
    echo "❌ Failed to configure KMS permissions"
    exit 1
fi

cleanup() {
    echo "🛑 Cleanup in progress..."
    if [ -n "$KMS_KEY_ID" ]; then
        restore_kms_permissions "$KMS_KEY_ID"
    fi
    exit 1
}

trap cleanup INT TERM

PROCESSED_COUNT=0
SUCCESS_COUNT=0
FAILED_DATABASES=()

for db in "${RDS[@]}"; do
    CLUSTER_ID="${db}-sandbox-$(date +%Y%m%d%H%M)"
    INSTANCE_ID="${db}-instance-sandbox-$(date +%Y%m%d%H%M)"
    SNAPSHOT_COPY="${db}-copy-$(date +%Y%m%d%H%M)"
    MANUAL_SNAPSHOT="${db}-manual-$(date +%Y%m%d%H%M)"
    SNAPSHOT_CROSS_ACCOUNT="${db}-cross-account-$(date +%Y%m%d%H%M)"
    
    echo -e "\n\033[1;34m===== Processing database: $db =====\033[0m"

    EXISTING_CLUSTER=$(aws rds --no-cli-pager describe-db-clusters \
        --profile "$TO_ACCOUNT_PROFILE" \
        --region "$TO_REGION" \
        --query "DBClusters[?starts_with(DBClusterIdentifier, \`${db}-sandbox\`)].DBClusterIdentifier" \
        --output text \
        --no-cli-pager 2>/dev/null || echo "")
    
    if [[ -n "$EXISTING_CLUSTER" && "$EXISTING_CLUSTER" != "None" ]]; then
        echo "✅ Cluster already exists in destination account: $EXISTING_CLUSTER"
        echo "⏭️  Skipping database $db - already migrated previously"
        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo -e "\n✅ \033[1;32mDatabase $db already processed! ($SUCCESS_COUNT/${#RDS[@]})\033[0m"
        continue
    fi

    echo "🔐 Discovering specific KMS key for: $db"
    CURRENT_KMS_KEY=$(aws rds --no-cli-pager describe-db-clusters \
        --db-cluster-identifier "$db" \
        --profile "$FROM_ACCOUNT_PROFILE" \
        --region "$FROM_REGION" \
        --query 'DBClusters[0].KmsKeyId' \
        --output text \
        --no-cli-pager)
    
    if [ -z "$CURRENT_KMS_KEY" ] || [ "$CURRENT_KMS_KEY" = "None" ]; then
        echo "❌ Could not discover KMS key for $db. Skipping..."
        FAILED_DATABASES+=("$db: KMS key not found")
        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
        continue
    fi
    
    echo "KMS key for $db: $CURRENT_KMS_KEY"
    
    if [ "$CURRENT_KMS_KEY" != "$KMS_KEY_ID" ]; then
        echo "🔐 Configuring specific KMS permissions for this database..."
        if ! configure_kms_permissions "$CURRENT_KMS_KEY"; then
            echo "❌ Failed to configure KMS permissions for $db. Skipping..."
            FAILED_DATABASES+=("$db: Error configuring KMS")
            PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
            continue
        fi
    fi

    echo -e "\n\033[1;33m[SOURCE ACCOUNT] Using profile $FROM_ACCOUNT_PROFILE ($FROM_REGION)\033[0m"

    echo -e "\nGetting latest snapshot for: $db"
    LATEST_SNAPSHOT=$(aws rds --no-cli-pager describe-db-cluster-snapshots \
        --profile "$FROM_ACCOUNT_PROFILE" \
        --region "$FROM_REGION" \
        --snapshot-type automated \
        --db-cluster-identifier "$db" \
        --query "reverse(sort_by(DBClusterSnapshots, &SnapshotCreateTime))[0].DBClusterSnapshotIdentifier" \
        --output text)
    
    if [ "$LATEST_SNAPSHOT" = "None" ] || [ -z "$LATEST_SNAPSHOT" ]; then
        echo "❌ No snapshot found for $db. Skipping..."
        FAILED_DATABASES+=("$db: No snapshot found")
        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
        continue
    fi
    
    echo "Snapshot found: $LATEST_SNAPSHOT"

    CLUSTER_INFO=$(aws rds --no-cli-pager describe-db-clusters \
        --profile "$FROM_ACCOUNT_PROFILE" \
        --db-cluster-identifier "$db" \
        --region "$FROM_REGION" \
        --query 'DBClusters[0].[AllocatedStorage,DatabaseName]' \
        --output text)
    
    ALLOCATED_STORAGE=$(echo "$CLUSTER_INFO" | cut -f1)
    if [ "$ALLOCATED_STORAGE" != "None" ] && [ -n "$ALLOCATED_STORAGE" ]; then
        echo "💾 Estimated cluster size: ${ALLOCATED_STORAGE}GB"
        if [ "$ALLOCATED_STORAGE" -gt 100 ]; then
            echo "⚠️  Large cluster detected - process may take 2+ hours"
        fi
    fi

    echo -e "\nCreating manual snapshot: $MANUAL_SNAPSHOT"
    if ! aws rds --no-cli-pager create-db-cluster-snapshot \
        --profile "$FROM_ACCOUNT_PROFILE" \
        --db-cluster-identifier "$db" \
        --db-cluster-snapshot-identifier "$MANUAL_SNAPSHOT" \
        --region "$FROM_REGION"; then
        echo "❌ Error creating manual snapshot for $db. Skipping..."
        FAILED_DATABASES+=("$db: Error creating manual snapshot")
        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
        continue
    fi

    echo -e "\nWaiting for manual snapshot to become available..."
    if ! aws rds --no-cli-pager wait db-cluster-snapshot-available \
        --profile "$FROM_ACCOUNT_PROFILE" \
        --db-cluster-snapshot-identifier "$MANUAL_SNAPSHOT" \
        --region "$FROM_REGION"; then
        echo "❌ Timeout waiting for manual snapshot for $db. Skipping..."
        continue
    fi
    echo "Manual snapshot created: $MANUAL_SNAPSHOT"

    echo -e "\nSharing manual snapshot with destination account"
    if ! aws rds --no-cli-pager modify-db-cluster-snapshot-attribute \
        --profile "$FROM_ACCOUNT_PROFILE" \
        --db-cluster-snapshot-identifier "$MANUAL_SNAPSHOT" \
        --attribute-name restore \
        --values-to-add "$TO_ACCOUNT_ID" \
        --region "$FROM_REGION"; then
        echo "❌ Error sharing snapshot for $db. Skipping..."
        continue
    fi

    echo -e "\n\033[1;32m[DESTINATION ACCOUNT] Using profile $TO_ACCOUNT_PROFILE ($FROM_REGION)\033[0m"

    echo -e "\nCopying snapshot between accounts (same region): $FROM_REGION"
    echo "Using KMS key: $CURRENT_KMS_KEY"
    if ! aws rds --no-cli-pager copy-db-cluster-snapshot \
        --profile "$TO_ACCOUNT_PROFILE" \
        --source-db-cluster-snapshot-identifier "arn:aws:rds:$FROM_REGION:$FROM_ACCOUNT_ID:cluster-snapshot:$MANUAL_SNAPSHOT" \
        --target-db-cluster-snapshot-identifier "$SNAPSHOT_CROSS_ACCOUNT" \
        --kms-key-id "$CURRENT_KMS_KEY" \
        --region "$FROM_REGION" \
        --no-cli-pager; then
        echo "❌ Error copying snapshot between accounts for $db. Skipping..."
        if [ "$CURRENT_KMS_KEY" != "$KMS_KEY_ID" ]; then
            restore_kms_permissions "$CURRENT_KMS_KEY"
        fi
        FAILED_DATABASES+=("$db: Error in cross-account copy")
        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
        continue
    fi

    echo -e "\nWaiting for cross-account copy to complete..."
    echo "⏳ Cross-account copy usually takes 5-15 minutes..."
    
    WAIT_COUNT=0
    MAX_WAIT=60
    
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        COPY_STATUS=$(aws rds --no-cli-pager describe-db-cluster-snapshots \
            --profile "$TO_ACCOUNT_PROFILE" \
            --db-cluster-snapshot-identifier "$SNAPSHOT_CROSS_ACCOUNT" \
            --region "$FROM_REGION" \
            --query 'DBClusterSnapshots[0].Status' \
            --output text 2>/dev/null || echo "creating")
        
        if [ "$COPY_STATUS" = "available" ]; then
            echo "✅ Cross-account copy completed!"
            break
        elif [ "$COPY_STATUS" = "failed" ]; then
            echo "❌ Cross-account copy failed!"
            continue 2
        fi
        
        if [ $((WAIT_COUNT % 4)) -eq 0 ]; then
            ELAPSED=$((WAIT_COUNT * 30 / 60))
            echo "⏳ Waiting... ${ELAPSED} minutes (Status: $COPY_STATUS)"
        fi
        
        sleep 30
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done
    
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "❌ 30-minute timeout reached for cross-account copy"
        continue
    fi

    if [ "$FROM_REGION" != "$TO_REGION" ]; then
        echo -e "\nCopying snapshot between regions ($FROM_REGION → $TO_REGION)"
        if ! aws rds --no-cli-pager copy-db-cluster-snapshot \
            --profile "$TO_ACCOUNT_PROFILE" \
            --source-db-cluster-snapshot-identifier "arn:aws:rds:$FROM_REGION:$TO_ACCOUNT_ID:cluster-snapshot:$SNAPSHOT_CROSS_ACCOUNT" \
            --target-db-cluster-snapshot-identifier "$SNAPSHOT_COPY" \
            --kms-key-id "alias/aws/rds" \
            --source-region "$FROM_REGION" \
            --region "$TO_REGION"; then
            echo "❌ Error copying snapshot between regions for $db. Skipping..."
            continue
        fi

        echo -e "\nWaiting for cross-region copy to complete..."
        echo "⏳ Cross-region copy may take 30-60 minutes for large snapshots..."
        echo "💡 You can monitor progress in AWS Console: RDS > Snapshots"
        
        # Use SNAPSHOT_COPY for cross-region scenario
        FINAL_SNAPSHOT="$SNAPSHOT_COPY"
    else
        echo -e "\nSame region detected ($FROM_REGION) - using cross-account snapshot directly"
        # Use SNAPSHOT_CROSS_ACCOUNT for same-region scenario
        FINAL_SNAPSHOT="$SNAPSHOT_CROSS_ACCOUNT"
    fi

    echo "Checking initial copy status..."
    
    # Determine which region to check based on scenario
    if [ "$FROM_REGION" != "$TO_REGION" ]; then
        CHECK_REGION="$TO_REGION"
    else
        CHECK_REGION="$FROM_REGION"
    fi
    
    COPY_STATUS=$(aws rds --no-cli-pager describe-db-cluster-snapshots \
        --profile "$TO_ACCOUNT_PROFILE" \
        --db-cluster-snapshot-identifier "$FINAL_SNAPSHOT" \
        --region "$CHECK_REGION" \
        --query 'DBClusterSnapshots[0].Status' \
        --output text 2>/dev/null || echo "creating")
    
    echo "Initial status: $COPY_STATUS"
    
    if [ "$COPY_STATUS" = "available" ]; then
        echo "✅ Snapshot already available!"
    else
        echo "Waiting for completion (timeout: 90 minutes)..."
        WAIT_COUNT=0
        MAX_WAIT=180
        
        while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
            COPY_STATUS=$(aws rds --no-cli-pager describe-db-cluster-snapshots \
                --profile "$TO_ACCOUNT_PROFILE" \
                --db-cluster-snapshot-identifier "$FINAL_SNAPSHOT" \
                --region "$CHECK_REGION" \
                --query 'DBClusterSnapshots[0].Status' \
                --output text 2>/dev/null || echo "creating")
            
            if [ "$COPY_STATUS" = "available" ]; then
                echo "✅ Copy completed successfully!"
                break
            elif [ "$COPY_STATUS" = "failed" ]; then
                echo "❌ Copy failed!"
                continue 2
            fi
            
            if [ $((WAIT_COUNT % 10)) -eq 0 ]; then
                ELAPSED=$((WAIT_COUNT * 30 / 60))
                echo "⏳ Waiting... ${ELAPSED} minutes elapsed (Status: $COPY_STATUS)"
            fi
            
            sleep 30
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done
        
        if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
            echo "⚠️  90-minute timeout reached"
            echo "💡 Copy may continue in background. Check AWS Console."
            echo "❌ Skipping to next database..."
            continue
        fi
    fi
    
    if [ "$FROM_REGION" != "$TO_REGION" ]; then
        echo "Cross-region copy completed: $FINAL_SNAPSHOT"
    else
        echo "Cross-account copy ready for use: $FINAL_SNAPSHOT"
    fi

    echo -e "\n\033[1;32m[DESTINATION ACCOUNT] Using profile $TO_ACCOUNT_PROFILE ($TO_REGION)\033[0m"

    # Share snapshot in destination region (only needed for cross-region)
    if [ "$FROM_REGION" != "$TO_REGION" ]; then
        echo -e "\nSharing copied snapshot in destination region"
        aws rds --no-cli-pager modify-db-cluster-snapshot-attribute \
            --profile "$TO_ACCOUNT_PROFILE" \
            --db-cluster-snapshot-identifier "$FINAL_SNAPSHOT" \
            --attribute-name restore \
            --values-to-add "$TO_ACCOUNT_ID" \
            --region "$TO_REGION"
    fi

    echo -e "\nRestoring cluster: $CLUSTER_ID"
    aws rds --no-cli-pager restore-db-cluster-from-snapshot \
        --profile "$TO_ACCOUNT_PROFILE" \
        --db-cluster-identifier "$CLUSTER_ID" \
        --snapshot-identifier "$FINAL_SNAPSHOT" \
        --engine aurora-postgresql \
        --engine-version "13.18" \
        --db-subnet-group-name "$DB_SUBNET_GROUP" \
        --vpc-security-group-ids "$TO_SG_ID" \
        --region "$TO_REGION"

    echo -e "\nWaiting for cluster to become available..."
    aws rds --no-cli-pager wait db-cluster-available \
        --profile "$TO_ACCOUNT_PROFILE" \
        --db-cluster-identifier "$CLUSTER_ID" \
        --region "$TO_REGION"
    echo "Cluster available: $CLUSTER_ID"

    echo -e "\nCreating Serverless V2 instance: $INSTANCE_ID"
    if ! aws rds --no-cli-pager create-db-instance \
        --profile "$TO_ACCOUNT_PROFILE" \
        --db-instance-identifier "$INSTANCE_ID" \
        --db-cluster-identifier "$CLUSTER_ID" \
        --engine aurora-postgresql \
        --db-instance-class db.serverless \
        --region "$TO_REGION"; then
        echo "⚠️  Error creating instance, but cluster was created successfully"
        echo "💡 You can create the instance manually in AWS Console"
    else
        echo -e "\nWaiting for instance to become available..."
        if ! aws rds --no-cli-pager wait db-instance-available \
            --profile "$TO_ACCOUNT_PROFILE" \
            --db-instance-identifier "$INSTANCE_ID" \
            --region "$TO_REGION"; then
            echo "⚠️  Timeout waiting for instance, but continuing..."
        else
            echo "Instance available: $INSTANCE_ID"
        fi
    fi

    echo -e "\nConfiguring auto-scaling"
    aws rds --no-cli-pager modify-db-cluster \
        --profile "$TO_ACCOUNT_PROFILE" \
        --db-cluster-identifier "$CLUSTER_ID" \
        --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=1 \
        --apply-immediately \
        --region "$TO_REGION"

    echo -e "\nResetting master password"
    aws rds --no-cli-pager modify-db-cluster \
        --profile "$TO_ACCOUNT_PROFILE" \
        --db-cluster-identifier "$CLUSTER_ID" \
        --master-user-password "$MASTER_PASSWORD" \
        --apply-immediately \
        --region "$TO_REGION"

    ENDPOINT=$(aws rds --no-cli-pager describe-db-clusters \
        --profile "$TO_ACCOUNT_PROFILE" \
        --db-cluster-identifier "$CLUSTER_ID" \
        --query 'DBClusters[0].Endpoint' \
        --output text \
        --region "$TO_REGION")

    echo -e "\n\033[1;32m===== RESTORATION COMPLETED =====\033[0m"
    echo "Cluster: $CLUSTER_ID"
    echo "Instance: $INSTANCE_ID"
    echo "Endpoint: $ENDPOINT"
    echo "Port: 5432"
    echo "Master user: admin_user"
    echo "Password: $MASTER_PASSWORD"
    echo "Region: $TO_REGION"
    
    # Clean up snapshots based on scenario
    if [ "$FROM_REGION" != "$TO_REGION" ]; then
        # Cross-region: delete the copied snapshot and intermediate snapshot
        echo -e "\nDeleting copied snapshot: $FINAL_SNAPSHOT"
        aws rds --no-cli-pager delete-db-cluster-snapshot \
            --profile "$TO_ACCOUNT_PROFILE" \
            --db-cluster-snapshot-identifier "$FINAL_SNAPSHOT" \
            --region "$TO_REGION"

        echo -e "\nDeleting intermediate snapshot: $SNAPSHOT_CROSS_ACCOUNT"
        aws rds --no-cli-pager delete-db-cluster-snapshot \
            --profile "$TO_ACCOUNT_PROFILE" \
            --db-cluster-snapshot-identifier "$SNAPSHOT_CROSS_ACCOUNT" \
            --region "$FROM_REGION"
    else
        # Same region: only delete the cross-account snapshot
        echo -e "\nDeleting cross-account snapshot: $FINAL_SNAPSHOT"
        aws rds --no-cli-pager delete-db-cluster-snapshot \
            --profile "$TO_ACCOUNT_PROFILE" \
            --db-cluster-snapshot-identifier "$FINAL_SNAPSHOT" \
            --region "$FROM_REGION"
    fi

    echo -e "\nDeleting manual snapshot from source account: $MANUAL_SNAPSHOT"
    aws rds --no-cli-pager delete-db-cluster-snapshot \
        --profile "$FROM_ACCOUNT_PROFILE" \
        --db-cluster-snapshot-identifier "$MANUAL_SNAPSHOT" \
        --region "$FROM_REGION"

    if [ "$CURRENT_KMS_KEY" != "$KMS_KEY_ID" ]; then
        echo "🔐 Restoring specific KMS permissions for $db..."
        restore_kms_permissions "$CURRENT_KMS_KEY"
    fi

    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    echo -e "\n✅ \033[1;32mDatabase $db processed successfully! ($SUCCESS_COUNT/${#RDS[@]})\033[0m"

done

restore_kms_permissions "$KMS_KEY_ID"

echo -e "\n🎉 \033[1;32mProcess completed!\033[0m"
echo ""
echo "📊 Summary of operations performed:"
echo "   • Total databases: ${#RDS[@]}"
echo "   • Processed: $PROCESSED_COUNT"
echo "   • Successes: $SUCCESS_COUNT"
echo "   • Failures: $((PROCESSED_COUNT - SUCCESS_COUNT))"
echo "   • Clusters restored in region $TO_REGION"
echo "   • KMS permissions restored to original state"

if [ ${#FAILED_DATABASES[@]} -gt 0 ]; then
    echo ""
    echo "⚠️  Databases that failed:"
    for failed_db in "${FAILED_DATABASES[@]}"; do
        echo "   • $failed_db"
    done
fi

echo ""
echo "🔍 Next steps:"
echo "   • Check the created clusters in AWS Console ($TO_REGION)"
echo "   • Test connectivity with the new clusters"
echo "   • Configure automatic backups if necessary"
echo ""
echo "💡 Remember to update your applications with the new endpoints!"
