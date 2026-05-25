#!/usr/bin/env python3
"""
FSAMP End-to-End Test Runner

Enterprise-grade E2E tests with full authentication flow:
- Cognito JWT authentication (no security bypass)
- Full stack validation: Gateway -> S3 -> SNS -> SQS -> Processor -> DynamoDB
- LocalStack Pro integration

Usage:
    python run-e2e-tests.py
    python run-e2e-tests.py --verbose
    python run-e2e-tests.py --test file_upload
"""

import argparse
import hashlib
import os
import sys
import time
import uuid
from datetime import datetime
from typing import Any

import boto3
import requests
from botocore.config import Config
from tenacity import retry, stop_after_attempt, wait_exponential
def _discover_cognito_ids() -> tuple[str, str]:
    """Discover Cognito User Pool and Client IDs from LocalStack."""
    endpoint = os.getenv("AWS_ENDPOINT_URL", "http://localhost:4566")
    region = os.getenv("AWS_REGION", "us-west-2")
    
    env_pool_id = os.getenv("COGNITO_USER_POOL_ID", "")
    env_client_id = os.getenv("COGNITO_CLIENT_ID", "")
    
    if env_pool_id and env_client_id and "fsamp-local" not in env_pool_id:
        return env_pool_id, env_client_id
    
    cognito = boto3.client(
        "cognito-idp",
        endpoint_url=endpoint,
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID", "test"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY", "test"),
        region_name=region,
    )
    
    pool_id = None
    pools = cognito.list_user_pools(MaxResults=10)
    for pool in pools.get("UserPools", []):
        if "fsamp" in pool.get("Name", "").lower():
            pool_id = pool["Id"]
            break
    
    if not pool_id:
        raise RuntimeError("Could not find FSAMP Cognito User Pool in LocalStack")
    
    client_id = None
    clients = cognito.list_user_pool_clients(UserPoolId=pool_id, MaxResults=10)
    for client in clients.get("UserPoolClients", []):
        client_id = client["ClientId"]
        break
    
    if not client_id:
        raise RuntimeError("Could not find FSAMP Cognito Client in LocalStack")
    
    return pool_id, client_id


class TestConfig:
    """Test configuration from environment variables."""
    
    GATEWAY_URL = os.getenv("GATEWAY_URL", "http://localhost:8080")
    AWS_ENDPOINT_URL = os.getenv("AWS_ENDPOINT_URL", "http://localhost:4566")
    AWS_REGION = os.getenv("AWS_REGION", "us-west-2")
    AWS_ACCESS_KEY_ID = os.getenv("AWS_ACCESS_KEY_ID", "test")
    AWS_SECRET_ACCESS_KEY = os.getenv("AWS_SECRET_ACCESS_KEY", "test")
    
    S3_BUCKET_NAME = os.getenv("S3_BUCKET_NAME", "fsamp-local-files")
    DYNAMODB_TABLE_NAME = os.getenv("DYNAMODB_TABLE_NAME", "fsamp-local-file-metadata")
    OUTBOX_TABLE_NAME = os.getenv("OUTBOX_TABLE_NAME", "fsamp-local-outbox")
    DYNAMODB_OUTBOX_TABLE_NAME = OUTBOX_TABLE_NAME
    DYNAMODB_IDEMPOTENCY_TABLE_NAME = os.getenv(
        "DYNAMODB_IDEMPOTENCY_TABLE_NAME",
        "fsamp-local-idempotency-keys",
    )
    SQS_QUEUE_NAME = os.getenv("SQS_QUEUE_NAME", "fsamp-local-processing-queue")
    
    COGNITO_USER_POOL_ID: str = ""
    COGNITO_CLIENT_ID: str = ""
    _cognito_discovered: bool = False
    
    TEST_USER = os.getenv("TEST_USER", "e2e-test-user")
    TEST_PASSWORD = os.getenv("TEST_PASSWORD", "E2eTestPass123!")
    ADMIN_USER = os.getenv("ADMIN_USER", "e2e-admin-user")
    ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "E2eAdminPass123!")
    
    UPLOAD_TIMEOUT = 30
    PROCESSING_TIMEOUT = 60
    HEALTH_CHECK_TIMEOUT = 120
    
    @classmethod
    def ensure_cognito_discovered(cls) -> None:
        """Ensure Cognito IDs are discovered."""
        if cls._cognito_discovered:
            return
        cls.COGNITO_USER_POOL_ID, cls.COGNITO_CLIENT_ID = _discover_cognito_ids()
        cls._cognito_discovered = True
