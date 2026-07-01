#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
default_test_movement_id="$((900000000 + (($(date +%s) + RANDOM) % 99999999)))"
TEST_MOVEMENT_ID="${TEST_MOVEMENT_ID:-$default_test_movement_id}"
TOPIC_NAME="${TOPIC_NAME:-${DEBEZIUM_TOPIC_PREFIX:-warehouse_cdc}.public.inventory_movements}"
CLICKHOUSE_DB_NAME="${CLICKHOUSE_DB:-bi_analytics}"
METABASE_WAIT_SECONDS="${METABASE_WAIT_SECONDS:-20}"
PAUSE_AT_END="${PAUSE_AT_END:-auto}"

# shellcheck source=scripts/chaos-common.sh
source "${SCRIPT_DIR}/chaos-common.sh"
set_project_root "$PROJECT_ROOT"

log_step() {
  printf '[bi-cdc-smoke] %s\n' "$1"
}

pause_before_exit() {
  case "${PAUSE_AT_END,,}" in
    false|0|no|off)
      return 0
      ;;
    true|1|yes|on|auto)
      if [[ -t 0 && -t 1 ]]; then
        printf '\n[bi-cdc-smoke] Press Enter to close...\n'
        read -r _
      fi
      ;;
  esac
}

assert_non_empty() {
  local label="$1"
  local value="$2"
  if [[ -z "${value//[$'\r\n\t ']}" ]]; then
    printf '[bi-cdc-smoke] %s\n' "$label returned no data" >&2
    exit 1
  fi
}

extract_json_string() {
  local key="$1"
  local line="$2"
  printf '%s\n' "$line" | sed -n "s/.*\"${key}\":\"\([^\"]*\)\".*/\1/p"
}

extract_json_number() {
  local key="$1"
  local line="$2"
  printf '%s\n' "$line" | sed -n "s/.*\"${key}\":\([0-9][0-9.]*\).*/\1/p"
}

run_clickhouse_query() {
  local query="$1"
  pushd "$PROJECT_ROOT" >/dev/null
  docker compose exec -T clickhouse clickhouse-client \
    --user "${CLICKHOUSE_ADMIN_USER:-clickhouse_admin}" \
    --password "${CLICKHOUSE_ADMIN_PASSWORD:-clickhouse_admin_password}" \
    --query "$query"
  popd >/dev/null
}

run_sql_via_haproxy_compact() {
  local sql="$1"
  local client_service
  client_service="$(get_sql_client_service)"

  local command='export PGPASSWORD="$POSTGRES_PASSWORD"; psql -h haproxy -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -P pager=off -X -t -A -F " | "'
  local output=""
  local exit_code=0
  local attempt=0

  for ((attempt = 1; attempt <= 8; attempt++)); do
    pushd "$PROJECT_ROOT" >/dev/null
    set +e
    output="$(printf '%s\n' "$sql" | docker compose exec -T "$client_service" bash -lc "$command" 2>&1)"
    exit_code=$?
    set -e
    popd >/dev/null

    SQL_LAST_OUTPUT="$output"
    SQL_LAST_EXIT_CODE=$exit_code
    SQL_LAST_CLIENT_SERVICE="$client_service"

    if (( exit_code == 0 )); then
      return 0
    fi

    if (( attempt < 8 )); then
      sleep 2
    fi
  done

  echo "Failed to execute SQL through HAProxy." >&2
  [[ -n "$output" ]] && echo "$output" >&2
  return "$exit_code"
}

run_kafka_grep() {
  local pattern="$1"
  pushd "$PROJECT_ROOT" >/dev/null
  docker compose exec -T kafka bash -lc \
    "/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka:9092 --topic '${TOPIC_NAME}' --from-beginning --timeout-ms 6000 2>/dev/null | grep '${pattern}' | tail -n 5"
  popd >/dev/null
}

print_psql_row_summary() {
  local label="$1"
  local row
  row="$(printf '%s\n' "$2" | awk -F'\\|' '
    /^[[:space:]]*[0-9]+[[:space:]]*\|/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3)
      printf "%s | %s | %s\n", $1, $2, $3
      exit
    }
  ')"
  assert_non_empty "$label" "$row"
  log_step "$label: $row"
}

print_kafka_event_summary() {
  local label="$1"
  local output="$2"
  local event_line
  event_line="$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -n 1)"
  assert_non_empty "$label" "$event_line"

  local movement_id movement_type quantity op deleted
  movement_id="$(extract_json_number "inventory_movement_id" "$event_line")"
  movement_type="$(extract_json_string "movement_type" "$event_line")"
  quantity="$(extract_json_string "quantity" "$event_line")"
  op="$(extract_json_string "__op" "$event_line")"
  deleted="$(extract_json_string "__deleted" "$event_line")"

  log_step "$label: op=${op:-?} deleted=${deleted:-?} id=${movement_id:-?} type=${movement_type:-?} qty=${quantity:-?}"
}

print_clickhouse_row_summary() {
  local label="$1"
  local output="$2"
  local compact
  compact="$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -n 1)"
  assert_non_empty "$label" "$compact"
  log_step "$label: $compact"
}

assert_docker_compose_available

log_step "Insert test movement into PostgreSQL through HAProxy"
run_sql_via_haproxy_compact "
WITH refs AS (
  SELECT
    (SELECT min(product_id) FROM products) AS product_id,
    (SELECT min(warehouse_id) FROM warehouses) AS warehouse_id,
    (SELECT min(employee_id) FROM employees) AS employee_id
)
INSERT INTO inventory_movements (
  inventory_movement_id,
  product_id,
  warehouse_id,
  movement_type,
  quantity,
  moved_at,
  employee_id
)
SELECT
  ${TEST_MOVEMENT_ID},
  refs.product_id,
  refs.warehouse_id,
  'adjustment'::inventory_movement_type,
  11.111,
  now(),
  refs.employee_id
