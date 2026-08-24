/**
 * FSAMP Smoke Test
 *
 * Quick validation test to verify the system is functional.
 * Run this after deployments or before heavier load tests.
 *
 * Usage:
 *   k6 run smoke-test.js
 *   k6 run -e BASE_URL=https://api.example.com smoke-test.js
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.1/index.js';

const errorRate = new Rate('errors');
const uploadDuration = new Trend('upload_duration');

export const options = {
  vus: Number(__ENV.SMOKE_VUS || 3),
  duration: __ENV.SMOKE_DURATION || '1m',

  thresholds: {
    http_req_failed: ['rate<0.01'],      // <1% errors
    http_req_duration: ['p(95)<1000'],   // 95% under 1s
    errors: ['rate<0.01'],               // Custom error rate
  },

  tags: {
    testType: 'smoke',
    environment: __ENV.ENVIRONMENT || 'staging',
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const AUTH_TOKEN = __ENV.AUTH_TOKEN || '';
const HEALTH_PATH = __ENV.HEALTH_PATH || '/health';
const UPLOAD_PATH = __ENV.UPLOAD_PATH || '/files/upload';

const headers = {
  'Authorization': AUTH_TOKEN ? `Bearer ${AUTH_TOKEN}` : '',
  'X-Idempotency-Key': '', // Will be set per-request
};

/**
 * Generate UUID v4 for idempotency keys
 */
function uuidv4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

/**
 * Generate test file content
 */
function generateTestFile(sizeBytes) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let content = '';
  for (let i = 0; i < sizeBytes; i++) {
    content += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return content;
}

/**
 * Setup function - runs once before the test
 */
export function setup() {
  console.log(`Starting smoke test against: ${BASE_URL}`);

  if (!AUTH_TOKEN) {
    throw new Error('AUTH_TOKEN is required for authenticated upload scenarios');
  }

  const healthRes = http.get(`${BASE_URL}${HEALTH_PATH}`, { timeout: '10s' });

  if (healthRes.status !== 200) {
    console.error(`Health check failed: ${healthRes.status}`);
    throw new Error('System health check failed - aborting smoke test');
  }

  console.log('Health check passed - system is responding');

  return {
    startTime: new Date().toISOString(),
    baseUrl: BASE_URL,
  };
}

/**
 * Main test function - runs for each VU iteration
 */
export default function(data) {

  group('Health Endpoints', function() {
    const healthRes = http.get(`${BASE_URL}${HEALTH_PATH}`);
    check(healthRes, {
      'health status is 200': (r) => r.status === 200,
      'health response has status UP': (r) => {
        try {
          const body = JSON.parse(r.body);
          return body.status === 'UP';
        } catch (e) {
          return false;
        }
      },
    }) || errorRate.add(1);

  });

  group('Upload Endpoint', function() {
    const idempotencyKey = uuidv4();
    const reqHeaders = Object.assign({}, headers, {
      'X-Idempotency-Key': idempotencyKey,
    });

    const testContent = generateTestFile(1024);
    const filename = `smoke-test-${idempotencyKey}.txt`;
    const payload = {
      file: http.file(testContent, filename, 'text/plain'),
    };

    const startTime = new Date();
    const uploadRes = http.post(
      `${BASE_URL}${UPLOAD_PATH}`,
      payload,
      { headers: reqHeaders, timeout: '30s' }
    );
    const duration = new Date() - startTime;

    uploadDuration.add(duration);

    const uploadSuccess = check(uploadRes, {
      'upload status is 2xx': (r) => r.status >= 200 && r.status < 300,
      'upload response has fileId': (r) => {
        try {
          const body = JSON.parse(r.body);
          return body.fileId !== undefined;
        } catch (e) {
          return false;
        }
      },
      'upload response time < 5s': (r) => r.timings.duration < 5000,
    });

    if (!uploadSuccess) {
      errorRate.add(1);
      console.error(`Upload failed: ${uploadRes.status} - ${uploadRes.body}`);
    }

    if (uploadRes.status >= 200 && uploadRes.status < 300) {
      sleep(0.5);

      const retryRes = http.post(
        `${BASE_URL}${UPLOAD_PATH}`,
        { file: http.file(testContent, filename, 'text/plain') },
        { headers: reqHeaders, timeout: '30s' }
      );

      check(retryRes, {
        'idempotent retry returns same fileId': (r) => {
          try {
            const original = JSON.parse(uploadRes.body);
            const retry = JSON.parse(r.body);
            return original.fileId === retry.fileId;
          } catch (e) {
            return false;
          }
        },
      });
    }
  });

  group('Error Handling', function() {
    const notFoundRes = http.get(`${BASE_URL}/api/v1/nonexistent-endpoint`, {
      // API Gateway REST APIs use 403 for an undefined edge resource, while
      // the gateway container itself returns the conventional 404.
      responseCallback: http.expectedStatuses(403, 404),
    });
    check(notFoundRes, {
      'nonexistent endpoint is rejected': (r) => r.status === 403 || r.status === 404,
    });

    sleep(0.5);

    const invalidRes = http.post(
      `${BASE_URL}${UPLOAD_PATH}`,
      '{"invalid": json}',
      {
        headers: {
          'Authorization': `Bearer ${AUTH_TOKEN}`,
          'Content-Type': 'application/json',
        },
        responseCallback: http.expectedStatuses(400, 415),
      }
    );
    check(invalidRes, {
      'non-multipart upload is rejected': (r) => r.status === 400 || r.status === 415,
    });
  });

  sleep(1);
}

/**
 * Teardown function - runs once after all VUs complete
 */
export function teardown(data) {
  console.log(`Smoke test completed`);
  console.log(`Started at: ${data.startTime}`);
  console.log(`Ended at: ${new Date().toISOString()}`);
}

function collectChecks(group) {
  return (group.groups || []).reduce(
    (checks, childGroup) => checks.concat(collectChecks(childGroup)),
    group.checks || []
  );
}

export function handleSummary(data) {
  const checks = collectChecks(data.root_group);
  const passed = checks.filter(c => c.passes > 0 && c.fails === 0);
  const failed = checks.filter(c => c.fails > 0);

  console.log('\nSmoke test summary');
  console.log(`Total Checks: ${checks.length}`);
  console.log(`Passed: ${passed.length}`);
  console.log(`Failed: ${failed.length}`);

  if (failed.length > 0) {
    console.log('\nFailed Checks:');
    failed.forEach(c => console.log(`  - ${c.name}: ${c.fails} failures`));
  }

  return {
    'stdout': textSummary(data, { indent: '  ', enableColors: true }),
    'smoke-test-results.json': JSON.stringify(data, null, 2),
  };
}
