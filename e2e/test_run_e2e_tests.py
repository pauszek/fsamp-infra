"""Regression tests for the fail-closed E2E runner contract."""

from __future__ import annotations

from contextlib import redirect_stdout
import importlib.util
from io import StringIO
from pathlib import Path
import unittest
from unittest.mock import Mock, patch


RUNNER_PATH = Path(__file__).with_name("run-e2e-tests.py")
SPEC = importlib.util.spec_from_file_location("fsamp_e2e_runner", RUNNER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Cannot load E2E runner from {RUNNER_PATH}")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class E2ERunnerContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.original_gateway_url = RUNNER.TestConfig.GATEWAY_URL
        self.original_health_path = getattr(
            RUNNER.TestConfig, "GATEWAY_HEALTH_PATH", None
        )
        self.original_upload_path = getattr(
            RUNNER.TestConfig, "GATEWAY_UPLOAD_PATH", None
        )
        self.original_management_url = getattr(
            RUNNER.TestConfig, "GATEWAY_MANAGEMENT_URL", None
        )
        self.original_management_verify_tls = getattr(
            RUNNER.TestConfig, "GATEWAY_MANAGEMENT_VERIFY_TLS", None
        )
        self.original_gateway_role_name = RUNNER.TestConfig.GATEWAY_ROLE_NAME
        self.original_processor_role_name = RUNNER.TestConfig.PROCESSOR_ROLE_NAME
        self.original_demo_runtime = RUNNER.TestConfig.DEMO_RUNTIME

        RUNNER.TestConfig.GATEWAY_URL = "http://api.example.test/local/"
        RUNNER.TestConfig.GATEWAY_HEALTH_PATH = "/health"
        RUNNER.TestConfig.GATEWAY_UPLOAD_PATH = "/files/upload"
        RUNNER.TestConfig.GATEWAY_MANAGEMENT_URL = "https://alb.example.test/"
        RUNNER.TestConfig.GATEWAY_MANAGEMENT_VERIFY_TLS = False
        RUNNER.TestConfig.GATEWAY_ROLE_NAME = "fsamp-test-gateway-task-role"
        RUNNER.TestConfig.PROCESSOR_ROLE_NAME = "fsamp-test-processor-lambda-role"
        RUNNER.TestConfig.DEMO_RUNTIME = "compose"

    def tearDown(self) -> None:
        RUNNER.TestConfig.GATEWAY_URL = self.original_gateway_url
        self._restore("GATEWAY_HEALTH_PATH", self.original_health_path)
        self._restore("GATEWAY_UPLOAD_PATH", self.original_upload_path)
        self._restore("GATEWAY_MANAGEMENT_URL", self.original_management_url)
        self._restore(
            "GATEWAY_MANAGEMENT_VERIFY_TLS",
            self.original_management_verify_tls,
        )
        RUNNER.TestConfig.GATEWAY_ROLE_NAME = self.original_gateway_role_name
        RUNNER.TestConfig.PROCESSOR_ROLE_NAME = self.original_processor_role_name
        RUNNER.TestConfig.DEMO_RUNTIME = self.original_demo_runtime

    def _restore(self, name: str, value: object) -> None:
        if value is None:
            delattr(RUNNER.TestConfig, name)
        else:
            setattr(RUNNER.TestConfig, name, value)

    def test_gateway_readiness_uses_configured_public_health_path(self) -> None:
        response = Mock()
        response.json.return_value = {"status": "UP"}

        with patch.object(RUNNER.requests, "get", return_value=response) as get:
            self.assertTrue(RUNNER.wait_for_gateway())

        get.assert_called_once_with(
            "http://api.example.test/local/health",
            timeout=10,
        )
        response.raise_for_status.assert_called_once_with()

    def test_upload_check_uses_configured_public_upload_path(self) -> None:
        response = Mock(status_code=401)

        with patch.object(RUNNER.requests, "post", return_value=response) as post:
            result = RUNNER.test_unauthenticated_request_rejected()

        self.assertTrue(result.passed)
        self.assertEqual(
            post.call_args.args[0],
            "http://api.example.test/local/files/upload",
        )

    def test_local_parity_readiness_accepts_empty_emulated_edge_body(self) -> None:
        response = Mock()
        response.json.return_value = {}
        RUNNER.TestConfig.DEMO_RUNTIME = "terraform-local"

        with patch.object(RUNNER.requests, "get", return_value=response):
            self.assertTrue(RUNNER.wait_for_gateway.__wrapped__())

    def test_gateway_health_verifies_local_parity_backend(self) -> None:
        edge_response = Mock(status_code=200)
        edge_response.json.return_value = {}
        backend_response = Mock(status_code=200)
        backend_response.json.return_value = {
            "status": "UP",
            "components": {"diskSpace": {"status": "UP"}},
        }
        RUNNER.TestConfig.DEMO_RUNTIME = "terraform-local"

        with (
            patch.object(
                RUNNER,
                "_discover_gateway_backend_url",
                return_value="http://172.18.0.4:8080",
            ),
            patch.object(
                RUNNER.requests,
                "get",
                side_effect=[edge_response, backend_response],
            ) as get,
        ):
            result = RUNNER.test_gateway_health()

        self.assertTrue(result.passed)
        self.assertEqual(
            [call.args[0] for call in get.call_args_list],
            [
                "http://api.example.test/local/health",
                "http://172.18.0.4:8080/actuator/health",
            ],
        )

    def test_gateway_backend_discovery_uses_running_task_network(self) -> None:
        ecs = Mock()
        ecs.list_tasks.return_value = {"taskArns": ["task-arn"]}
        ecs.describe_tasks.return_value = {
            "tasks": [
                {
                    "lastStatus": "RUNNING",
                    "containers": [
                        {
                            "name": "gateway",
                            "lastStatus": "RUNNING",
                            "networkInterfaces": [
                                {"privateIpv4Address": "172.18.0.4"}
                            ],
                            "networkBindings": [{"containerPort": 8080}],
                        }
                    ],
                }
            ]
        }

        with patch.object(RUNNER, "get_ecs_client", return_value=ecs):
            backend_url = RUNNER._discover_gateway_backend_url()

        self.assertEqual(backend_url, "http://172.18.0.4:8080")
        ecs.list_tasks.assert_called_once_with(
            cluster=RUNNER.TestConfig.ECS_CLUSTER_NAME,
            serviceName=RUNNER.TestConfig.GATEWAY_SERVICE_NAME,
            desiredStatus="RUNNING",
        )

    def test_api_docs_use_management_endpoint(self) -> None:
        response = Mock(status_code=200)

        with patch.object(RUNNER.requests, "get", return_value=response) as get:
            result = RUNNER.test_gateway_api_docs()

        self.assertTrue(result.passed)
        requested_urls = [call.args[0] for call in get.call_args_list]
        self.assertEqual(
            requested_urls,
            [
                "https://alb.example.test/actuator/info",
                "https://alb.example.test/v3/api-docs",
                "https://alb.example.test/swagger-ui/index.html",
            ],
        )
        self.assertTrue(
            all(
                call.kwargs["verify"] is False
                for call in get.call_args_list
            )
        )

    def test_api_docs_fail_when_any_endpoint_is_unavailable(self) -> None:
        responses = [
            Mock(status_code=200),
            Mock(status_code=200),
            Mock(status_code=500),
        ]

        with patch.object(RUNNER.requests, "get", side_effect=responses):
            result = RUNNER.test_gateway_api_docs()

        self.assertFalse(result.passed)
        self.assertIn("swagger", result.error or "")

    def test_authenticated_upload_rejects_incomplete_response(self) -> None:
        auth = Mock()
        auth.get_user_token.return_value = "access-token"
        response = Mock(status_code=201)
        response.json.return_value = {
            "fileId": "88a45d72-f956-43b7-a373-2ea920965259",
            "filename": "wrong-name.txt",
        }

        with (
            patch.object(RUNNER, "get_auth", return_value=auth),
            patch.object(RUNNER.requests, "post", return_value=response),
        ):
            result = RUNNER.test_authenticated_file_upload()

        self.assertFalse(result.passed)
        self.assertIn("filename", result.error or "")

    def test_empty_summary_fails_closed(self) -> None:
        output = StringIO()

        with redirect_stdout(output):
            exit_code = RUNNER.print_summary([])

        self.assertEqual(exit_code, 1)
        self.assertIn("No tests were executed", output.getvalue())

    @patch.object(RUNNER.boto3, "client")
    def test_iam_check_uses_configured_role_names(self, client: Mock) -> None:
        iam = client.return_value
        iam.list_role_policies.return_value = {"PolicyNames": ["least-privilege"]}

        result = RUNNER.test_iam_roles_exist()

        self.assertTrue(result.passed)
        requested_roles = [
            call.kwargs["RoleName"] for call in iam.get_role.call_args_list
        ]
        self.assertEqual(
            requested_roles,
            [
                "fsamp-test-gateway-task-role",
                "fsamp-test-processor-lambda-role",
            ],
        )

    def test_localstack_readiness_failure_is_a_failed_result(self) -> None:
        with (
            patch.object(RUNNER.TestConfig, "ensure_cognito_discovered"),
            patch.object(
                RUNNER,
                "wait_for_localstack",
                side_effect=RuntimeError("localstack unavailable"),
            ),
            patch.object(RUNNER, "wait_for_gateway") as wait_for_gateway,
        ):
            results = RUNNER.run_all_tests()

        self.assertEqual(len(results), 1)
        self.assertEqual(results[0].name, "localstack_readiness")
        self.assertFalse(results[0].passed)
        self.assertIn("localstack unavailable", results[0].error or "")
        wait_for_gateway.assert_not_called()

    def test_gateway_readiness_failure_is_a_failed_result(self) -> None:
        with (
            patch.object(RUNNER.TestConfig, "ensure_cognito_discovered"),
            patch.object(RUNNER, "wait_for_localstack"),
            patch.object(
                RUNNER,
                "wait_for_gateway",
                side_effect=RuntimeError("gateway unavailable"),
            ),
        ):
            results = RUNNER.run_all_tests()

        self.assertEqual(len(results), 1)
        self.assertEqual(results[0].name, "gateway_readiness")
        self.assertFalse(results[0].passed)
        self.assertIn("gateway unavailable", results[0].error or "")


if __name__ == "__main__":
    unittest.main()
