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

// Custom metrics
const errorRate = new Rate('errors');
const uploadDuration = new Trend('upload_duration');

// Test configuration
export const options = {
  vus: 3,
  duration: '1m',
  
  thresholds: {
    // Strict thresholds for smoke test
    http_req_failed: ['rate<0.01'],      // <1% errors
    http_req_duration: ['p(95)<1000'],   // 95% under 1s
    errors: ['rate<0.01'],               // Custom error rate
  },
  
  // Tags for filtering in dashboards
  tags: {
    testType: 'smoke',
    environment: __ENV.ENVIRONMENT || 'staging',
  },
};

// Configuration from environment or defaults
const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const AUTH_TOKEN = __ENV.AUTH_TOKEN || '';

// Request headers
const headers = {
  'Content-Type': 'application/json',
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
  
  // Verify connectivity
  const healthRes = http.get(`${BASE_URL}/actuator/health`, { timeout: '10s' });
  
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
    // Health check
    const healthRes = http.get(`${BASE_URL}/actuator/health`);
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
    
    sleep(0.5);
    
    // Info endpoint
    const infoRes = http.get(`${BASE_URL}/actuator/info`);
    check(infoRes, {
      'info status is 200': (r) => r.status === 200,
    }) || errorRate.add(1);
  });
  
  group('Upload Endpoint', function() {
    // Generate unique idempotency key
    const idempotencyKey = uuidv4();
    const reqHeaders = Object.assign({}, headers, {
      'X-Idempotency-Key': idempotencyKey,
    });
    
    // Small file upload (1KB)
    const testContent = generateTestFile(1024);
    const payload = {
      filename: `smoke-test-${idempotencyKey}.txt`,
      content: testContent,
      contentType: 'text/plain',
    };
    
    const startTime = new Date();
    const uploadRes = http.post(
      `${BASE_URL}/api/v1/files/upload`,
      JSON.stringify(payload),
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
    
    // Test idempotency - same key should return same result
    if (uploadRes.status >= 200 && uploadRes.status < 300) {
      sleep(0.5);
      
      const retryRes = http.post(
        `${BASE_URL}/api/v1/files/upload`,
        JSON.stringify(payload),
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
    // Test 404 handling
    const notFoundRes = http.get(`${BASE_URL}/api/v1/nonexistent-endpoint`);
    check(notFoundRes, {
      'nonexistent endpoint returns 404': (r) => r.status === 404,
    });
    
    sleep(0.5);
    
    // Test invalid payload handling
    const invalidRes = http.post(
      `${BASE_URL}/api/v1/files/upload`,
      '{"invalid": json}',
      { headers: { 'Content-Type': 'application/json' } }
    );
    check(invalidRes, {
      'invalid JSON returns 400': (r) => r.status === 400,
    });
  });
  
  // Pause between iterations
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

/**
 * Handle test summary
 */
export function handleSummary(data) {
  const passed = data.root_group.checks.filter(c => c.passes > 0 && c.fails === 0);
  const failed = data.root_group.checks.filter(c => c.fails > 0);
  
  console.log('\n========== SMOKE TEST SUMMARY ==========');
  console.log(`Total Checks: ${data.root_group.checks.length}`);
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

// Import text summary helper
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.1/index.js';
