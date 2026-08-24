/**
 * FSAMP Soak Test
 *
 * Reuses the production-shaped multipart scenarios from load-test.js while
 * holding a moderate load long enough to expose leaks and queue backlogs.
 */

export { default, setup, teardown, handleSummary } from './load-test.js';

export const options = {
  stages: [
    { duration: '5m', target: 20 },
    { duration: '50m', target: 20 },
    { duration: '5m', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.005'],
    http_req_duration: ['p(95)<500', 'p(99)<2000'],
    upload_latency: ['p(95)<3000', 'p(99)<5000'],
    errors: ['rate<0.005'],
    http_5xx_errors: ['rate<0.001'],
    'checks{type:critical}': ['rate>0.99'],
    'checks{type:upload}': ['rate>0.98'],
  },
  tags: {
    testType: 'soak',
    environment: __ENV.ENVIRONMENT || 'staging',
  },
};