FROM refs;

SELECT inventory_movement_id, movement_type, quantity
FROM inventory_movements
WHERE inventory_movement_id = ${TEST_MOVEMENT_ID};
"
print_psql_row_summary "PostgreSQL row after INSERT" "$SQL_LAST_OUTPUT"

log_step "Check topic existence in Kafka"
pushd "$PROJECT_ROOT" >/dev/null
topic_description="$(
  docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server kafka:9092 \
    --describe \
    --topic "${TOPIC_NAME}" \
    | head -n 1
)"
popd >/dev/null
topic_partitions="$(printf '%s\n' "$topic_description" | sed -n 's/.*PartitionCount: \([0-9][0-9]*\).*/\1/p')"
topic_replication="$(printf '%s\n' "$topic_description" | sed -n 's/.*ReplicationFactor: \([0-9][0-9]*\).*/\1/p')"
log_step "Kafka topic ready: ${TOPIC_NAME} (partitions=${topic_partitions:-?}, replication=${topic_replication:-?})"

log_step "Look for the inserted row in Kafka CDC topic"
insert_kafka_output="$(run_kafka_grep "${TEST_MOVEMENT_ID}")"
assert_non_empty "Kafka lookup after INSERT" "$insert_kafka_output"
print_kafka_event_summary "Kafka event after INSERT" "$insert_kafka_output"

log_step "Check current row in ClickHouse"
insert_clickhouse_output="$(run_clickhouse_query "SELECT concat('id=', toString(inventory_movement_id), ', type=', movement_type, ', qty=', toString(quantity)) FROM ${CLICKHOUSE_DB_NAME}.inventory_movements_current WHERE inventory_movement_id = ${TEST_MOVEMENT_ID} FORMAT TabSeparatedRaw")"
assert_non_empty "ClickHouse lookup after INSERT" "$insert_clickhouse_output"
print_clickhouse_row_summary "ClickHouse row after INSERT" "$insert_clickhouse_output"

log_step "Update the test movement"
run_sql_via_haproxy_compact "
UPDATE inventory_movements
SET movement_type = 'write_off'::inventory_movement_type,
    quantity = 22.222,
    moved_at = now()
WHERE inventory_movement_id = ${TEST_MOVEMENT_ID};

SELECT inventory_movement_id, movement_type, quantity
FROM inventory_movements
WHERE inventory_movement_id = ${TEST_MOVEMENT_ID};
"
print_psql_row_summary "PostgreSQL row after UPDATE" "$SQL_LAST_OUTPUT"

log_step "Look for the updated row in Kafka CDC topic"
update_kafka_output="$(run_kafka_grep "${TEST_MOVEMENT_ID}")"
assert_non_empty "Kafka lookup after UPDATE" "$update_kafka_output"
print_kafka_event_summary "Kafka event after UPDATE" "$update_kafka_output"

log_step "Check updated row in ClickHouse"
update_clickhouse_output="$(run_clickhouse_query "SELECT concat('id=', toString(inventory_movement_id), ', type=', movement_type, ', qty=', toString(quantity)) FROM ${CLICKHOUSE_DB_NAME}.inventory_movements_current WHERE inventory_movement_id = ${TEST_MOVEMENT_ID} FORMAT TabSeparatedRaw")"
assert_non_empty "ClickHouse lookup after UPDATE" "$update_clickhouse_output"
print_clickhouse_row_summary "ClickHouse row after UPDATE" "$update_clickhouse_output"

if [[ -t 0 && -t 1 ]]; then
  printf '[bi-cdc-smoke] Open Metabase dashboard and verify the charts, then press Enter to continue with DELETE... '
  read -r _
else
  log_step "Waiting ${METABASE_WAIT_SECONDS} seconds before DELETE so the dashboard can be refreshed"
  sleep "${METABASE_WAIT_SECONDS}"
fi

log_step "Delete the test movement"
run_sql_via_haproxy_compact "
DELETE FROM inventory_movements
WHERE inventory_movement_id = ${TEST_MOVEMENT_ID};

SELECT count(*) AS pg_row_count
FROM inventory_movements
WHERE inventory_movement_id = ${TEST_MOVEMENT_ID};
"
log_step "PostgreSQL row count after DELETE: $(printf '%s\n' "$SQL_LAST_OUTPUT" | awk '/^[[:space:]]*[0-9]+[[:space:]]*$/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1; exit }')"

log_step "Look for the delete event in Kafka CDC topic"
delete_kafka_output="$(run_kafka_grep "${TEST_MOVEMENT_ID}")"
assert_non_empty "Kafka lookup after DELETE" "$delete_kafka_output"
print_kafka_event_summary "Kafka event after DELETE" "$delete_kafka_output"

log_step "Confirm that the row disappeared from the ClickHouse analytics view"
delete_clickhouse_output="$(run_clickhouse_query "SELECT count() FROM ${CLICKHOUSE_DB_NAME}.inventory_movements_current WHERE inventory_movement_id = ${TEST_MOVEMENT_ID} FORMAT TabSeparatedRaw")"
assert_non_empty "ClickHouse row count after DELETE" "$delete_clickhouse_output"
log_step "ClickHouse row count after DELETE: ${delete_clickhouse_output}"

log_step "Smoke scenario completed"
pause_before_exit
