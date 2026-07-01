#!/bin/sh
set -eu

: "${DEBEZIUM_CONNECT_URL:=http://debezium-connect:8083}"
: "${DEBEZIUM_CONNECTOR_NAME:=postgres-connector}"
: "${DEBEZIUM_POLL_INTERVAL_SECONDS:=10}"

status_url="${DEBEZIUM_CONNECT_URL%/}/connectors/${DEBEZIUM_CONNECTOR_NAME}/status"
restart_url="${DEBEZIUM_CONNECT_URL%/}/connectors/${DEBEZIUM_CONNECTOR_NAME}/restart?includeTasks=true&onlyFailed=true"
register_script="/workspace/cdc/debezium/register.sh"

log() {
  printf '[debezium-watchdog] %s\n' "$1"
}

restart_failed_connector() {
  log "Connector task is FAILED, requesting restart"
  curl -fsS -X POST "$restart_url" >/dev/null || true
}

register_connector_if_missing() {
  if [ -x "$register_script" ]; then
    log "Connector is missing, registering it again"
    /bin/sh "$register_script" >/dev/null
  fi
}

while true; do
  status_json="$(curl -fsS "$status_url" 2>/dev/null || true)"

  if [ -z "$status_json" ]; then
    register_connector_if_missing
    sleep "$DEBEZIUM_POLL_INTERVAL_SECONDS"
    continue
  fi

  case "$status_json" in
    *'"error_code":404'*|*'Connector '*)
      register_connector_if_missing
      ;;
    *'"state":"FAILED"'*)
      restart_failed_connector
      ;;
  esac

  sleep "$DEBEZIUM_POLL_INTERVAL_SECONDS"
done
