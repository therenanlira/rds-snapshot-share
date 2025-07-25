# RDS Snapshot Share

This script automates the process of sharing RDS cluster snapshots from a source AWS account to a destination AWS account and restoring them.

## Features

- **Cross-Account Sharing**: Automatically shares snapshots between two AWS accounts.
- **Cross-Region Migration**: Supports migrating snapshots to a different AWS region.
- **Automated Restore**: Restores the snapshot as a new cluster in the destination account.
- **KMS Key Management**: Handles KMS key policy updates for cross-account access.
- **Configuration Validation**: Includes a script to validate your configuration before running the main script.
- **Secure**: Prompts for the master password instead of storing it in a configuration file.

## Prerequisites

- **AWS CLI**: Installed and configured with profiles for both source and destination accounts.
- **jq**: A lightweight and flexible command-line JSON processor.

## Networking

To ensure the script runs successfully, you need to have the following networking resources configured in your destination account:

- **DB Subnet Group**: The DB subnet group specified in the `.env` file must contain the subnets where the new RDS clusters will be launched.
- **Security Group**: The security group specified in the `.env` file must have an inbound rule that allows traffic from the DB subnets on port 5432. This is required for the script to be able to connect to the new RDS clusters and verify that they are running.

## How to Use

### 1. Configuration

Create a `.env` file in the root of the project. This file will store all the necessary configuration variables.

You can create a `.env` file by running the script without any parameters:
```bash
./rds-snapshots-share.sh
```
If the file does not exist, the script will create a new one with default values.

Here is an example of the `.env` file:

```bash
#!/bin/bash

# ==================================================================
# Configuration for rds-snapshots-share.sh
# ==================================================================

# List of clusters to migrate
RDS=("cluster-1" "cluster-2" "cluster-3")

# Configurations for the SOURCE account
FROM_ACCOUNT_PROFILE="source-profile"
FROM_ACCOUNT_ID="111111111111"
FROM_REGION="us-east-1"

# Configurations for the DESTINATION account
TO_ACCOUNT_PROFILE="destination-profile"
TO_ACCOUNT_ID="222222222222"
TO_REGION="us-west-2"
TO_SG_ID="sg-xxxxxxxxx"
DB_SUBNET_GROUP="db-subnet-group"
```

### 2. Validate Configuration

After setting up your `config.sh` file, it is highly recommended to run the validation script to ensure all your configurations are correct.

```bash
./validate.sh
```

This script will check:
- If the AWS profiles are valid and can be accessed.
- If the source RDS clusters exist.
- If the destination security group and DB subnet group exist.
- If the security group and DB subnet group are in the same VPC.
- If the security group has the correct inbound rules for PostgreSQL.

### 3. Run the script

Once the configuration is validated, you can run the main script to start the snapshot sharing and restoring process.

```bash
./rds-snapshots-share.sh
```

The script will prompt you to enter the master password for the new RDS clusters.

## How it Works

1.  **Backup**: For each cluster defined in the `RDS` array, the script creates a new snapshot.
2.  **Share**: The script shares the created snapshot with the destination account.
3.  **Restore**: The script restores the shared snapshot in the destination account as a new cluster.
4.  **Modify**: The script modifies the newly created cluster to use the specified security group.
5.  **Cleanup**: The script deletes the temporary snapshot from the source account.

## Important Notes

- The script has built-in checks to ensure that commands are executed successfully.
- It uses `aws sts get-caller-identity` to verify the configured profiles.
- Make sure the IAM roles and policies are correctly set up to allow snapshot sharing and restoring between the accounts.
- The script will ask for the master password of the database when you run it. It is not stored in any file.
- The script will create a `output.json` file to store the output of the AWS CLI commands. This file is used for debugging purposes.
- The script will create a `rds-snapshots-share.log` file to store the logs of the script. This file is useful for debugging and auditing purposes.