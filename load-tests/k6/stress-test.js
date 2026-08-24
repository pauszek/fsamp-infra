/**
 * FSAMP Stress Test
 *
 * Push the system beyond normal capacity to find breaking points.
 * Identifies the maximum throughput and failure modes.
 *
 * Usage:
 *   k6 run stress-test.js
 *   k6 run -e BASE_URL=https://api.example.com stress-test.js
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter, Gauge } from 'k6/metrics';
import { randomIntBetween, randomItem } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.1/index.js';
const errorRate = new Rate('errors');
const http5xxRate = new Rate('http_5xx_errors');
const uploadLatency = new Trend('upload_latency', true);
const successfulRequests = new Counter('successful_requests');
const failedRequests = new Counter('failed_requests');
const breakingPointVUs = new Gauge('breaking_point_vus');
const recoveryTime = new Gauge('recovery_time_seconds');
export const options = {
  stages: [
    { duration: '1m', target: 50 },

    { duration: '2m', target: 100 },
    { duration: '2m', target: 100 },  // Hold

    { duration: '2m', target: 200 },
    { duration: '2m', target: 200 },  // Hold

    { duration: '2m', target: 300 },
    { duration: '2m', target: 300 },  // Hold (likely breaking point)

    { duration: '2m', target: 400 },
    { duration: '2m', target: 400 },  // Hold (beyond capacity)

    { duration: '2m', target: 100 },
    { duration: '2m', target: 50 },
    { duration: '1m', target: 0 },
  ],

  thresholds: {
    http_req_failed: ['rate<0.10'],  // Allow up to 10% errors
    http_req_duration: ['p(95)<10000'],  // Allow higher latency

    errors: ['rate<0.15'],
    http_5xx_errors: ['rate<0.10'],
  },

  tags: {
    testType: 'stress',
    environment: __ENV.ENVIRONMENT || 'staging',
  },

};
const CONFIG = {
  baseUrl: __ENV.BASE_URL || 'http://localhost:8080',
  authToken: __ENV.AUTH_TOKEN || '',
  healthPath: __ENV.HEALTH_PATH || '/health',
  uploadPath: __ENV.UPLOAD_PATH || '/files/upload',
  timeout: '60s',
  uploadTimeout: '120s',

  fileSizes: [
    1024,    // 1 KB
    5120,    // 5 KB
    10240,   // 10 KB
  ],
};
function uuidv4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

function generateFileContent(sizeBytes) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let content = '';
  for (let i = 0; i < sizeBytes; i++) {
    content += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return content;
}

function buildHeaders(idempotencyKey) {
  const headers = {
    'X-Request-ID': uuidv4(),
  };

  if (CONFIG.authToken) {
    headers['Authorization'] = `Bearer ${CONFIG.authToken}`;
  }

  if (idempotencyKey) {
    headers['X-Idempotency-Key'] = idempotencyKey;
  }

  return headers;
}

let breakingPointDetected = false;
let breakingPointTime = null;
let consecutiveErrors = 0;
const ERROR_THRESHOLD = 10;
export function setup() {
  console.log(`\nFSAMP Stress Test`);
  console.log(`Target: ${CONFIG.baseUrl}`);
  console.log(`Warning: this test pushes the system to failure`);
  console.log('');

  if (!CONFIG.authToken) {
    throw new Error('AUTH_TOKEN is required for authenticated upload scenarios');
  }

  const healthRes = http.get(`${CONFIG.baseUrl}${CONFIG.healthPath}`, {
    timeout: '10s',
  });

  if (healthRes.status !== 200) {
    console.warn(`Warning: Initial health check returned ${healthRes.status}`);
  }

  return {
    startTime: new Date().toISOString(),
    baseUrl: CONFIG.baseUrl,
  };
}
export default function(data) {
  const vu = __VU;
  const iter = __ITER;

  group('Stress Upload', function() {
    const idempotencyKey = uuidv4();
    const fileSize = randomItem(CONFIG.fileSizes);
    const content = generateFileContent(fileSize);

    const payload = {
      file: http.file(
        content,
        `stress-test-vu${vu}-${idempotencyKey}.txt`,
        'text/plain'
      ),
    };

    const headers = buildHeaders(idempotencyKey);

    const startTime = new Date();
    const response = http.post(
      `${CONFIG.baseUrl}${CONFIG.uploadPath}`,
      payload,
      {
        headers: headers,
        timeout: CONFIG.uploadTimeout,
        tags: { name: 'stress_upload' },
      }
    );
    const duration = new Date() - startTime;

    uploadLatency.add(duration);

    if (response.status >= 500) {
      http5xxRate.add(1);
      consecutiveErrors++;

      if (!breakingPointDetected && consecutiveErrors >= ERROR_THRESHOLD) {
        breakingPointDetected = true;
        breakingPointTime = new Date().toISOString();
        breakingPointVUs.add(__VU);
        console.warn(`\nBREAKING POINT DETECTED at ${__VU} VUs!`);
        console.warn(`Time: ${breakingPointTime}`);
        console.warn(`Error: ${response.status} - ${response.body.substring(0, 200)}\n`);
      }
    } else {
      http5xxRate.add(0);

      if (breakingPointDetected && consecutiveErrors > 0) {
        const recoveryStart = new Date();
        if (response.status >= 200 && response.status < 300) {
          console.log(`OK System recovering at ${__VU} VUs`);
          consecutiveErrors = 0;
        }
      } else {
        consecutiveErrors = 0;
      }
    }

    const success = check(response, {
      'stress: status is 2xx': (r) => r.status >= 200 && r.status < 300,
      'stress: not rate limited': (r) => r.status !== 429,
      'stress: not server error': (r) => r.status < 500,
      'stress: latency < 10s': (r) => r.timings.duration < 10000,
    });

    if (success) {
      successfulRequests.add(1);
      errorRate.add(0);
    } else {
      failedRequests.add(1);
      errorRate.add(1);
    }

    if (iter % 100 === 0) {
      console.log(`VU ${vu}, Iter ${iter}: ${response.status} (${duration}ms)`);
    }
  });

  sleep(0.1);
}
export function teardown(data) {
  console.log(`\nStress Test Completed`);
  console.log(`Started: ${data.startTime}`);
  console.log(`Ended: ${new Date().toISOString()}`);

  if (breakingPointDetected) {
    console.log(`\nBreaking point detected`);
    console.log(`Time: ${breakingPointTime}`);
  } else {
    console.log(`\nNo breaking point detected within test parameters`);
  }

  console.log('');
}
export function handleSummary(data) {
  const totalRequests = data.metrics.http_reqs?.values?.count || 0;
  const failedRequests = data.metrics.http_req_failed?.values?.passes || 0;
  const maxVUs = data.metrics.vus_max?.values?.max || 0;
  const p95Latency = data.metrics.http_req_duration?.values?.['p(95)'] || 0;
  const p99Latency = data.metrics.http_req_duration?.values?.['p(99)'] || 0;

  console.log('\nStress test results');
  console.log(`Max VUs Reached: ${maxVUs}`);
  console.log(`Total Requests: ${totalRequests}`);
  console.log(`Failed Requests: ${failedRequests}`);
  console.log(`Error Rate: ${((failedRequests / totalRequests) * 100).toFixed(2)}%`);
  console.log(`Latency p95: ${p95Latency.toFixed(0)}ms`);
  console.log(`Latency p99: ${p99Latency.toFixed(0)}ms`);

  if (breakingPointDetected) {
    console.log(`\nBreaking point: ~${maxVUs} VUs`);
    console.log(`Recommendation: Scale infrastructure or add rate limiting`);
  } else {
    console.log(`\nSystem handled ${maxVUs} VUs without breaking`);
  }
  console.log('');

  return {
    'stdout': textSummary(data, { indent: '  ', enableColors: true }),
    'stress-test-results.json': JSON.stringify(data, null, 2),
  };
}
