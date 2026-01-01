/**
 * FSAMP Load Test
 * 
 * Standard load test simulating realistic traffic patterns.
 * Tests the system under expected normal load conditions.
 * 
 * Usage:
 *   k6 run load-test.js
 *   k6 run -e BASE_URL=https://api.example.com load-test.js
 *   k6 run --out influxdb=http://localhost:8086/k6 load-test.js
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter, Gauge } from 'k6/metrics';
import { randomIntBetween, randomItem } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.1/index.js';

// =============================================================================
// CUSTOM METRICS
// =============================================================================

// Error tracking
const errorRate = new Rate('errors');
const http5xxRate = new Rate('http_5xx_errors');

// Latency tracking
const uploadLatency = new Trend('upload_latency', true);
const healthLatency = new Trend('health_latency', true);

// Throughput
const successfulUploads = new Counter('successful_uploads');
const failedUploads = new Counter('failed_uploads');
const bytesUploaded = new Counter('bytes_uploaded');

// SLO compliance gauge
const sloCompliance = new Gauge('slo_compliance');

// =============================================================================
// TEST CONFIGURATION
// =============================================================================

export const options = {
  // Ramping VUs pattern
  stages: [
    { duration: '2m', target: 20 },   // Ramp up to 20 users
    { duration: '3m', target: 50 },   // Ramp up to 50 users
    { duration: '5m', target: 50 },   // Stay at 50 users
    { duration: '3m', target: 20 },   // Scale down to 20
    { duration: '2m', target: 0 },    // Ramp down to 0
  ],
  
  // SLO-based thresholds
  thresholds: {
    // Availability: 99.5% (max 0.5% errors)
    http_req_failed: ['rate<0.005'],
    
    // Latency SLOs
    http_req_duration: ['p(50)<200', 'p(95)<500', 'p(99)<2000'],
    upload_latency: ['p(95)<3000', 'p(99)<5000'],
    health_latency: ['p(95)<100'],
    
    // Error rates
    errors: ['rate<0.005'],
    http_5xx_errors: ['rate<0.001'],
    
    // Custom checks
    'checks{type:critical}': ['rate>0.99'],
    'checks{type:upload}': ['rate>0.98'],
  },
  
  // Tags for dashboards
  tags: {
    testType: 'load',
    environment: __ENV.ENVIRONMENT || 'staging',
  },
  
  // Graceful stop
  gracefulStop: '30s',
};

// =============================================================================
// CONFIGURATION
// =============================================================================

const CONFIG = {
  baseUrl: __ENV.BASE_URL || 'http://localhost:8080',
  authToken: __ENV.AUTH_TOKEN || '',
  
  // Request timeouts
  timeout: '30s',
  uploadTimeout: '60s',
  
  // Test data variations
  fileSizes: [
    1024,        // 1 KB
    10240,       // 10 KB
    102400,      // 100 KB
    524288,      // 512 KB
    1048576,     // 1 MB
  ],
  
  fileTypes: [
    { ext: 'txt', mime: 'text/plain' },
    { ext: 'json', mime: 'application/json' },
    { ext: 'pdf', mime: 'application/pdf' },
    { ext: 'png', mime: 'image/png' },
    { ext: 'xml', mime: 'application/xml' },
  ],
  
  // Sleep ranges (seconds)
  thinkTimeMin: 1,
  thinkTimeMax: 3,
};

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

/**
 * Generate UUID v4
 */
function uuidv4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

/**
 * Generate random file content
 */
function generateFileContent(sizeBytes) {
  // Use a more efficient method for larger files
  if (sizeBytes <= 10240) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    let content = '';
    for (let i = 0; i < sizeBytes; i++) {
      content += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return content;
  }
  
  // For larger files, use repeated pattern
  const pattern = 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '.repeat(100);
  let content = '';
  while (content.length < sizeBytes) {
    content += pattern;
  }
  return content.substring(0, sizeBytes);
}

/**
 * Build headers with auth and idempotency
 */
