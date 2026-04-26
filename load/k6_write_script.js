import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const FIRST_SEEDED_ORDER_ID = Number(__ENV.FIRST_ORDER_ID || 400001);
const SEEDED_ORDER_COUNT = Number(__ENV.ORDER_COUNT || 300000);
const STATUSES = ['new', 'confirmed', 'picking', 'shipped', 'delivered', 'cancelled'];

export const options = {
  scenarios: {
    writes: {
      executor: 'constant-vus',
      vus: 10,
      duration: '1m',
      exec: 'writeProfile',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    'http_req_duration{profile:oltp_insert}': ['p(95)<10000'],
    'http_req_duration{profile:oltp_update}': ['p(95)<10000'],
    'http_req_duration{profile:log_insert}': ['p(95)<10000'],
  },
};

function randomOrderId() {
  return FIRST_SEEDED_ORDER_ID + Math.floor(Math.random() * SEEDED_ORDER_COUNT);
}

function randomStatus() {
  return STATUSES[Math.floor(Math.random() * STATUSES.length)];
}

export function writeProfile() {
  const headers = { 'Content-Type': 'application/json' };
  const orderId = randomOrderId();

  const responses = http.batch([
    ['POST', `${BASE_URL}/api/oltp/orders`, '{}', { headers, tags: { profile: 'oltp_insert' } }],
    [
      'POST',
      `${BASE_URL}/api/oltp/orders/${orderId}/status`,
      JSON.stringify({ status: randomStatus() }),
      { headers, tags: { profile: 'oltp_update' } },
    ],
    [
      'POST',
      `${BASE_URL}/api/log/order-status-events`,
      JSON.stringify({ status: randomStatus() }),
      { headers, tags: { profile: 'log_insert' } },
    ],
  ]);

  check(responses[0], { 'insert status is 201': (r) => r.status === 201 });
  check(responses[1], { 'update status is 200': (r) => r.status === 200 });
  check(responses[2], { 'log status is 201': (r) => r.status === 201 });
  sleep(0.1);
}
