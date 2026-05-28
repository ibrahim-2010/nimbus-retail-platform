#!/usr/bin/env python3
"""
NimbusRetail Bootstrap — Python equivalent of bootstrap.sh.

Creates all prerequisite AWS resources before any Terraform run.
Fully idempotent — safe to re-run on an existing account.

Resources created:
  1. S3 bucket  — versioned, AES256-encrypted, public-access-blocked (Terraform state)
  2. DynamoDB table — Terraform state locking
  3. EC2 key pair — Jenkins SSH access (saved to ./<KEY_NAME>.pem)
  4. Cleans orphan Jenkins IAM role and security group from prior deployments

Usage:
    python scripts/bootstrap.py

Requirements:
    pip install boto3
    AWS credentials must be configured (env vars, ~/.aws/credentials, or instance role)
"""

import json
import logging
import sys
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

# ── Structured JSON logging ──────────────────────────────────────────────────

class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "level": record.levelname,
            "step": getattr(record, "step", None),
            "msg": record.getMessage(),
        }
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload)

_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(_JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[_handler])
log = logging.getLogger("bootstrap")

# ── Config ───────────────────────────────────────────────────────────────────

REGION = "us-east-1"
S3_BUCKET = "ibrahim-cloud-native-tf-state"
DYNAMO_TABLE = "ibrahim-cloud-native-tf-lock"
KEY_NAME = "test"

JENKINS_ROLE_NAME = "jenkins-nimbus-role"
JENKINS_PROFILE_NAME = "jenkins-nimbus-profile"
JENKINS_SG_NAME = "jenkins-nimbus-sg"


def _step(n: int, total: int, label: str) -> logging.LoggerAdapter:
    return logging.LoggerAdapter(log, {"step": f"{n}/{total} {label}"})


# ── Step implementations ─────────────────────────────────────────────────────

def create_s3_bucket(s3) -> None:
    lg = _step(1, 6, "S3 bucket")
    try:
        s3.head_bucket(Bucket=S3_BUCKET)
        lg.info("already exists — skipping creation", extra={"step": "1/6 S3 bucket"})
    except ClientError as e:
        if e.response["Error"]["Code"] != "404":
            raise
        kwargs: dict = {"Bucket": S3_BUCKET}
        if REGION != "us-east-1":
            # us-east-1 is the S3 default — passing LocationConstraint for it is an API error
            kwargs["CreateBucketConfiguration"] = {"LocationConstraint": REGION}
        s3.create_bucket(**kwargs)
        lg.info("created", extra={"step": "1/6 S3 bucket"})

    s3.put_bucket_versioning(
        Bucket=S3_BUCKET,
        VersioningConfiguration={"Status": "Enabled"},
    )
    s3.put_bucket_encryption(
        Bucket=S3_BUCKET,
        ServerSideEncryptionConfiguration={
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
                "BucketKeyEnabled": True,
            }]
        },
    )
    s3.put_public_access_block(
        Bucket=S3_BUCKET,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )
    log.info("versioning=enabled encryption=AES256 public_access=blocked",
             extra={"step": "1/6 S3 bucket"})


def create_dynamodb_table(dynamodb) -> None:
    lg = _step(2, 6, "DynamoDB table")
    try:
        table = dynamodb.Table(DYNAMO_TABLE)
        table.load()
        lg.info("already exists — skipping")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceNotFoundException":
            raise
        dynamodb.create_table(
            TableName=DYNAMO_TABLE,
            AttributeDefinitions=[{"AttributeName": "LockID", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "LockID", "KeyType": "HASH"}],
            BillingMode="PAY_PER_REQUEST",
        )
        dynamodb.Table(DYNAMO_TABLE).wait_until_exists()
        lg.info("created and ACTIVE")