def get_boto_config() -> Config:
    """Get boto3 configuration for LocalStack."""
    return Config(
        region_name=TestConfig.AWS_REGION,
        signature_version="v4",
        retries={"max_attempts": 3, "mode": "standard"}
    )


def get_cognito_client():
    """Get Cognito IDP client configured for LocalStack."""
    return boto3.client(
        "cognito-idp",
        endpoint_url=TestConfig.AWS_ENDPOINT_URL,
        aws_access_key_id=TestConfig.AWS_ACCESS_KEY_ID,
        aws_secret_access_key=TestConfig.AWS_SECRET_ACCESS_KEY,
        config=get_boto_config()
    )


def get_s3_client():
    """Get S3 client configured for LocalStack."""
    return boto3.client(
        "s3",
        endpoint_url=TestConfig.AWS_ENDPOINT_URL,
        aws_access_key_id=TestConfig.AWS_ACCESS_KEY_ID,
        aws_secret_access_key=TestConfig.AWS_SECRET_ACCESS_KEY,
        config=get_boto_config()
    )


def get_dynamodb_client():
    """Get DynamoDB client configured for LocalStack."""
    return boto3.client(
        "dynamodb",
        endpoint_url=TestConfig.AWS_ENDPOINT_URL,
        aws_access_key_id=TestConfig.AWS_ACCESS_KEY_ID,
        aws_secret_access_key=TestConfig.AWS_SECRET_ACCESS_KEY,
        config=get_boto_config()
    )


def get_sqs_client():
    """Get SQS client configured for LocalStack."""
    return boto3.client(
        "sqs",
        endpoint_url=TestConfig.AWS_ENDPOINT_URL,
        aws_access_key_id=TestConfig.AWS_ACCESS_KEY_ID,
        aws_secret_access_key=TestConfig.AWS_SECRET_ACCESS_KEY,
        config=get_boto_config()
    )
class CognitoAuth:
    """Handles Cognito authentication for E2E tests."""
    
    def __init__(self):
        TestConfig.ensure_cognito_discovered()
        self.cognito = get_cognito_client()
        self._tokens: dict[str, dict] = {}
    
    def authenticate(self, username: str, password: str) -> str:
        """
        Authenticate user and return access token.
        Uses ADMIN_NO_SRP_AUTH flow for simplicity in E2E tests.
        """
        cache_key = f"{username}:{password}"
        
        if cache_key in self._tokens:
            token_data = self._tokens[cache_key]
            if token_data.get("expires_at", 0) > time.time() + 300:
                return token_data["access_token"]
        
        try:
            response = self.cognito.admin_initiate_auth(
                UserPoolId=TestConfig.COGNITO_USER_POOL_ID,
                ClientId=TestConfig.COGNITO_CLIENT_ID,
                AuthFlow="ADMIN_NO_SRP_AUTH",
                AuthParameters={
                    "USERNAME": username,
                    "PASSWORD": password,
                }
            )
            
            auth_result = response.get("AuthenticationResult", {})
            access_token = auth_result.get("AccessToken")
            expires_in = auth_result.get("ExpiresIn", 3600)
            
            if access_token:
                self._tokens[cache_key] = {
                    "access_token": access_token,
                    "id_token": auth_result.get("IdToken"),
                    "refresh_token": auth_result.get("RefreshToken"),
                    "expires_at": time.time() + expires_in
                }
                return access_token
            
            raise ValueError("No access token in response")
            
        except Exception as e:
            log(f"Authentication failed for {username}: {e}", "ERROR")
            raise
    
    def get_user_token(self) -> str:
        """Get token for standard test user."""
        return self.authenticate(TestConfig.TEST_USER, TestConfig.TEST_PASSWORD)
    
    def get_admin_token(self) -> str:
        """Get token for admin test user."""
        return self.authenticate(TestConfig.ADMIN_USER, TestConfig.ADMIN_PASSWORD)


