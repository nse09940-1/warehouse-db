#!/usr/bin/env bash
set -euo pipefail

required_vars=(
  PATRONI_NAME
  PATRONI_SCOPE
  PATRONI_ETCD_HOSTS
  PATRONI_RESTAPI_CONNECT_ADDRESS
  PATRONI_POSTGRESQL_CONNECT_ADDRESS
  PATRONI_DATA_DIR
  PATRONI_SUPERUSER_USERNAME
  PATRONI_SUPERUSER_PASSWORD
  PATRONI_REPLICATION_USERNAME
  PATRONI_REPLICATION_PASSWORD
  PATRONI_REWIND_USERNAME
  PATRONI_REWIND_PASSWORD
  PATRONI_DEBEZIUM_USERNAME
  POSTGRES_DB
  POSTGRES_USER
  POSTGRES_PASSWORD
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Environment variable is required: ${var_name}" >&2
    exit 1
  fi
done

mkdir -p "${PATRONI_DATA_DIR}" /etc/patroni /var/run/postgresql
chmod 700 "${PATRONI_DATA_DIR}"
chown -R postgres:postgres "${PATRONI_DATA_DIR}" /etc/patroni /var/run/postgresql /opt/patroni

envsubst < /etc/patroni/patroni.yml.tmpl > /etc/patroni/patroni.yml
chown postgres:postgres /etc/patroni/patroni.yml

exec gosu postgres patroni /etc/patroni/patroni.yml
