# -----------------------------------------------------------------------------
# LET OP: dit bestand documenteert de backend-configuratie (REQ-NCA-P1-06).
# De S3-bucket en DynamoDB-tabel voor de remote state moeten ÉÉNMALIG
# bestaan vóórdat je `terraform init` draait, want Terraform kan zijn eigen
# backend niet met zichzelf aanmaken (chicken-and-egg probleem).
#
# Gebruik hiervoor het losse bootstrap-project in environments/bootstrap/,
# of maak ze handmatig aan:
#
#   aws s3api create-bucket --bucket <project>-tfstate --region eu-west-1 \
#     --create-bucket-configuration LocationConstraint=eu-west-1
#   aws s3api put-bucket-versioning --bucket <project>-tfstate \
#     --versioning-configuration Status=Enabled
#   aws s3api put-bucket-encryption --bucket <project>-tfstate \
#     --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
#   aws dynamodb create-table --table-name <project>-tflock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST
#
# Daarna initialiseer je met:
#
#   terraform init \
#     -backend-config="bucket=<project>-tfstate" \
#     -backend-config="key=production/terraform.tfstate" \
#     -backend-config="region=eu-west-1" \
#     -backend-config="dynamodb_table=<project>-tflock" \
#     -backend-config="encrypt=true"
#
# In de GitHub Actions workflow gebeurt dit automatisch via de
# TF_BACKEND_* repository variables/secrets.
# -----------------------------------------------------------------------------
