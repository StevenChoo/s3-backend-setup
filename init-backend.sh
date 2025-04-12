#!/bin/bash

# Script to bootstrap a secure OpenTofu backend with S3 bucket and DynamoDB table
# Uses CloudFormation to ensure secure and consistent infrastructure
# Usage: ./init-backend.sh [path/to/opentofu/project]

# Exit immediately if a command exits with a non-zero status
set -e

# Get dir of script so we can call the script from other places and still be able to have the correct references to directories
source=$(readlink -f -- "${BASH_SOURCE[0]}")
source_dir=$(dirname "${source}")

# Check if project path is provided as argument, otherwise use default
if [ $# -eq 1 ]; then
  project_dir=$(readlink -f -- "$1")
  # Validate that the provided path exists and is a directory
  if [ ! -d "$project_dir" ]; then
    echo "Error: The specified project path '$1' does not exist or is not a directory."
    echo "Please provide a valid OpenTofu project directory."
    exit 1
  fi
else
  # Default to parent directory if no argument provided
  project_dir=$(dirname "${source}/..")
  echo "No project directory specified. Using default: $project_dir"
fi

# Default values
DEFAULT_REGION="eu-west-1"

# Ask for project name
read -p "Enter project name (required): " PROJECT_NAME
if [ -z "$PROJECT_NAME" ]; then
  echo "Error: Project name is required"
  exit 1
fi

# Ask for environment name (optional)
read -p "Enter environment name (dev/prod/etc., optional): " ENV_NAME

# Ask for AWS region (optional)
read -p "Enter AWS region (default: $DEFAULT_REGION): " REGION
REGION=${REGION:-$DEFAULT_REGION}

# Set stack name based on project and environment
STACK_NAME="opentofu-backend-${PROJECT_NAME}"
if [ -n "$ENV_NAME" ]; then
  STACK_NAME="${STACK_NAME}-${ENV_NAME}"
fi

# Check if open-tofu (tofu) is installed
if ! command -v tofu &> /dev/null
then
    echo "Error: open-tofu (tofu) is not installed. Please install it and try again."
    exit 1
fi

# Check for valid AWS credentials
if ! aws sts get-caller-identity &> /dev/null
then
    echo "Error: Invalid AWS credentials. Please configure your AWS credentials and try again."
    exit 1
fi

# Parameters for the CloudFormation stack
PARAMETERS="ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}"
if [ -n "$ENV_NAME" ]; then
  PARAMETERS="${PARAMETERS} ParameterKey=EnvironmentName,ParameterValue=${ENV_NAME}"
fi

echo "--- CloudFormation deploy ---"
echo "Creating stack: ${STACK_NAME}"
echo "Project: ${PROJECT_NAME}"
if [ -n "$ENV_NAME" ]; then
  echo "Environment: ${ENV_NAME}"
fi
echo "Region: ${REGION}"

# Deploy the CloudFormation stack with our parameters
aws cloudformation deploy \
  --template-file "${source_dir}/cfn-backend-template.yaml" \
  --stack-name "$STACK_NAME" \
  --region "${REGION}" \
  --parameter-overrides ${PARAMETERS} \
  --capabilities CAPABILITY_IAM

# Get the outputs from CloudFormation to use in our OpenTofu configuration
echo "--- Get S3 bucket & DynamoDB table name for OpenTofu backend ---"
bucket=$(aws cloudformation describe-stacks --region "${REGION}" --query "Stacks[?StackName=='$STACK_NAME'][].Outputs[?OutputKey=='OpenTofuBackendBucketName'].OutputValue" --output text)
dbtable=$(aws cloudformation describe-stacks --region "${REGION}" --query "Stacks[?StackName=='$STACK_NAME'][].Outputs[?OutputKey=='OpenTofuBackendDynamoDBName'].OutputValue" --output text)
kms_key=$(aws cloudformation describe-stacks --region "${REGION}" --query "Stacks[?StackName=='$STACK_NAME'][].Outputs[?OutputKey=='KMSKeyID'].OutputValue" --output text)

echo "S3 Bucket: $bucket"
echo "DynamoDB table: $dbtable"
echo "KMS Key ID: $kms_key"

# Check if the project directory contains a main.tf file (required for OpenTofu)
if [ ! -f "${project_dir}/main.tf" ]; then
  # Save backend configuration to a file in the project directory
  echo "Saving backend configuration to ${project_dir}/backend-info.json..."
  cat > "${project_dir}/backend-info.json" << EOF
{
  "project": "${PROJECT_NAME}",
  "environment": "${ENV_NAME}",
  "region": "${REGION}",
  "backend": {
    "s3_bucket": "${bucket}",
    "dynamodb_table": "${dbtable}",
    "kms_key_id": "${kms_key}"
  }
}
EOF
  echo "Error: The project directory (${project_dir}) does not contain a main.tf file."
  echo "This does not appear to be a valid OpenTofu project."
  echo "Backend infrastructure has been created, but OpenTofu initialization was skipped."
  echo "Configuration saved to: ${project_dir}/backend-info.json"
  echo ""
  echo "To manually setup your OpenTofu project with this backend:"
  echo "1. Create a main.tf file with the required OpenTofu configuration"
  echo "2. Add the S3 backend configuration as shown below"
  echo "3. Run 'tofu init' to initialize the backend"
  echo ""
  echo "See README.md for detailed instructions and examples"
  exit 1
fi

# Initialize OpenTofu with the new backend
echo "--- OpenTofu init ---"
tofu -chdir="$project_dir" init -reconfigure \
  -backend-config="bucket=${bucket}" \
  -backend-config="region=${REGION}" \
  -backend-config="dynamodb_table=${dbtable}" \
  -backend-config="encrypt=true" \
  -upgrade

# Run OpenTofu plan
echo "--- OpenTofu plan ---"
tofu -chdir="$project_dir" plan

# Run OpenTofu apply (commented out by default for safety - uncomment if needed)
echo "--- OpenTofu apply ---"
# Uncomment the line below to automatically apply changes
# tofu -chdir=$openTofuDir apply -auto-approve

# Ask user if they want to apply changes
read -p "Do you want to apply the OpenTofu changes? (yes/no): " APPLY_CHANGES
if [ "$APPLY_CHANGES" == "yes" ]; then
  tofu -chdir="$project_dir" apply
else
  echo "Skipping apply. You can manually run: tofu -chdir=$project_dir apply"
fi

# Print backend configuration for future reference
echo ""
echo "================================================================="
echo "OpenTofu S3 Backend Setup Complete!"
echo "================================================================="
echo ""
echo "To use this backend in your OpenTofu (Terraform) configuration:"
echo ""
echo 'terraform {
  backend "s3" {
    bucket         = "'${bucket}'"
    key            = "path/to/your/state.tfstate"
    region         = "'${REGION}'"
    dynamodb_table = "'${dbtable}'"
    encrypt        = true
  }
}'
echo ""
echo "================================================================="
