#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CONFIG_TEMPLATE="${SCRIPT_DIR}/connector.config.json"

: "${DEBEZIUM_CONNECT_URL:=http://localhost:8083}"
: "${DEBEZIUM_CONNECTOR_NAME:=postgres-connector}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${DEBEZIUM_USER:?DEBEZIUM_USER is required}"
: "${DEBEZIUM_PASSWORD:?DEBEZIUM_PASSWORD is required}"
: "${DEBEZIUM_TOPIC_PREFIX:?DEBEZIUM_TOPIC_PREFIX is required}"
: "${DEBEZIUM_SLOT_NAME:?DEBEZIUM_SLOT_NAME is required}"
: "${DEBEZIUM_PUBLICATION_NAME:?DEBEZIUM_PUBLICATION_NAME is required}"

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

rendered_config="$(
  sed \
    -e "s|__POSTGRES_DB__|$(escape_sed_replacement "$POSTGRES_DB")|g" \
    -e "s|__DEBEZIUM_USER__|$(escape_sed_replacement "$DEBEZIUM_USER")|g" \
    -e "s|__DEBEZIUM_PASSWORD__|$(escape_sed_replacement "$DEBEZIUM_PASSWORD")|g" \
    -e "s|__DEBEZIUM_TOPIC_PREFIX__|$(escape_sed_replacement "$DEBEZIUM_TOPIC_PREFIX")|g" \
    -e "s|__DEBEZIUM_SLOT_NAME__|$(escape_sed_replacement "$DEBEZIUM_SLOT_NAME")|g" \
    -e "s|__DEBEZIUM_PUBLICATION_NAME__|$(escape_sed_replacement "$DEBEZIUM_PUBLICATION_NAME")|g" \
    "$CONFIG_TEMPLATE"
)"

connectors_url="${DEBEZIUM_CONNECT_URL%/}/connectors/${DEBEZIUM_CONNECTOR_NAME}/config"

echo "Registering Debezium connector ${DEBEZIUM_CONNECTOR_NAME} via ${connectors_url}"
printf '%s' "$rendered_config" | curl -fsS \
  -X PUT \
  -H "Content-Type: application/json" \
  --data-binary @- \
  "$connectors_url"

echo
echo "Connector registration request completed."
