#!/usr/bin/env bash
set -euo pipefail

: "${CLICKHOUSE_DB:?}"
: "${CLICKHOUSE_ADMIN_USER:?}"
: "${CLICKHOUSE_ADMIN_PASSWORD:?}"
: "${CLICKHOUSE_METABASE_USER:?}"
: "${CLICKHOUSE_METABASE_PASSWORD:?}"
: "${CLICKHOUSE_CDC_TOPIC:?}"
: "${CLICKHOUSE_KAFKA_GROUP:?}"

clickhouse_ready() {
  clickhouse-client --query "SELECT 1" >/dev/null 2>&1
}

until clickhouse_ready; do
  sleep 1
done

clickhouse-client \
  --multiquery <<SQL
CREATE DATABASE IF NOT EXISTS ${CLICKHOUSE_DB};

CREATE USER IF NOT EXISTS ${CLICKHOUSE_ADMIN_USER}
IDENTIFIED WITH plaintext_password BY '${CLICKHOUSE_ADMIN_PASSWORD}';

CREATE TABLE IF NOT EXISTS ${CLICKHOUSE_DB}.inventory_movements_queue
(
  raw_message String
)
ENGINE = Kafka
SETTINGS
  kafka_broker_list = 'kafka:9092',
  kafka_topic_list = '${CLICKHOUSE_CDC_TOPIC}',
  kafka_group_name = '${CLICKHOUSE_KAFKA_GROUP}',
  kafka_format = 'JSONAsString',
  kafka_num_consumers = 1,
  kafka_handle_error_mode = 'stream';

CREATE TABLE IF NOT EXISTS ${CLICKHOUSE_DB}.inventory_movements_cdc
(
  inventory_movement_id UInt64,
  product_id UInt64,
  warehouse_id UInt64,
  movement_type LowCardinality(String),
  quantity Decimal(14, 3),
  moved_at DateTime64(3, 'UTC'),
  employee_id UInt64,
  cdc_op LowCardinality(String),
  cdc_source_ts_ms UInt64,
  version UInt64,
  is_deleted UInt8
)
ENGINE = ReplacingMergeTree(version)
ORDER BY (inventory_movement_id);

CREATE MATERIALIZED VIEW IF NOT EXISTS ${CLICKHOUSE_DB}.inventory_movements_queue_mv
TO ${CLICKHOUSE_DB}.inventory_movements_cdc
AS
SELECT
  JSONExtractUInt(raw_message, 'inventory_movement_id') AS inventory_movement_id,
  JSONExtractUInt(raw_message, 'product_id') AS product_id,
  JSONExtractUInt(raw_message, 'warehouse_id') AS warehouse_id,
  JSONExtractString(raw_message, 'movement_type') AS movement_type,
  toDecimal64OrZero(JSONExtractString(raw_message, 'quantity'), 3) AS quantity,
  parseDateTime64BestEffortOrNull(JSONExtractString(raw_message, 'moved_at'), 3, 'UTC') AS moved_at,
  JSONExtractUInt(raw_message, 'employee_id') AS employee_id,
  JSONExtractString(raw_message, '__op') AS cdc_op,
  toUInt64OrZero(JSONExtractString(raw_message, '__source_ts_ms')) AS cdc_source_ts_ms,
  greatest(toUInt64OrZero(JSONExtractString(raw_message, '__source_ts_ms')), toUInt64(toUnixTimestamp64Milli(now64(3)))) AS version,
  if(lowerUTF8(JSONExtractString(raw_message, '__deleted')) = 'true', 1, 0) AS is_deleted
FROM ${CLICKHOUSE_DB}.inventory_movements_queue
WHERE JSONExtractUInt(raw_message, 'inventory_movement_id') > 0;

CREATE VIEW IF NOT EXISTS ${CLICKHOUSE_DB}.inventory_movements_current AS
SELECT
  inventory_movement_id,
  product_id,
  warehouse_id,
  movement_type,
  quantity,
  moved_at,
  employee_id,
  cdc_op,
  cdc_source_ts_ms,
  version
FROM ${CLICKHOUSE_DB}.inventory_movements_cdc FINAL
WHERE is_deleted = 0;

CREATE USER IF NOT EXISTS ${CLICKHOUSE_METABASE_USER}
IDENTIFIED WITH plaintext_password BY '${CLICKHOUSE_METABASE_PASSWORD}';

GRANT SELECT ON ${CLICKHOUSE_DB}.* TO ${CLICKHOUSE_ADMIN_USER};
GRANT SELECT ON ${CLICKHOUSE_DB}.* TO ${CLICKHOUSE_METABASE_USER};
SQL
