import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const FIRST_SEEDED_ORDER_ID = Number(__ENV.FIRST_ORDER_ID || 400001);
const SEEDED_ORDER_COUNT = Number(__ENV.ORDER_COUNT || 25000);

const STATUSES = ['new', 'confirmed', 'picking', 'shipped', 'delivered', 'cancelled'];

export const options = {
  scenarios: {
    oltp: {
      executor: 'ramping-vus',
      exec: 'oltpProfile',
      stages: [
        { duration: '1m', target: 10 },
        { duration: '3m', target: 10 },
        { duration: '30s', target: 0 },
      ],
    },
    olap: {
      executor: 'ramping-vus',
      exec: 'olapProfile',
      stages: [
        { duration: '1m', target: 3 },
        { duration: '3m', target: 3 },
        { duration: '30s', target: 0 },
      ],
    },
    logs: {
      executor: 'ramping-vus',
      exec: 'logProfile',
      stages: [
        { duration: '1m', target: 10 },
        { duration: '3m', target: 10 },
        { duration: '30s', target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    'http_req_duration{profile:oltp_read}': ['p(95)<10000'],
    'http_req_duration{profile:oltp_insert}': ['p(95)<10000'],
    'http_req_duration{profile:oltp_update}': ['p(95)<10000'],
    'http_req_duration{profile:olap_revenue}': ['p(95)<30000'],
    'http_req_duration{profile:olap_turnover}': ['p(95)<30000'],
    'http_req_duration{profile:log_insert}': ['p(95)<10000'],
  },
};

function randomOrderId() {
  return FIRST_SEEDED_ORDER_ID + Math.floor(Math.random() * SEEDED_ORDER_COUNT);
}

function randomStatus() {
  return STATUSES[Math.floor(Math.random() * STATUSES.length)];
}

export function oltpProfile() {
  const orderId = randomOrderId();
  const headers = { 'Content-Type': 'application/json' };

  const responses = http.batch([
    ['GET', `${BASE_URL}/api/oltp/orders/${orderId}`, null, { tags: { profile: 'oltp_read' } }],
    ['POST', `${BASE_URL}/api/oltp/orders`, '{}', { headers, tags: { profile: 'oltp_insert' } }],
    [
      'POST',
      `${BASE_URL}/api/oltp/orders/${orderId}/status`,
      JSON.stringify({ status: randomStatus() }),
      { headers, tags: { profile: 'oltp_update' } },
    ],
  ]);

  check(responses[0], { 'oltp read status is 200': (r) => r.status === 200 });
  check(responses[1], { 'oltp insert status is 201': (r) => r.status === 201 });
  check(responses[2], { 'oltp update status is 200': (r) => r.status === 200 });
  sleep(0.2);
}

export function olapProfile() {
  const from = encodeURIComponent('2020-01-01T00:00:00Z');
  const to = encodeURIComponent('2100-01-01T00:00:00Z');

  const responses = http.batch([
    [
      'GET',
      `${BASE_URL}/api/olap/revenue-by-day?from=${from}&to=${to}`,
      null,
      { tags: { profile: 'olap_revenue' } },
    ],
    [
      'GET',
      `${BASE_URL}/api/olap/warehouse-turnover?from=${from}&to=${to}&min_quantity=1`,
      null,
      { tags: { profile: 'olap_turnover' } },
    ],
  ]);

  check(responses[0], { 'olap revenue status is 200': (r) => r.status === 200 });
  check(responses[1], { 'olap turnover status is 200': (r) => r.status === 200 });
  sleep(1);
}

export function logProfile() {
  const response = http.post(
    `${BASE_URL}/api/log/order-status-events`,
    JSON.stringify({ status: randomStatus() }),
    {
      headers: { 'Content-Type': 'application/json' },
      tags: { profile: 'log_insert' },
    },
  );

  check(response, { 'log insert status is 201': (r) => r.status === 201 });
  sleep(0.1);
}