function buildHeaders(idempotencyKey) {
  const headers = {
    'Content-Type': 'application/json',
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

/**
 * Simulate realistic user think time
 */
function thinkTime() {
  sleep(randomIntBetween(CONFIG.thinkTimeMin, CONFIG.thinkTimeMax));
}

// =============================================================================
// SETUP
// =============================================================================

export function setup() {
  console.log(`\n========================================`);
  console.log(`FSAMP Load Test`);
  console.log(`Target: ${CONFIG.baseUrl}`);
  console.log(`========================================\n`);
  
  // Verify system is healthy before starting
  const healthRes = http.get(`${CONFIG.baseUrl}/actuator/health`, {
    timeout: '10s',
  });
  
  if (healthRes.status !== 200) {
    throw new Error(`Health check failed: ${healthRes.status}`);
  }
  
  const healthBody = JSON.parse(healthRes.body);
  if (healthBody.status !== 'UP') {
    throw new Error(`System not healthy: ${healthBody.status}`);
  }
  
  console.log('✓ System health verified');
  
  return {
    startTime: new Date().toISOString(),
    baseUrl: CONFIG.baseUrl,
  };
}

// =============================================================================
// MAIN TEST SCENARIO
// =============================================================================

export default function(data) {
  const vu = __VU;
  const iter = __ITER;
  
  // Weighted scenario selection (realistic traffic mix)
  const scenarios = [
    { name: 'upload', weight: 60 },
    { name: 'health', weight: 20 },
    { name: 'status', weight: 20 },
  ];
  
  const totalWeight = scenarios.reduce((sum, s) => sum + s.weight, 0);
  const random = Math.random() * totalWeight;
  let cumulative = 0;
  let selectedScenario = 'upload';
  
  for (const scenario of scenarios) {
    cumulative += scenario.weight;
    if (random <= cumulative) {
      selectedScenario = scenario.name;
      break;
    }
  }
  
  // Execute selected scenario
  switch (selectedScenario) {
    case 'upload':
      uploadScenario(vu, iter);
      break;
    case 'health':
      healthScenario();
      break;
    case 'status':
      statusScenario();
      break;
  }
  
  thinkTime();
}

// =============================================================================
// TEST SCENARIOS
// =============================================================================

/**
 * File upload scenario
 */
function uploadScenario(vu, iter) {
  group('File Upload', function() {
    const idempotencyKey = uuidv4();
    const fileSize = randomItem(CONFIG.fileSizes);
    const fileType = randomItem(CONFIG.fileTypes);
    
    // Generate test file
    const content = generateFileContent(fileSize);
    const filename = `load-test-vu${vu}-iter${iter}-${idempotencyKey}.${fileType.ext}`;
    
    const payload = JSON.stringify({
      filename: filename,
      content: content,
      contentType: fileType.mime,
      metadata: {
        testRun: true,
        vuId: vu,
        iteration: iter,
        timestamp: new Date().toISOString(),
      },
    });
    
    const headers = buildHeaders(idempotencyKey);
    
    // Execute upload
    const startTime = new Date();
    const response = http.post(
      `${CONFIG.baseUrl}/api/v1/files/upload`,
      payload,
      {
        headers: headers,
        timeout: CONFIG.uploadTimeout,
        tags: { name: 'upload', endpoint: 'upload' },
      }
    );
    const duration = new Date() - startTime;
    
    // Record metrics
    uploadLatency.add(duration);
    bytesUploaded.add(fileSize);
    
    // Track 5xx errors specifically
    if (response.status >= 500) {
      http5xxRate.add(1);
    } else {
      http5xxRate.add(0);
    }
    
    // Checks
    const success = check(response, {
      'upload: status is 2xx': (r) => r.status >= 200 && r.status < 300,
      'upload: has fileId': (r) => {
        try {
          return JSON.parse(r.body).fileId !== undefined;
        } catch (e) {
          return false;
        }
      },
      'upload: latency < 3s': (r) => r.timings.duration < 3000,
    }, { type: 'upload' });
    
    // Update counters
    if (success) {
      successfulUploads.add(1);
      errorRate.add(0);
      sloCompliance.add(1);
    } else {
      failedUploads.add(1);
      errorRate.add(1);
      sloCompliance.add(0);
      
      // Log failure details for debugging
      console.warn(`Upload failed: VU=${vu}, Status=${response.status}, Body=${response.body.substring(0, 200)}`);
    }
  });
}

/**
 * Health check scenario
 */
function healthScenario() {
  group('Health Check', function() {
    const startTime = new Date();
    const response = http.get(`${CONFIG.baseUrl}/actuator/health`, {
      timeout: CONFIG.timeout,
      tags: { name: 'health', endpoint: 'health' },
    });
    const duration = new Date() - startTime;
    
    healthLatency.add(duration);
    
    check(response, {
      'health: status is 200': (r) => r.status === 200,
      'health: status is UP': (r) => {
        try {
          return JSON.parse(r.body).status === 'UP';
        } catch (e) {
          return false;
        }
      },
      'health: latency < 100ms': (r) => r.timings.duration < 100,
    }, { type: 'critical' });
  });
}

/**
 * Status/info check scenario
 */
function statusScenario() {
  group('Status Check', function() {
    // Check multiple status endpoints
    const endpoints = [
      '/actuator/info',
      '/actuator/metrics',
    ];
    
    for (const endpoint of endpoints) {
      const response = http.get(`${CONFIG.baseUrl}${endpoint}`, {
        timeout: CONFIG.timeout,
        tags: { name: 'status', endpoint: endpoint },
      });
      
      check(response, {
        [`${endpoint}: status is 2xx`]: (r) => r.status >= 200 && r.status < 300,
      });
    }
  });
}

// =============================================================================
// TEARDOWN
// =============================================================================

export function teardown(data) {
  console.log(`\n========================================`);
  console.log(`Load Test Completed`);
  console.log(`Started: ${data.startTime}`);
  console.log(`Ended: ${new Date().toISOString()}`);
  console.log(`========================================\n`);
}

// =============================================================================
// SUMMARY
// =============================================================================

export function handleSummary(data) {
  // Calculate SLO compliance
  const httpFailed = data.metrics.http_req_failed?.values?.rate || 0;
  const p95Latency = data.metrics.http_req_duration?.values?.['p(95)'] || 0;
  const p99Latency = data.metrics.http_req_duration?.values?.['p(99)'] || 0;
  
  const availabilitySLO = httpFailed < 0.005;
  const latencyP95SLO = p95Latency < 500;
  const latencyP99SLO = p99Latency < 2000;
  
  console.log('\n========== SLO COMPLIANCE ==========');
  console.log(`Availability (99.5%): ${availabilitySLO ? '✓ PASS' : '✗ FAIL'} (${((1 - httpFailed) * 100).toFixed(3)}%)`);
  console.log(`Latency p95 (<500ms): ${latencyP95SLO ? '✓ PASS' : '✗ FAIL'} (${p95Latency.toFixed(0)}ms)`);
  console.log(`Latency p99 (<2000ms): ${latencyP99SLO ? '✓ PASS' : '✗ FAIL'} (${p99Latency.toFixed(0)}ms)`);
  console.log('====================================\n');
  
  return {
    'stdout': textSummary(data, { indent: '  ', enableColors: true }),
    'load-test-results.json': JSON.stringify(data, null, 2),
  };
}
