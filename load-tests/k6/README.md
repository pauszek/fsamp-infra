# FSAMP Load Testing with k6

> Performance and load testing suite for FSAMP platform

## Overview

This directory contains k6 load testing scripts for validating the performance
and reliability of the FSAMP platform.

## Prerequisites

### Install k6

```bash
# macOS
brew install k6

# Linux (Debian/Ubuntu)
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update
sudo apt-get install k6

# Docker
docker pull grafana/k6
```

### Configure Environment

```bash
# Copy example config
cp config.example.json config.json

# Edit with your values
vim config.json
```

## Test Types

| Script | Purpose | Duration |
|--------|---------|----------|
| `smoke-test.js` | Verify system works under minimal load | ~1 min |
| `load-test.js` | Normal load testing | ~10 min |
| `stress-test.js` | Find breaking points | ~15 min |
| `spike-test.js` | Sudden traffic spikes | ~5 min |
| `soak-test.js` | Extended duration testing | ~1 hour |

## Quick Start

```bash
# Run smoke test first
k6 run smoke-test.js

# Run full load test
k6 run load-test.js

# Run with custom config
k6 run -e BASE_URL=https://api.example.com load-test.js

# Run with Docker
docker run -i grafana/k6 run - < load-test.js
```

## Test Scenarios

### 1. Smoke Test

Minimal load to verify the system is functional:
- 1-5 VUs (Virtual Users)
- Duration: 1 minute
- Use case: Quick validation after deployment

```bash
k6 run smoke-test.js
```

### 2. Load Test

Standard load testing with realistic traffic:
- Ramp up: 0 → 50 VUs over 2 minutes
- Sustained: 50 VUs for 5 minutes
- Ramp down: 50 → 0 VUs over 2 minutes

```bash
k6 run load-test.js
```

### 3. Stress Test

Push the system beyond normal capacity:
- Progressive ramp: 0 → 100 → 200 → 300 VUs
- Find breaking points
- Monitor recovery

```bash
k6 run stress-test.js
```

### 4. Spike Test

Sudden dramatic increases in traffic:
- Baseline: 10 VUs
- Spike: 10 → 200 VUs instantly
- Recovery monitoring

```bash
k6 run spike-test.js
```

## Thresholds (SLO Validation)

Tests are configured with thresholds matching our SLOs:

```javascript
thresholds: {
  // Availability: 99.5%
  'http_req_failed': ['rate<0.005'],
  
  // Latency SLOs
  'http_req_duration': ['p(95)<500', 'p(99)<2000'],
  
  // Error rate
  'http_req_failed{endpoint:upload}': ['rate<0.01'],
}
```

## Output & Reporting

### Console Output

```bash
k6 run load-test.js
```

### JSON Output

```bash
k6 run --out json=results.json load-test.js
```

### InfluxDB + Grafana

```bash
# Start InfluxDB and Grafana
docker-compose up -d

# Run with InfluxDB output
k6 run --out influxdb=http://localhost:8086/k6 load-test.js
```

### CloudWatch Integration

```bash
# Output to CloudWatch (custom extension)
K6_CLOUDWATCH_NAMESPACE=FSAMP/LoadTests k6 run load-test.js
```

## CI/CD Integration

### GitHub Actions

```yaml
- name: Run k6 Load Test
  uses: grafana/k6-action@v0.3.1
  with:
    filename: load-tests/k6/load-test.js
  env:
    BASE_URL: ${{ secrets.API_URL }}
    AUTH_TOKEN: ${{ secrets.TEST_AUTH_TOKEN }}
```

### GitLab CI

```yaml
load-test:
  image: grafana/k6
  script:
    - k6 run load-tests/k6/load-test.js
  artifacts:
    paths:
      - results.json
```

## Interpreting Results

### Key Metrics

| Metric | Description | Good Value |
|--------|-------------|------------|
| `http_req_duration` | Total request time | p95 < 500ms |
| `http_req_failed` | Failed request rate | < 0.5% |
| `http_reqs` | Requests per second | > 100 RPS |
| `vus` | Active virtual users | As configured |
| `iterations` | Completed test iterations | All expected |

### Sample Output

```
     ✓ status is 200
     ✓ response time < 500ms
     ✓ upload successful

     checks.........................: 100.00% ✓ 15000  ✗ 0
     data_received..................: 45 MB   450 kB/s
     data_sent......................: 1.2 GB  12 MB/s
     http_req_blocked...............: avg=1.2ms   p(95)=3.5ms
     http_req_connecting............: avg=0.8ms   p(95)=2.1ms
     http_req_duration..............: avg=234ms   p(95)=478ms   p(99)=1.2s
     http_req_failed................: 0.12%   ✓ 18     ✗ 14982
     http_req_receiving.............: avg=12ms    p(95)=45ms
     http_req_sending...............: avg=8ms     p(95)=22ms
     http_req_waiting...............: avg=214ms   p(95)=420ms
     http_reqs......................: 15000   150/s
     iteration_duration.............: avg=1.2s    p(95)=2.5s
     iterations.....................: 5000    50/s
     vus............................: 50      min=1    max=50
     vus_max........................: 50      min=50   max=50
```

## Troubleshooting

### Common Issues

1. **Connection refused**: Check BASE_URL and network access
2. **401 Unauthorized**: Verify AUTH_TOKEN is valid
3. **High error rate**: Check target service health
4. **Timeout errors**: Increase timeout or reduce load

### Debug Mode

```bash
# Verbose logging
k6 run --verbose load-test.js

# HTTP debugging
k6 run --http-debug load-test.js
```

## Resources

- [k6 Documentation](https://k6.io/docs/)
- [k6 Examples](https://github.com/grafana/k6/tree/master/examples)
- [SRE Book - Testing](https://sre.google/sre-book/testing-reliability/)
