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
import json
import os
import sys
import time
import traceback
import uuid
import warnings
from datetime import datetime
from typing import Any

import boto3
import requests
from botocore.config import Config
from tenacity import retry, stop_after_attempt, wait_exponential
from urllib3.exceptions import InsecureRequestWarning


def _environment_boolean(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    normalized = value.strip().lower()
    if normalized not in {"true", "false"}:
        raise ValueError(f"{name} must be true or false")
    return normalized == "true"


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
    GATEWAY_HEALTH_PATH = os.getenv("GATEWAY_HEALTH_PATH", "/actuator/health")
    GATEWAY_UPLOAD_PATH = os.getenv(
        "GATEWAY_UPLOAD_PATH", "/api/v1/files/upload"
    )
    GATEWAY_FILES_PATH = os.getenv("GATEWAY_FILES_PATH", "/api/v1/files")
    GATEWAY_MANAGEMENT_URL = os.getenv("GATEWAY_MANAGEMENT_URL", GATEWAY_URL)
    GATEWAY_MANAGEMENT_VERIFY_TLS = _environment_boolean(
        "GATEWAY_MANAGEMENT_VERIFY_TLS", True
    )
    DEMO_RUNTIME = os.getenv("FSAMP_DEMO_RUNTIME", "compose")
    ECS_CLUSTER_NAME = os.getenv("ECS_CLUSTER_NAME", "fsamp-local-cluster")
    GATEWAY_SERVICE_NAME = os.getenv(
        "GATEWAY_SERVICE_NAME", "fsamp-local-gateway"
    )
    GATEWAY_CONTAINER_NAME = os.getenv("GATEWAY_CONTAINER_NAME", "gateway")
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
    FILE_EVENTS_AUDIT_QUEUE_NAME = os.getenv(
        "FILE_EVENTS_AUDIT_QUEUE_NAME", "fsamp-local-file-events-audit"
    )
    PROCESSING_EVENTS_AUDIT_QUEUE_NAME = os.getenv(
        "PROCESSING_EVENTS_AUDIT_QUEUE_NAME",
        "fsamp-local-processing-events-audit",
    )
    GATEWAY_ROLE_NAME = os.getenv("GATEWAY_ROLE_NAME", "fsamp-gateway-role")
    PROCESSOR_ROLE_NAME = os.getenv(
        "PROCESSOR_ROLE_NAME", "fsamp-processor-role"
    )
    EXPECTED_AUDIT_SERVICES = frozenset(
        service.strip().lower()
        for service in os.getenv(
            "EXPECTED_AUDIT_SERVICES",
            "cloudtrail,guardduty,config"
            if _environment_boolean("ENABLE_AUDIT_SERVICES", False)
            else "",
        ).split(",")
        if service.strip()
    )
    EVENT_SCHEMA_VERSION = "1.2.0"

    COGNITO_USER_POOL_ID: str = ""
    COGNITO_CLIENT_ID: str = ""
    _cognito_discovered: bool = False

    TEST_USER = os.getenv("TEST_USER", "e2e-test-user")
    TEST_PASSWORD = os.getenv("TEST_PASSWORD", "E2eTestPass123!")
    ADMIN_USER = os.getenv("ADMIN_USER", "e2e-admin-user")
    ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "E2eAdminPass123!")

    UPLOAD_TIMEOUT = 30
    PROCESSING_TIMEOUT = 120
    HEALTH_CHECK_TIMEOUT = 120

    @classmethod
    def ensure_cognito_discovered(cls) -> None:
        """Ensure Cognito IDs are discovered."""
        if cls._cognito_discovered:
            return
        cls.COGNITO_USER_POOL_ID, cls.COGNITO_CLIENT_ID = _discover_cognito_ids()
        cls._cognito_discovered = True


def _join_url(base_url: str, path: str) -> str:
    return f"{base_url.rstrip('/')}/{path.lstrip('/')}"


def get_boto_config() -> Config:
    """Get boto3 configuration for LocalStack."""
    return Config(
        region_name=TestConfig.AWS_REGION,
        signature_version="v4",
        retries={"max_attempts": 3, "mode": "standard"},
    )


