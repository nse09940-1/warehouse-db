#!/usr/bin/env bash
set -euo pipefail

: "${POSTGRES_DB:?}"
: "${POSTGRES_USER:?}"
: "${POSTGRES_PASSWORD:?}"
PATRONI_SUPERUSER_USERNAME="${PATRONI_SUPERUSER_USERNAME:-postgres}"

psql \
  --username "${PATRONI_SUPERUSER_USERNAME}" \
  --dbname postgres \
  -v ON_ERROR_STOP=1 \
  -v app_db="${POSTGRES_DB}" \
  -v app_user="${POSTGRES_USER}" \
  -v app_password="${POSTGRES_PASSWORD}" <<'SQL'
SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L SUPERUSER CREATEDB CREATEROLE', :'app_user', :'app_password')
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_roles
  WHERE rolname = :'app_user'
)\gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L SUPERUSER CREATEDB CREATEROLE', :'app_user', :'app_password')
WHERE EXISTS (
  SELECT 1
  FROM pg_roles
  WHERE rolname = :'app_user'
)\gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'app_db', :'app_user')
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_database
  WHERE datname = :'app_db'
)\gexec
SQL