_auth: CognitoAuth | None = None

def get_auth() -> CognitoAuth:
    """Get or create auth instance."""
    global _auth
    if _auth is None:
        _auth = CognitoAuth()
    return _auth
class TestResult:
    """Represents a test result."""
    
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.error: str | None = None
        self.duration: float = 0.0
        self.details: dict[str, Any] = {}
    
    def __str__(self) -> str:
        status = "PASS" if self.passed else "FAIL"
        result = f"{status} {self.name} ({self.duration:.2f}s)"
        if self.error:
            result += f"\n    Error: {self.error}"
        return result


def log(message: str, level: str = "INFO") -> None:
    """Log a message with timestamp."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level}] {message}")
@retry(stop=stop_after_attempt(12), wait=wait_exponential(multiplier=1, min=2, max=10))
def wait_for_gateway() -> bool:
    """Wait for gateway to be healthy."""
    response = requests.get(
        f"{TestConfig.GATEWAY_URL}/actuator/health",
        timeout=10
    )
    response.raise_for_status()
    data = response.json()
    if data.get("status") != "UP":
        raise Exception(f"Gateway not healthy: {data}")
    return True


@retry(stop=stop_after_attempt(12), wait=wait_exponential(multiplier=1, min=2, max=10))
def wait_for_localstack() -> bool:
    """Wait for LocalStack to be healthy."""
    response = requests.get(
        f"{TestConfig.AWS_ENDPOINT_URL}/_localstack/health",
        timeout=10
    )
    response.raise_for_status()
    return True
def test_gateway_health() -> TestResult:
    """Test that gateway health endpoint is available."""
    result = TestResult("gateway_health")
    start = time.time()
    
    try:
        response = requests.get(
            f"{TestConfig.GATEWAY_URL}/actuator/health",
            timeout=TestConfig.UPLOAD_TIMEOUT
        )
        response.raise_for_status()
        data = response.json()
        
        result.details["status"] = data.get("status")
        result.details["components"] = list(data.get("components", {}).keys())
        
        if data.get("status") == "UP":
            result.passed = True
        else:
            result.error = f"Unexpected status: {data.get('status')}"
            
    except Exception as e:
        result.error = str(e)
    
    result.duration = time.time() - start
    return result


def test_localstack_resources() -> TestResult:
    """Test that LocalStack resources are properly configured."""
    result = TestResult("localstack_resources")
    start = time.time()
    
    try:
        s3 = get_s3_client()
        dynamodb = get_dynamodb_client()
        sqs = get_sqs_client()
        cognito = get_cognito_client()
        
        buckets = s3.list_buckets()
        bucket_names = [b["Name"] for b in buckets.get("Buckets", [])]
        result.details["s3_buckets"] = bucket_names
        
        if TestConfig.S3_BUCKET_NAME not in bucket_names:
            result.error = f"S3 bucket {TestConfig.S3_BUCKET_NAME} not found"
            result.duration = time.time() - start
            return result
        
        tables = dynamodb.list_tables()
        table_names = tables.get("TableNames", [])
        result.details["dynamodb_tables"] = table_names
        
        required_tables = {
            TestConfig.DYNAMODB_TABLE_NAME,
            TestConfig.DYNAMODB_OUTBOX_TABLE_NAME,
            TestConfig.DYNAMODB_IDEMPOTENCY_TABLE_NAME,
        }
        missing_tables = sorted(required_tables - set(table_names))
        if missing_tables:
            result.error = f"DynamoDB tables not found: {missing_tables}"
            result.duration = time.time() - start
            return result
        
        queues = sqs.list_queues()
        queue_urls = queues.get("QueueUrls", [])
        result.details["sqs_queues"] = [q.split("/")[-1] for q in queue_urls]
        
        pools = cognito.list_user_pools(MaxResults=10)
        pool_names = [p["Name"] for p in pools.get("UserPools", [])]
        result.details["cognito_pools"] = pool_names
        
        result.passed = True
        
    except Exception as e:
        result.error = str(e)
    
    result.duration = time.time() - start
    return result


def test_cognito_authentication() -> TestResult:
    """Test Cognito authentication flow."""
    result = TestResult("cognito_authentication")
    start = time.time()
    
    try:
        auth = get_auth()
        
        user_token = auth.get_user_token()
        result.details["user_token_length"] = len(user_token)
        result.details["user_authenticated"] = True
        
        admin_token = auth.get_admin_token()
        result.details["admin_token_length"] = len(admin_token)
        result.details["admin_authenticated"] = True
        
        result.passed = True
        
    except Exception as e:
        result.error = str(e)
    
    result.duration = time.time() - start
    return result


def test_unauthenticated_request_rejected() -> TestResult:
    """Test that unauthenticated requests are properly rejected."""
    result = TestResult("unauthenticated_rejected")
    start = time.time()
    
    try:
        response = requests.post(
            f"{TestConfig.GATEWAY_URL}/api/v1/files/upload",
            files={"file": ("test.txt", b"test content", "text/plain")},
            timeout=TestConfig.UPLOAD_TIMEOUT
        )
        
        result.details["status_code"] = response.status_code
        
        if response.status_code == 401:
            result.passed = True
            result.details["security"] = "Properly enforced"
        else:
            result.error = f"Expected 401, got {response.status_code}"
            
    except Exception as e:
        result.error = str(e)
    
    result.duration = time.time() - start
    return result


def test_authenticated_file_upload() -> TestResult:
    """Test file upload with proper JWT authentication."""
    result = TestResult("authenticated_file_upload")
    start = time.time()
    
    try:
        auth = get_auth()
        token = auth.get_user_token()
        
        file_id = str(uuid.uuid4())
        file_content = f"E2E Test File - {file_id}\nCreated: {datetime.now().isoformat()}"
        filename = f"e2e-test-{file_id}.txt"
        
        checksum = hashlib.sha256(file_content.encode()).hexdigest()
        
        headers = {
            "Authorization": f"Bearer {token}",
            "X-Correlation-ID": str(uuid.uuid4()),
        }
        
        response = requests.post(
            f"{TestConfig.GATEWAY_URL}/api/v1/files/upload",
            files={"file": (filename, file_content.encode(), "text/plain")},
            headers=headers,
            timeout=TestConfig.UPLOAD_TIMEOUT
        )
        
        result.details["status_code"] = response.status_code
        result.details["file_id"] = file_id
        result.details["checksum"] = checksum[:16] + "..."
        
        if response.status_code in (200, 201, 202):
            try:
                result.details["response"] = response.json()
            except Exception:
                result.details["response_text"] = response.text[:200]
            result.passed = True
        else:
            result.error = f"Upload failed: {response.status_code} - {response.text[:200]}"
            
    except Exception as e:
        result.error = str(e)
    
    result.duration = time.time() - start
    return result


def test_full_processing_flow() -> TestResult:
    """
    Test the complete FSAMP file processing flow:
    
    Gateway -> S3 -> SNS -> SQS -> Processor -> DynamoDB
    
    Steps:
    1. Upload file via Gateway (with JWT auth)
    2. Verify file stored in S3
    3. Verify SNS/SQS message (processor consumes)
    4. Wait for Processor to complete (with polling)
    5. Verify metadata in DynamoDB
    """
    result = TestResult("full_processing_flow")
    start = time.time()
    max_wait_time = TestConfig.PROCESSING_TIMEOUT
    poll_interval = 2  # seconds
    
    try:
        auth = get_auth()
        token = auth.get_user_token()
        
        correlation_id = uuid.uuid4().hex
        idempotency_key = str(uuid.uuid4())
        file_content = f"Full Flow Test - {correlation_id}\nTimestamp: {datetime.now().isoformat()}\nCorrelation: {correlation_id}"
        filename = f"flow-test-{correlation_id}.txt"
        
        headers = {
            "Authorization": f"Bearer {token}",
            "X-Correlation-ID": correlation_id,
            "X-Request-ID": str(uuid.uuid4()),
            "X-Idempotency-Key": idempotency_key,
        }
        
        log(f"  -> Uploading file: {filename}")
        response = requests.post(
            f"{TestConfig.GATEWAY_URL}/api/v1/files/upload",
            files={"file": (filename, file_content.encode(), "text/plain")},
            headers=headers,
            timeout=TestConfig.UPLOAD_TIMEOUT
        )
        
        result.details["1_upload_status"] = response.status_code
        
        if response.status_code not in (200, 201, 202):
            result.error = f"Upload failed: {response.status_code} - {response.text[:200]}"
            result.duration = time.time() - start
            return result
        
        try:
            upload_response = response.json()
            result.details["1_upload_response"] = upload_response
            uploaded_file_id = (
                upload_response.get("fileId") or 
                upload_response.get("file_id") or
                upload_response.get("id")
            )
            s3_key = upload_response.get("s3Key") or upload_response.get("key")
        except Exception:
            uploaded_file_id = None
            s3_key = None
            result.details["1_upload_raw"] = response.text[:200]
        
        log(f"  -> Upload successful, fileId: {uploaded_file_id}")
        
        s3 = get_s3_client()
        
        objects = s3.list_objects_v2(
            Bucket=TestConfig.S3_BUCKET_NAME,
            MaxKeys=100
        )
        
        object_keys = [obj["Key"] for obj in objects.get("Contents", [])]
        result.details["2_s3_objects_count"] = len(object_keys)
        
        file_found_in_s3 = False
        for key in object_keys:
            if (uploaded_file_id and uploaded_file_id in key) or (s3_key and s3_key == key):
                file_found_in_s3 = True
                result.details["2_s3_file_key"] = key
                head = s3.head_object(Bucket=TestConfig.S3_BUCKET_NAME, Key=key)
                result.details["2_s3_sse"] = head.get("ServerSideEncryption", "unknown")
                result.details["2_s3_kms_key"] = head.get("SSEKMSKeyId", "unknown")
                break
        
        if file_found_in_s3:
            log(f"  -> File found in S3: {result.details.get('2_s3_file_key')}")
        else:
            result.details["2_s3_sample_keys"] = object_keys[:5]
        
        dynamodb = get_dynamodb_client()
        outbox_found = False
        if uploaded_file_id:
            try:
                outbox_response = dynamodb.query(
                    TableName=TestConfig.OUTBOX_TABLE_NAME,
                    KeyConditionExpression="PK = :pk",
                    ExpressionAttributeValues={
                        ":pk": {"S": "OUTBOX#FileUpload"}
                    },
                    ScanIndexForward=False,
                    Limit=10,
                )
                for item in outbox_response.get("Items", []):
                    aggregate_id = item.get("aggregateId", {}).get("S", "")
                    payload = item.get("payload", {}).get("S", "")
                    if aggregate_id == uploaded_file_id or uploaded_file_id in payload:
                        outbox_found = True
                        result.details["3_outbox_event"] = "found"
                        result.details["3_outbox_status"] = item.get("status", {}).get("S", "unknown")
                        result.details["3_outbox_event_type"] = item.get("eventType", {}).get("S", "unknown")
                        break
                if not outbox_found:
                    result.details["3_outbox_event"] = "not found"
            except Exception as outbox_err:
                result.details["3_outbox_error"] = str(outbox_err)[:100]

        log(f"  -> Waiting for Processor (max {max_wait_time}s)...")
        
        processing_complete = False
        waited = 0
        
        while waited < max_wait_time:
            time.sleep(poll_interval)
            waited += poll_interval
            
            try:
                if uploaded_file_id:
                    item_response = dynamodb.query(
                        TableName=TestConfig.DYNAMODB_TABLE_NAME,
                        KeyConditionExpression="PK = :pk",
                        ExpressionAttributeValues={
                            ":pk": {"S": f"FILE#{uploaded_file_id}"}
                        },
                        ScanIndexForward=False,
                        Limit=1,
                    )
                    
                    if item_response.get("Items"):
                        processing_complete = True
                        result.details["4_dynamodb_record"] = "found"
                        result.details["4_processing_time"] = f"{waited}s"
                        
                        item = item_response["Items"][0]
                        result.details["4_file_status"] = item.get("status", {}).get("S", "unknown")
                        result.details["4_processed_at"] = item.get("processedAt", {}).get("S", "unknown")
                        log(f"  -> DynamoDB record found after {waited}s")
                        break
                
            except Exception as db_err:
                result.details["4_dynamodb_error"] = str(db_err)[:100]
            
            if processing_complete:
                break
            
            if waited % 10 == 0:
                log(f"  -> Still waiting... ({waited}s/{max_wait_time}s)")
        
        sqs = get_sqs_client()
        try:
            queue_url = f"{TestConfig.AWS_ENDPOINT_URL}/000000000000/{TestConfig.SQS_QUEUE_NAME}"
            queue_attrs = sqs.get_queue_attributes(
                QueueUrl=queue_url,
                AttributeNames=["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"]
            )
            
            attrs = queue_attrs.get("Attributes", {})
            messages_available = int(attrs.get("ApproximateNumberOfMessages", "0"))
            messages_in_flight = int(attrs.get("ApproximateNumberOfMessagesNotVisible", "0"))
            
            result.details["5_sqs_messages_available"] = messages_available
            result.details["5_sqs_messages_in_flight"] = messages_in_flight
            
            if messages_available == 0:
                result.details["5_sqs_status"] = "queue drained (processor consuming)"
            else:
                result.details["5_sqs_status"] = f"{messages_available} messages pending"
                
        except Exception as sqs_err:
            result.details["5_sqs_error"] = str(sqs_err)[:100]
        
        if file_found_in_s3 and outbox_found and processing_complete:
            result.passed = True
            result.details["6_flow_complete"] = True
            result.details["6_verdict"] = "Full flow verified: Gateway -> S3 -> Outbox -> SNS/SQS -> Processor -> DynamoDB"
            log("  -> OK Full processing flow verified!")
        else:
            missing = []
            if not file_found_in_s3:
                missing.append("S3 object")
            if not outbox_found:
                missing.append("Gateway outbox event")
            if not processing_complete:
                missing.append("Processor DynamoDB update")
            result.error = "Full flow incomplete: " + ", ".join(missing)
            result.details["6_flow_complete"] = False
            result.details["6_verdict"] = result.error
            log(f"  -> FAIL {result.error}")
        
    except Exception as e:
        result.error = str(e)
        import traceback
        result.details["traceback"] = traceback.format_exc()[:500]
    
    result.duration = time.time() - start
    return result


def test_gateway_api_docs() -> TestResult:
    """Test that API documentation endpoints are available."""
    result = TestResult("api_docs")
    start = time.time()
    
    try:
        endpoints = {
            "/actuator/info": "actuator",
            "/v3/api-docs": "openapi",
            "/swagger-ui.html": "swagger",
        }
        
        available = []
        for endpoint, name in endpoints.items():
            try:
                response = requests.get(
                    f"{TestConfig.GATEWAY_URL}{endpoint}",
                    timeout=10,
                    allow_redirects=True
                )
                if response.status_code == 200:
                    available.append(name)
                    result.details[name] = "available"
                else:
                    result.details[name] = f"status {response.status_code}"
            except Exception as e:
                result.details[name] = f"error: {str(e)[:50]}"
        
        result.passed = len(available) > 0
        result.details["available_endpoints"] = available
        
    except Exception as e:
        result.error = str(e)
    
    result.duration = time.time() - start
    return result


def test_audit_services_active() -> TestResult:
    """
    Test that audit services (CloudTrail, GuardDuty, AWS Config) are active.

    FedRAMP controls: AU-2/AU-3 (CloudTrail), SI-4 (GuardDuty), CM-2/CM-6 (Config).
    Only runs when ENABLE_AUDIT_SERVICES=1 is set.
    """
    result = TestResult("audit_services")
    start = time.time()

    if os.getenv("ENABLE_AUDIT_SERVICES", "0") != "1":
        result.passed = True
        result.details["skipped"] = "ENABLE_AUDIT_SERVICES not set"
        result.duration = time.time() - start
        return result

    try:
        endpoint = TestConfig.AWS_ENDPOINT_URL
        region = TestConfig.AWS_REGION
        creds = {
            "endpoint_url": endpoint,
            "aws_access_key_id": TestConfig.AWS_ACCESS_KEY_ID,
            "aws_secret_access_key": TestConfig.AWS_SECRET_ACCESS_KEY,
            "region_name": region,
        }

        checks_passed = 0
        total_checks = 3

        try:
            ct = boto3.client("cloudtrail", **creds)
            trails = ct.describe_trails()["trailList"]
            fsamp_trail = [t for t in trails if "fsamp" in t.get("Name", "")]
            if fsamp_trail:
                status = ct.get_trail_status(Name=fsamp_trail[0]["Name"])
                is_logging = status.get("IsLogging", False)
                result.details["cloudtrail"] = f"active, logging={is_logging}"
                if is_logging:
                    checks_passed += 1
                else:
                    result.details["cloudtrail_warning"] = "trail exists but not logging"
            else:
                result.details["cloudtrail"] = "no fsamp trail found"
        except Exception as e:
            result.details["cloudtrail"] = f"error: {str(e)[:80]}"

        try:
            gd = boto3.client("guardduty", **creds)
            detectors = gd.list_detectors()["DetectorIds"]
            if detectors:
                detector = gd.get_detector(DetectorId=detectors[0])
                status = detector.get("Status", "UNKNOWN")
                result.details["guardduty"] = f"detector={detectors[0]}, status={status}"
                if status == "ENABLED":
                    checks_passed += 1
            else:
                result.details["guardduty"] = "no detectors found"
        except Exception as e:
            result.details["guardduty"] = f"error: {str(e)[:80]}"

        try:
            cfg = boto3.client("config", **creds)
            recorders = cfg.describe_configuration_recorders()[
                "ConfigurationRecorders"
            ]
            if recorders:
                rec_status = cfg.describe_configuration_recorder_status()[
                    "ConfigurationRecordersStatus"
                ]
                recording = any(s.get("recording", False) for s in rec_status)
                result.details["config"] = (
                    f"recorder={recorders[0]['name']}, recording={recording}"
                )
                if recording:
                    checks_passed += 1
            else:
                result.details["config"] = "no recorders found"
        except Exception as e:
            result.details["config"] = f"error: {str(e)[:80]}"

        result.passed = checks_passed == total_checks
        result.details["checks_passed"] = f"{checks_passed}/{total_checks}"

    except Exception as e:
        result.error = str(e)

    result.duration = time.time() - start
    return result


def test_iam_roles_exist() -> TestResult:
    """
    Test that least-privilege IAM roles are provisioned (FedRAMP AC-6).
    """
    result = TestResult("iam_roles")
    start = time.time()

    try:
        iam = boto3.client(
            "iam",
            endpoint_url=TestConfig.AWS_ENDPOINT_URL,
            aws_access_key_id=TestConfig.AWS_ACCESS_KEY_ID,
            aws_secret_access_key=TestConfig.AWS_SECRET_ACCESS_KEY,
            region_name=TestConfig.AWS_REGION,
        )

        expected_roles = ["fsamp-gateway-role", "fsamp-processor-role"]
        found_roles = []

        for role_name in expected_roles:
            try:
                role = iam.get_role(RoleName=role_name)
                found_roles.append(role_name)

                policies = iam.list_role_policies(RoleName=role_name)
                policy_names = policies.get("PolicyNames", [])
                result.details[role_name] = f"exists, policies={policy_names}"
            except iam.exceptions.NoSuchEntityException:
                result.details[role_name] = "NOT FOUND"
            except Exception as e:
                result.details[role_name] = f"error: {str(e)[:60]}"

        result.passed = len(found_roles) == len(expected_roles)
        result.details["found"] = f"{len(found_roles)}/{len(expected_roles)}"

    except Exception as e:
        result.error = str(e)

    result.duration = time.time() - start
    return result
def run_all_tests(verbose: bool = False) -> list[TestResult]:
    """Run all E2E tests."""
    results = []
    
    log("=" * 70)
    log("FSAMP Enterprise E2E Tests")
    log("=" * 70)
    log(f"Gateway URL:    {TestConfig.GATEWAY_URL}")
    log(f"AWS Endpoint:   {TestConfig.AWS_ENDPOINT_URL}")
    log(f"Region:         {TestConfig.AWS_REGION}")
    
    try:
        TestConfig.ensure_cognito_discovered()
        log(f"User Pool:      {TestConfig.COGNITO_USER_POOL_ID}")
        log(f"Client ID:      {TestConfig.COGNITO_CLIENT_ID}")
    except Exception as e:
        log(f"Cognito discovery: {e}", "WARN")
    
    log("=" * 70)
    
    log("Waiting for services to be ready...")
    try:
        wait_for_localstack()
        log("OK LocalStack is ready")
    except Exception as e:
        log(f"FAIL LocalStack not ready: {e}", "ERROR")
        return results
    
    try:
        wait_for_gateway()
        log("OK Gateway is ready")
    except Exception as e:
        log(f"FAIL Gateway not ready: {e}", "ERROR")
        return results
    
    log("=" * 70)
    log("Running tests...")
    log("=" * 70)
    
    tests = [
        test_gateway_health,
        test_localstack_resources,
        test_gateway_api_docs,
        test_iam_roles_exist,
        
        test_cognito_authentication,
        test_unauthenticated_request_rejected,
        
        test_audit_services_active,
        
        test_authenticated_file_upload,
        test_full_processing_flow,
    ]
    
    for test_fn in tests:
        log(f"Running: {test_fn.__name__}")
        result = test_fn()
        results.append(result)
        print(f"  {result}")
        
        if verbose and result.details:
            for key, value in result.details.items():
                print(f"    {key}: {value}")
    
    return results


def print_summary(results: list[TestResult]) -> int:
    """Print test summary and return exit code."""
    print("\n" + "=" * 70)
    print("TEST SUMMARY")
    print("=" * 70)
    
    passed = sum(1 for r in results if r.passed)
    failed = sum(1 for r in results if not r.passed)
    total_duration = sum(r.duration for r in results)
    
    print(f"Passed:   {passed}")
    print(f"Failed:   {failed}")
    print(f"Total:    {len(results)}")
    print(f"Duration: {total_duration:.2f}s")
    print("=" * 70)
    
    if failed > 0:
        print("\nFailed tests:")
        for r in results:
            if not r.passed:
                print(f"  {r.name}: {r.error}")
    else:
        print("\nAll tests passed!")
    
    return 0 if failed == 0 else 1


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(description="FSAMP E2E Test Runner")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument("--test", "-t", help="Run specific test")
    args = parser.parse_args()
    
    results = run_all_tests(verbose=args.verbose)
    exit_code = print_summary(results)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