def get_cognito_client():
    """Get Cognito IDP client configured for LocalStack."""
    return boto3.client(
        "cognito-idp",
        endpoint_url=TestConfig.AWS_ENDPOINT_URL,
        aws_access_key_id=TestConfig.AWS_ACCESS_KEY_ID,
        aws_secret_access_key=TestConfig.AWS_SECRET_ACCESS_KEY,
        config=get_boto_config(),
    )


def get_s3_client():
    """Get S3 client configured for LocalStack."""
    return boto3.client(
        "s3",
        endpoint_url=TestConfig.AWS_ENDPOINT_URL,
        aws_access_key_id=TestConfig.AWS_ACCESS_KEY_ID,
        aws_secret_access_key=TestConfig.AWS_SECRET_ACCESS_KEY,
        config=get_boto_config(),
    )


def get_dynamodb_client():
    """Get DynamoDB client configured for LocalStack."""
    return boto3.client(
        "dynamodb",
        endpoint_url=TestConfig.AWS_ENDPOINT_URL,
        aws_access_key_id=TestConfig.AWS_ACCESS_KEY_ID,
        aws_secret_access_key=TestConfig.AWS_SECRET_ACCESS_KEY,
        config=get_boto_config(),
    )


def get_sqs_client():
    """Get SQS client configured for LocalStack."""
    return boto3.client(
        "sqs",
        endpoint_url=TestConfig.AWS_ENDPOINT_URL,
        aws_access_key_id=TestConfig.AWS_ACCESS_KEY_ID,
        aws_secret_access_key=TestConfig.AWS_SECRET_ACCESS_KEY,
        config=get_boto_config(),
    )


def get_ecs_client():
    """Get the ECS client used to locate the LocalStack parity gateway task."""
    return boto3.client(
        "ecs",
        endpoint_url=TestConfig.AWS_ENDPOINT_URL,
        aws_access_key_id=TestConfig.AWS_ACCESS_KEY_ID,
        aws_secret_access_key=TestConfig.AWS_SECRET_ACCESS_KEY,
        config=get_boto_config(),
    )


def _discover_gateway_backend_url() -> str:
    """Resolve the running parity gateway directly on its Docker network."""
    ecs = get_ecs_client()
    task_arns = ecs.list_tasks(
        cluster=TestConfig.ECS_CLUSTER_NAME,
        serviceName=TestConfig.GATEWAY_SERVICE_NAME,
        desiredStatus="RUNNING",
    ).get("taskArns", [])
    if not task_arns:
        raise RuntimeError("no running gateway ECS task found")

    tasks = ecs.describe_tasks(
        cluster=TestConfig.ECS_CLUSTER_NAME,
        tasks=task_arns,
    ).get("tasks", [])
    for task in tasks:
        if task.get("lastStatus") != "RUNNING":
            continue
        for container in task.get("containers", []):
            if (
                container.get("name") != TestConfig.GATEWAY_CONTAINER_NAME
                or container.get("lastStatus") != "RUNNING"
            ):
                continue
            interfaces = container.get("networkInterfaces", [])
            if not interfaces:
                continue
            address = interfaces[0].get("privateIpv4Address")
            bindings = container.get("networkBindings", [])
            port = next(
                (
                    binding.get("containerPort")
                    for binding in bindings
                    if binding.get("containerPort")
                ),
                8080,
            )
            if address:
                return f"http://{address}:{port}"

    raise RuntimeError("running gateway ECS task has no reachable network interface")


def _string(item: dict[str, Any], attribute: str) -> str:
    """Read a DynamoDB string attribute without hiding a missing contract field."""
    return item.get(attribute, {}).get("S", "")


def _canonical_message(body: str) -> dict[str, Any]:
    """Read either an SNS raw-delivery body or a standard SNS envelope."""
    parsed = json.loads(body)
    if isinstance(parsed, dict) and isinstance(parsed.get("Message"), str):
        parsed = json.loads(parsed["Message"])
    if not isinstance(parsed, dict):
        raise ValueError("event body is not a JSON object")
    return parsed