def create_key_pair(ec2_client) -> None:
    lg = _step(4, 6, "EC2 key pair")
    pem_path = Path(f"{KEY_NAME}.pem")
    try:
        ec2_client.describe_key_pairs(KeyNames=[KEY_NAME])
        lg.info("already exists — skipping")
        return
    except ClientError as e:
        if e.response["Error"]["Code"] != "InvalidKeyPair.NotFound":
            raise
    resp = ec2_client.create_key_pair(KeyName=KEY_NAME)
    pem_path.write_text(resp["KeyMaterial"])
    pem_path.chmod(0o400)
    lg.info("created", extra={"step": "4/6 EC2 key pair"})
    log.warning(
        f"Key material written to {pem_path} — save this file securely, it cannot be re-downloaded",
        extra={"step": "4/6 EC2 key pair"},
    )


def verify_identity(sts) -> str:
    lg = _step(5, 6, "AWS identity")
    identity = sts.get_caller_identity()
    account_id = identity["Account"]
    lg.info(f"account={account_id} region={REGION}")
    return account_id


def cleanup_orphan_jenkins(iam_client, ec2_client) -> None:
    lg = _step(6, 6, "orphan Jenkins cleanup")

    # Remove role from instance profile
    try:
        iam_client.remove_role_from_instance_profile(
            InstanceProfileName=JENKINS_PROFILE_NAME,
            RoleName=JENKINS_ROLE_NAME,
        )
        lg.info("removed role from instance profile")
    except ClientError:
        pass

    # Delete instance profile
    try:
        iam_client.delete_instance_profile(InstanceProfileName=JENKINS_PROFILE_NAME)
        lg.info("deleted instance profile")
    except ClientError:
        pass

    # Detach managed policies from role
    try:
        paginator = iam_client.get_paginator("list_attached_role_policies")
        for page in paginator.paginate(RoleName=JENKINS_ROLE_NAME):
            for policy in page["AttachedPolicies"]:
                iam_client.detach_role_policy(
                    RoleName=JENKINS_ROLE_NAME,
                    PolicyArn=policy["PolicyArn"],
                )
    except ClientError:
        pass

    # Delete inline policies from role
    try:
        paginator = iam_client.get_paginator("list_role_policies")
        for page in paginator.paginate(RoleName=JENKINS_ROLE_NAME):
            for name in page["PolicyNames"]:
                iam_client.delete_role_policy(RoleName=JENKINS_ROLE_NAME, PolicyName=name)
    except ClientError:
        pass

    # Delete the role itself
    try:
        iam_client.delete_role(RoleName=JENKINS_ROLE_NAME)
        lg.info("deleted IAM role")
    except ClientError:
        pass

    # Delete security group
    try:
        resp = ec2_client.describe_security_groups(
            Filters=[{"Name": "group-name", "Values": [JENKINS_SG_NAME]}]
        )
        groups = resp.get("SecurityGroups", [])
        if groups:
            ec2_client.delete_security_group(GroupId=groups[0]["GroupId"])
            lg.info(f"deleted security group {groups[0]['GroupId']}")
        else:
            lg.info("no orphan Jenkins resources found")
    except ClientError as e:
        lg.warning(f"could not delete security group: {e}")


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    log.info("NimbusRetail bootstrap starting", extra={"step": "init"})

    session = boto3.Session(region_name=REGION)
    s3 = session.client("s3")
    dynamodb = session.resource("dynamodb")
    ec2_client = session.client("ec2")
    iam_client = session.client("iam")
    sts = session.client("sts")

    try:
        create_s3_bucket(s3)
        create_dynamodb_table(dynamodb)
        log.info("ECR repos created by EKS-Terraform/ecr.tf — skipping", extra={"step": "3/6 ECR"})
        create_key_pair(ec2_client)
        account_id = verify_identity(sts)
        cleanup_orphan_jenkins(iam_client, ec2_client)
    except ClientError as e:
        log.error(f"AWS API error: {e}", extra={"step": "fatal"})
        sys.exit(1)

    log.info(
        "bootstrap complete",
        extra={"step": "summary"},
    )
    print(json.dumps({
        "status": "complete",
        "s3_bucket": S3_BUCKET,
        "dynamodb_table": DYNAMO_TABLE,
        "key_pair": KEY_NAME,
        "account_id": account_id,
        "region": REGION,
    }, indent=2))


if __name__ == "__main__":
    main()
