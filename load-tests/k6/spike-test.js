/**
 * FSAMP Spike Test
 * 
 * Tests system behavior under sudden dramatic traffic increases.
 * Simulates viral events or flash sales scenarios.
 * 
 * Usage:
 *   k6 run spike-test.js
 *   k6 run -e BASE_URL=https://api.example.com spike-test.js
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.1/index.js';

const errorRate = new Rate('errors');
const spikeLatency = new Trend('spike_latency', true);
const preSpike = new Counter('pre_spike_requests');
const duringSpike = new Counter('during_spike_requests');
const postSpike = new Counter('post_spike_requests');

export const options = {
  stages: [
    { duration: '1m', target: 10 },
    
    { duration: '10s', target: 200 },  // Ramp to 200 VUs in 10 seconds
    
    { duration: '1m', target: 200 },
    
    { duration: '10s', target: 10 },
    
    { duration: '2m', target: 10 },
    
    { duration: '30s', target: 0 },
  ],
  
  thresholds: {
    http_req_failed: ['rate<0.05'],  // Allow 5% errors
    http_req_duration: ['p(95)<5000'],
    errors: ['rate<0.05'],
  },
  
  tags: {
    testType: 'spike',
    environment: __ENV.ENVIRONMENT || 'staging',
  },
};

const CONFIG = {
  baseUrl: __ENV.BASE_URL || 'http://localhost:8080',
  authToken: __ENV.AUTH_TOKEN || '',
};

const TEST_PHASES = {
  PRE_SPIKE: 'pre_spike',
  SPIKE: 'spike',
  POST_SPIKE: 'post_spike',
};

function getCurrentPhase(elapsedSeconds) {
  if (elapsedSeconds < 60) return TEST_PHASES.PRE_SPIKE;
  if (elapsedSeconds < 130) return TEST_PHASES.SPIKE;  // 60s + 10s + 60s
  return TEST_PHASES.POST_SPIKE;
}

function uuidv4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

export function setup() {
  console.log(`\nFSAMP Spike Test`);
  console.log(`Target: ${CONFIG.baseUrl}`);
  console.log(`Pattern: 10 VUs -> 200 VUs -> 10 VUs (sudden spike)`);
  console.log('');
  
  return {
    startTime: Date.now(),
    baseUrl: CONFIG.baseUrl,
  };
}

export default function(data) {
  const elapsedSeconds = (Date.now() - data.startTime) / 1000;
  const phase = getCurrentPhase(elapsedSeconds);
  
  group(`${phase} - Request`, function() {
    const idempotencyKey = uuidv4();
    const payload = JSON.stringify({
      filename: `spike-test-${phase}-${idempotencyKey}.txt`,
      content: 'Spike test content - minimal payload for maximum throughput',
      contentType: 'text/plain',
      metadata: {
        phase: phase,
        elapsedSeconds: Math.floor(elapsedSeconds),
        activeVUs: __VU,
      },
    });
    
    const headers = {
      'Content-Type': 'application/json',
      'X-Idempotency-Key': idempotencyKey,
      'X-Request-ID': uuidv4(),
    };
    
    if (CONFIG.authToken) {
      headers['Authorization'] = `Bearer ${CONFIG.authToken}`;
    }
    
    const startTime = new Date();
    const response = http.post(
      `${CONFIG.baseUrl}/api/v1/files/upload`,
      payload,
      {
        headers: headers,
        timeout: '60s',
        tags: { phase: phase },
      }
    );
    const duration = new Date() - startTime;
    
    spikeLatency.add(duration);
    
    switch (phase) {
      case TEST_PHASES.PRE_SPIKE:
        preSpike.add(1);
        break;
      case TEST_PHASES.SPIKE:
        duringSpike.add(1);
        break;
      case TEST_PHASES.POST_SPIKE:
        postSpike.add(1);
        break;
    }
    
    const success = check(response, {
      'status is 2xx': (r) => r.status >= 200 && r.status < 300,
      'not rate limited': (r) => r.status !== 429,
      'not server error': (r) => r.status < 500,
    });
    
    if (success) {
      errorRate.add(0);
    } else {
      errorRate.add(1);
      
      if (phase === TEST_PHASES.SPIKE) {
        console.warn(`Spike error at ${Math.floor(elapsedSeconds)}s: ${response.status}`);
      }
    }
  });
  
  sleep(0.1);
}

export function teardown(data) {
  const totalDuration = (Date.now() - data.startTime) / 1000;
  
  console.log(`\nSpike Test Completed`);
  console.log(`Total Duration: ${totalDuration.toFixed(0)}s`);
  console.log('');
}

export function handleSummary(data) {
  const preSpike = data.metrics.pre_spike_requests?.values?.count || 0;
  const duringSpike = data.metrics.during_spike_requests?.values?.count || 0;
  const postSpike = data.metrics.post_spike_requests?.values?.count || 0;
  
  const p95Pre = data.metrics['http_req_duration{phase:pre_spike}']?.values?.['p(95)'] || 'N/A';
  const p95Spike = data.metrics['http_req_duration{phase:spike}']?.values?.['p(95)'] || 'N/A';
  const p95Post = data.metrics['http_req_duration{phase:post_spike}']?.values?.['p(95)'] || 'N/A';
  
  console.log('\nSpike test analysis');
  console.log('Request Distribution:');
  console.log(`  Pre-spike: ${preSpike} requests`);
  console.log(`  During spike: ${duringSpike} requests`);
  console.log(`  Post-spike: ${postSpike} requests`);
  console.log('\nLatency by Phase (p95):');
  console.log(`  Pre-spike: ${typeof p95Pre === 'number' ? p95Pre.toFixed(0) + 'ms' : p95Pre}`);
  console.log(`  During spike: ${typeof p95Spike === 'number' ? p95Spike.toFixed(0) + 'ms' : p95Spike}`);
  console.log(`  Post-spike (recovery): ${typeof p95Post === 'number' ? p95Post.toFixed(0) + 'ms' : p95Post}`);
  console.log('');
  
  return {
    'stdout': textSummary(data, { indent: '  ', enableColors: true }),
    'spike-test-results.json': JSON.stringify(data, null, 2),
  };
}