def _queue_url(queue_name: str) -> str:
    return get_sqs_client().get_queue_url(QueueName=queue_name)["QueueUrl"]


def _receive_event(queue_name: str, file_id: str, event_type: str) -> dict[str, Any]:
    """Consume an exact event from an audit subscription, ignoring unrelated traffic."""
    sqs = get_sqs_client()
    queue_url = _queue_url(queue_name)
    deadline = time.time() + TestConfig.PROCESSING_TIMEOUT
    parse_errors: list[str] = []

    while time.time() < deadline:
        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=2,
            VisibilityTimeout=10,
        )
        for message in response.get("Messages", []):
            try:
                event = _canonical_message(message["Body"])
            except (json.JSONDecodeError, ValueError) as exc:
                parse_errors.append(str(exc))
                event = {}

            sqs.delete_message(
                QueueUrl=queue_url,
                ReceiptHandle=message["ReceiptHandle"],
            )
            if event.get("fileId") == file_id and event.get("eventType") == event_type:
                return event

    suffix = f"; parse errors: {parse_errors[-3:]}" if parse_errors else ""
    raise TimeoutError(
        f"{event_type} for {file_id} was not delivered to {queue_name}{suffix}"
    )


def _published_outbox_event(
    dynamodb: Any, file_id: str, event_type: str
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Find an exact published outbox row across the 16 recovery shards."""
    deadline = time.time() + TestConfig.PROCESSING_TIMEOUT
    last_seen: list[str] = []

    while time.time() < deadline:
        for shard in (f"{value:02x}" for value in range(16)):
            response = dynamodb.query(
                TableName=TestConfig.OUTBOX_TABLE_NAME,
                IndexName="GSI1",
                KeyConditionExpression="GSI1PK = :status",
                ExpressionAttributeValues={
                    ":status": {"S": f"STATUS#PUBLISHED#{shard}"}
                },
            )
            for item in response.get("Items", []):
                last_seen.append(
                    f"{_string(item, 'aggregateId')}:{_string(item, 'eventType')}"
                )
                if (
                    _string(item, "aggregateId") == file_id
                    and _string(item, "eventType") == event_type
                ):
                    payload = json.loads(_string(item, "payload"))
                    if not isinstance(payload, dict):
                        raise ValueError("outbox payload is not a JSON object")
                    expected_partition = (
                        f"OUTBOX#{_string(item, 'aggregateType')}#{file_id}"
                    )
                    if _string(item, "PK") != expected_partition:
                        raise AssertionError(
                            "outbox PK does not include aggregate identity"
                        )
                    if _string(item, "outboxPartition") != expected_partition:
                        raise AssertionError("outboxPartition does not match PK")
                    if _string(item, "outboxShard") != shard:
                        raise AssertionError(
                            "outbox shard does not match its published GSI key"
                        )
                    if _string(item, "GSI1PK") != f"STATUS#PUBLISHED#{shard}":
                        raise AssertionError("published outbox GSI key is invalid")
                    if not _string(item, "publishedAt"):
                        raise AssertionError("published outbox row has no publishedAt")
                    if _string(item, "SK") != f"EVENT#{_string(item, 'eventId')}":
                        raise AssertionError("outbox SK does not match eventId")
                    return item, payload
        time.sleep(2)

    raise TimeoutError(
        f"published {event_type} outbox row for {file_id} not found; "
        f"last rows: {last_seen[-10:]}"
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
                },
            )

            auth_result = response.get("AuthenticationResult", {})
            access_token = auth_result.get("AccessToken")
            expires_in = auth_result.get("ExpiresIn", 3600)

            if access_token:
                self._tokens[cache_key] = {
                    "access_token": access_token,
                    "id_token": auth_result.get("IdToken"),
                    "refresh_token": auth_result.get("RefreshToken"),
                    "expires_at": time.time() + expires_in,
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
        _join_url(TestConfig.GATEWAY_URL, TestConfig.GATEWAY_HEALTH_PATH),
        timeout=10,
    )
    response.raise_for_status()
    data = response.json()
    if data.get("status") == "UP":
        return True
    if TestConfig.DEMO_RUNTIME == "terraform-local" and data == {}:
        # LocalStack's emulated API Gateway/ALB currently preserves the status
        # but replaces the upstream response body. The health test below also
        # verifies the real ECS task body directly.
        return True
    raise Exception(f"Gateway not healthy: {data}")


@retry(stop=stop_after_attempt(12), wait=wait_exponential(multiplier=1, min=2, max=10))
def wait_for_localstack() -> bool:
    """Wait for LocalStack to be healthy."""
    response = requests.get(
        f"{TestConfig.AWS_ENDPOINT_URL}/_localstack/health", timeout=10
    )
    response.raise_for_status()
    return True


def test_gateway_health() -> TestResult:
    """Test that gateway health endpoint is available."""
    result = TestResult("gateway_health")
    start = time.time()

    try:
        response = requests.get(
            _join_url(TestConfig.GATEWAY_URL, TestConfig.GATEWAY_HEALTH_PATH),
            timeout=TestConfig.UPLOAD_TIMEOUT,
        )
        response.raise_for_status()
        edge_data = response.json()
        result.details["edge_status_code"] = response.status_code

        if edge_data.get("status") == "UP":
            health_data = edge_data
            result.details["health_source"] = "edge"
        elif TestConfig.DEMO_RUNTIME == "terraform-local" and edge_data == {}:
            backend_url = _discover_gateway_backend_url()
            backend_response = requests.get(
                _join_url(backend_url, "/actuator/health"),
                timeout=TestConfig.UPLOAD_TIMEOUT,
            )
            backend_response.raise_for_status()
            health_data = backend_response.json()
            result.details["health_source"] = "ecs-task"
            result.details["backend_url"] = backend_url
        else:
            health_data = edge_data

        result.details["status"] = health_data.get("status")
        result.details["components"] = list(
            health_data.get("components", {}).keys()
        )

        if health_data.get("status") == "UP":
            result.passed = True
        else:
            result.error = f"Unexpected status: {health_data.get('status')}"

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
        queue_names = {q.rsplit("/", 1)[-1] for q in queue_urls}
        result.details["sqs_queues"] = sorted(queue_names)

        required_queues = {
            TestConfig.SQS_QUEUE_NAME,
            TestConfig.FILE_EVENTS_AUDIT_QUEUE_NAME,
            TestConfig.PROCESSING_EVENTS_AUDIT_QUEUE_NAME,
        }
        missing_queues = sorted(required_queues - queue_names)
        if missing_queues:
            result.error = f"SQS queues not found: {missing_queues}"
            result.duration = time.time() - start
            return result

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
            _join_url(TestConfig.GATEWAY_URL, TestConfig.GATEWAY_UPLOAD_PATH),
            files={"file": ("test.txt", b"test content", "text/plain")},
            timeout=TestConfig.UPLOAD_TIMEOUT,
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

        upload_nonce = str(uuid.uuid4())
        file_content = (
            f"E2E Test File - {upload_nonce}\nCreated: {datetime.now().isoformat()}"
        )
        file_bytes = file_content.encode()
        filename = f"e2e-test-{upload_nonce}.txt"

        checksum = hashlib.sha256(file_bytes).hexdigest()
        correlation_id = str(uuid.uuid4())

        headers = {
            "Authorization": f"Bearer {token}",
            "X-Correlation-ID": correlation_id,
        }

        response = requests.post(
            _join_url(TestConfig.GATEWAY_URL, TestConfig.GATEWAY_UPLOAD_PATH),
            files={"file": (filename, file_bytes, "text/plain")},
            headers=headers,
            timeout=TestConfig.UPLOAD_TIMEOUT,
        )

        result.details["status_code"] = response.status_code
        if response.status_code != 201:
            result.error = (
                f"Expected upload status 201, got {response.status_code}: "
                f"{response.text[:200]}"
            )
            result.duration = time.time() - start
            return result

        upload_response = response.json()
        server_file_id = upload_response.get("fileId")
        if not server_file_id:
            raise AssertionError("upload response has no fileId")
        try:
            uuid.UUID(server_file_id)
        except (TypeError, ValueError) as exc:
            raise AssertionError("upload response fileId is not a UUID") from exc
        if upload_response.get("filename") != filename:
            raise AssertionError("upload response filename does not match request")
        if upload_response.get("checksum") != checksum:
            raise AssertionError("upload response checksum does not match content")
        if upload_response.get("sizeBytes") != len(file_bytes):
            raise AssertionError("upload response size does not match content")
        if upload_response.get("mimeType") != "text/plain":
            raise AssertionError("upload response MIME type does not match request")
        if upload_response.get("correlationId") != correlation_id:
            raise AssertionError("upload response correlation ID does not match request")

        result.details["file_id"] = server_file_id
        result.details["checksum"] = checksum
        result.details["response"] = upload_response
        result.passed = True

    except Exception as e:
        result.error = str(e)

    result.duration = time.time() - start
    return result


def test_full_processing_flow() -> TestResult:
    """Verify the complete authenticated, encrypted, asynchronous file lifecycle."""
    result = TestResult("full_processing_flow")
    start = time.time()

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
            _join_url(TestConfig.GATEWAY_URL, TestConfig.GATEWAY_UPLOAD_PATH),
            files={"file": (filename, file_content.encode(), "text/plain")},
            headers=headers,
            timeout=TestConfig.UPLOAD_TIMEOUT,
        )

        result.details["1_upload_status"] = response.status_code

        if response.status_code != 201:
            raise AssertionError(
                f"expected upload status 201, got {response.status_code}: "
                f"{response.text[:200]}"
            )

        upload_response = response.json()
        result.details["1_upload_response"] = upload_response
        uploaded_file_id = upload_response.get("fileId")
        if not uploaded_file_id:
            raise AssertionError("upload response has no canonical fileId")

        retry_response = requests.post(
            _join_url(TestConfig.GATEWAY_URL, TestConfig.GATEWAY_UPLOAD_PATH),
            files={"file": (filename, file_content.encode(), "text/plain")},
            headers=headers,
            timeout=TestConfig.UPLOAD_TIMEOUT,
        )
        if retry_response.status_code != response.status_code:
            raise AssertionError("idempotent retry changed the HTTP status")
        if retry_response.json().get("fileId") != uploaded_file_id:
            raise AssertionError("idempotent retry created a different fileId")
        result.details["1_idempotent_retry"] = {
            "status": retry_response.status_code,
            "sameFileId": True,
        }
        log(f"  -> Upload successful, fileId: {uploaded_file_id}")

        dynamodb = get_dynamodb_client()
        metadata: dict[str, Any] = {}
        deadline = time.time() + TestConfig.PROCESSING_TIMEOUT
        while time.time() < deadline:
            metadata_response = dynamodb.get_item(
                TableName=TestConfig.DYNAMODB_TABLE_NAME,
                Key={
                    "PK": {"S": f"FILE#{uploaded_file_id}"},
                    "SK": {"S": "METADATA"},
                },
                ConsistentRead=True,
            )
            candidate = metadata_response.get("Item", {})
            if _string(candidate, "status") == "COMPLETED":
                metadata = candidate
                break
            time.sleep(2)

        if not metadata:
            raise TimeoutError(
                f"current metadata for {uploaded_file_id} did not reach COMPLETED"
            )
        if _string(metadata, "entityType") != "FILE_METADATA":
            raise AssertionError("current metadata entityType is not FILE_METADATA")
        if _string(metadata, "fileId") != uploaded_file_id:
            raise AssertionError(
                "current metadata fileId does not match upload response"
            )
        if not _string(metadata, "processedAt"):
            raise AssertionError("COMPLETED metadata has no processedAt")
        result.details["2_metadata"] = {
            "PK": _string(metadata, "PK"),
            "SK": _string(metadata, "SK"),
            "status": _string(metadata, "status"),
            "processedAt": _string(metadata, "processedAt"),
        }

        object_key = _string(metadata, "objectKey")
        bucket_name = _string(metadata, "bucketName")
        if bucket_name != TestConfig.S3_BUCKET_NAME or not object_key:
            raise AssertionError("metadata does not identify the uploaded S3 object")

        s3 = get_s3_client()
        head = s3.head_object(Bucket=bucket_name, Key=object_key)
        encryption = s3.get_bucket_encryption(Bucket=bucket_name)
        configured_kms_key = encryption["ServerSideEncryptionConfiguration"]["Rules"][
            0
        ]["ApplyServerSideEncryptionByDefault"].get("KMSMasterKeyID", "")
        object_kms_key = head.get("SSEKMSKeyId", "")
        if head.get("ServerSideEncryption") != "aws:kms":
            raise AssertionError("uploaded object is not encrypted with SSE-KMS")
        if not configured_kms_key or not object_kms_key:
            raise AssertionError("SSE-KMS key identity is missing")
        if not (
            configured_kms_key == object_kms_key
            or object_kms_key.endswith(f"/{configured_kms_key}")
            or configured_kms_key.endswith(f"/{object_kms_key}")
        ):
            raise AssertionError(
                "object KMS key does not match bucket encryption policy"
            )
        result.details["3_s3"] = {
            "key": object_key,
            "sse": head["ServerSideEncryption"],
            "kmsKeyId": object_kms_key,
        }

        gateway_outbox, uploaded_payload = _published_outbox_event(
            dynamodb, uploaded_file_id, "FILE_UPLOADED"
        )
        result_outbox, result_payload = _published_outbox_event(
            dynamodb, uploaded_file_id, "ANALYSIS_COMPLETED"
        )
        for name, row, payload, event_type in (
            ("gateway", gateway_outbox, uploaded_payload, "FILE_UPLOADED"),
            ("processor", result_outbox, result_payload, "ANALYSIS_COMPLETED"),
        ):
            if payload.get("schemaVersion") != TestConfig.EVENT_SCHEMA_VERSION:
                raise AssertionError(f"{name} outbox payload schema is not 1.2.0")
            if payload.get("eventType") != event_type:
                raise AssertionError(f"{name} outbox payload eventType is invalid")
            if payload.get("fileId") != uploaded_file_id:
                raise AssertionError(f"{name} outbox payload fileId is invalid")
            if payload.get("eventId") != _string(row, "eventId"):
                raise AssertionError(f"{name} outbox eventId does not match payload")
        if not isinstance(result_payload.get("processingResult"), dict):
            raise AssertionError("ANALYSIS_COMPLETED has no processingResult")
        result.details["4_outbox"] = {
            "gateway": _string(gateway_outbox, "PK"),
            "processor": _string(result_outbox, "PK"),
            "schemaVersion": result_payload["schemaVersion"],
            "status": _string(result_outbox, "status"),
        }

        uploaded_message = _receive_event(
            TestConfig.FILE_EVENTS_AUDIT_QUEUE_NAME,
            uploaded_file_id,
            "FILE_UPLOADED",
        )
        result_message = _receive_event(
            TestConfig.PROCESSING_EVENTS_AUDIT_QUEUE_NAME,
            uploaded_file_id,
            "ANALYSIS_COMPLETED",
        )
        for message, expected_event_id in (
            (uploaded_message, _string(gateway_outbox, "eventId")),
            (result_message, _string(result_outbox, "eventId")),
        ):
            if message.get("schemaVersion") != TestConfig.EVENT_SCHEMA_VERSION:
                raise AssertionError("SNS/SQS message schema is not 1.2.0")
            if message.get("eventId") != expected_event_id:
                raise AssertionError("SNS/SQS message does not match its outbox row")
        result.details["5_messaging"] = {
            "fileEventsQueue": TestConfig.FILE_EVENTS_AUDIT_QUEUE_NAME,
            "processingEventsQueue": TestConfig.PROCESSING_EVENTS_AUDIT_QUEUE_NAME,
        }

        get_response = requests.get(
            _join_url(
                TestConfig.GATEWAY_URL,
                f"{TestConfig.GATEWAY_FILES_PATH}/{uploaded_file_id}",
            ),
            headers={"Authorization": f"Bearer {token}"},
            timeout=TestConfig.UPLOAD_TIMEOUT,
        )
        if get_response.status_code != 200:
            raise AssertionError(
                f"authenticated GET failed: {get_response.status_code} "
                f"{get_response.text[:200]}"
            )
        gateway_metadata = get_response.json()
        if gateway_metadata.get("fileId") != uploaded_file_id:
            raise AssertionError("gateway GET returned another file")
        if gateway_metadata.get("status") != "COMPLETED":
            raise AssertionError("gateway GET did not expose COMPLETED state")

        denied_delete_response = requests.delete(
            _join_url(
                TestConfig.GATEWAY_URL,
                f"{TestConfig.GATEWAY_FILES_PATH}/{uploaded_file_id}",
            ),
            headers={"Authorization": f"Bearer {token}"},
            timeout=TestConfig.UPLOAD_TIMEOUT,
        )
        if denied_delete_response.status_code != 403:
            raise AssertionError(
                "non-admin DELETE was not denied: "
                f"{denied_delete_response.status_code} "
                f"{denied_delete_response.text[:200]}"
            )

        admin_token = auth.get_admin_token()
        delete_response = requests.delete(
            _join_url(
                TestConfig.GATEWAY_URL,
                f"{TestConfig.GATEWAY_FILES_PATH}/{uploaded_file_id}",
            ),
            headers={"Authorization": f"Bearer {admin_token}"},
            timeout=TestConfig.UPLOAD_TIMEOUT,
        )
        if delete_response.status_code != 204:
            raise AssertionError(
                f"authenticated DELETE failed: {delete_response.status_code} "
                f"{delete_response.text[:200]}"
            )

        result.details["6_gateway_api"] = {
            "GET": 200,
            "userDelete": 403,
            "adminDelete": 204,
        }
        result.details["7_verdict"] = (
            "Gateway -> SSE-KMS S3 -> published outbox -> SNS/SQS -> processor "
            "-> current metadata -> GET/DELETE verified"
        )
        result.passed = True
        log("  -> OK Full processing flow verified!")

    except Exception as e:
        result.error = str(e)
        result.details["traceback"] = traceback.format_exc()[:500]

    result.duration = time.time() - start
    return result


def test_gateway_api_docs() -> TestResult:
    """Test that API documentation endpoints are available."""
    result = TestResult("api_docs")
    start = time.time()

    try:
        management_url = (
            _discover_gateway_backend_url()
            if TestConfig.DEMO_RUNTIME == "terraform-local"
            else TestConfig.GATEWAY_MANAGEMENT_URL
        )
        endpoints = {
            "/actuator/info": "actuator",
            "/v3/api-docs": "openapi",
            "/swagger-ui/index.html": "swagger",
        }

        unavailable = []
        for endpoint, name in endpoints.items():
            try:
                with warnings.catch_warnings():
                    if not TestConfig.GATEWAY_MANAGEMENT_VERIFY_TLS:
                        warnings.simplefilter("ignore", InsecureRequestWarning)
                    response = requests.get(
                        _join_url(management_url, endpoint),
                        timeout=10,
                        allow_redirects=True,
                        verify=TestConfig.GATEWAY_MANAGEMENT_VERIFY_TLS,
                    )
                if response.status_code == 200:
                    result.details[name] = "available"
                else:
                    result.details[name] = f"status {response.status_code}"
                    unavailable.append(name)
            except Exception as e:
                result.details[name] = f"error: {str(e)[:50]}"
                unavailable.append(name)

        result.passed = not unavailable
        result.details["required_endpoints"] = list(endpoints.values())
        if unavailable:
            result.error = f"Required API endpoints unavailable: {unavailable}"

    except Exception as e:
        result.error = str(e)

    result.duration = time.time() - start
    return result


def test_audit_services_active() -> TestResult:
    """
    Test that audit services (CloudTrail, GuardDuty, AWS Config) are active.

    FedRAMP controls: AU-2/AU-3 (CloudTrail), SI-4 (GuardDuty), CM-2/CM-6 (Config).
    Only checks services explicitly listed in EXPECTED_AUDIT_SERVICES. The
    legacy ENABLE_AUDIT_SERVICES=1 switch still selects all three services.
    """
    result = TestResult("audit_services")
    start = time.time()

    expected_services = TestConfig.EXPECTED_AUDIT_SERVICES
    supported_services = {"cloudtrail", "guardduty", "config"}
    unknown_services = expected_services - supported_services
    if unknown_services:
        result.error = (
            "unsupported EXPECTED_AUDIT_SERVICES values: "
            + ", ".join(sorted(unknown_services))
        )
        result.duration = time.time() - start
        return result

    if not expected_services:
        result.passed = True
        result.details["skipped"] = "EXPECTED_AUDIT_SERVICES is empty"
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
        total_checks = len(expected_services)
        result.details["expected_services"] = sorted(expected_services)

        if "cloudtrail" in expected_services:
            try:
                ct = boto3.client("cloudtrail", **creds)
                trails = ct.describe_trails()["trailList"]
                fsamp_trail = [
                    trail for trail in trails if "fsamp" in trail.get("Name", "")
                ]
                if fsamp_trail:
                    status = ct.get_trail_status(Name=fsamp_trail[0]["Name"])
                    is_logging = status.get("IsLogging", False)
                    result.details["cloudtrail"] = f"active, logging={is_logging}"
                    if is_logging:
                        checks_passed += 1
                    else:
                        result.details["cloudtrail_warning"] = (
                            "trail exists but not logging"
                        )
                else:
                    result.details["cloudtrail"] = "no fsamp trail found"
            except Exception as e:
                result.details["cloudtrail"] = f"error: {str(e)[:80]}"

        if "guardduty" in expected_services:
            try:
                gd = boto3.client("guardduty", **creds)
                detectors = gd.list_detectors()["DetectorIds"]
                if detectors:
                    detector = gd.get_detector(DetectorId=detectors[0])
                    status = detector.get("Status", "UNKNOWN")
                    result.details["guardduty"] = (
                        f"detector={detectors[0]}, status={status}"
                    )
                    if status == "ENABLED":
                        checks_passed += 1
                else:
                    result.details["guardduty"] = "no detectors found"
            except Exception as e:
                result.details["guardduty"] = f"error: {str(e)[:80]}"

        if "config" in expected_services:
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

        expected_roles = [
            TestConfig.GATEWAY_ROLE_NAME,
            TestConfig.PROCESSOR_ROLE_NAME,
        ]
        found_roles = []

        for role_name in expected_roles:
            try:
                iam.get_role(RoleName=role_name)
                found_roles.append(role_name)

                policies = iam.list_role_policies(RoleName=role_name)
                policy_names = policies.get("PolicyNames", [])
                result.details[role_name] = f"exists, policies={policy_names}"
                if not policy_names:
                    found_roles.remove(role_name)
                    result.details[role_name] = "exists, but has no inline policy"
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


def run_all_tests(
    verbose: bool = False, selected_test: str | None = None
) -> list[TestResult]:
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
        failure = TestResult("localstack_readiness")
        failure.error = str(e)
        return [failure]

    try:
        wait_for_gateway()
        log("OK Gateway is ready")
    except Exception as e:
        log(f"FAIL Gateway not ready: {e}", "ERROR")
        failure = TestResult("gateway_readiness")
        failure.error = str(e)
        return [failure]

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

    if selected_test:
        normalized = selected_test.removeprefix("test_")
        tests = [
            test_fn
            for test_fn in tests
            if test_fn.__name__.removeprefix("test_") == normalized
        ]
        if not tests:
            raise ValueError(f"unknown test: {selected_test}")

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

    if not results:
        print("\nNo tests were executed; refusing a false-positive E2E result.")
        return 1

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

    try:
        results = run_all_tests(
            verbose=args.verbose,
            selected_test=args.test,
        )
    except ValueError as exc:
        parser.error(str(exc))
    exit_code = print_summary(results)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
