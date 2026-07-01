#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$DEFAULT_PROJECT_ROOT}"

if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL='*'
fi

RUN_OUTPUT=""
RUN_EXIT_CODE=0
SQL_LAST_OUTPUT=""
SQL_LAST_EXIT_CODE=0
SQL_LAST_CLIENT_SERVICE=""
CLUSTER_PRIMARY_COUNT=0
CLUSTER_REPLICA_COUNT=0
CLUSTER_STATE_TEXT=""
declare -ag CLUSTER_PRIMARY_NODES=()
declare -ag CLUSTER_REPLICA_NODES=()
declare -Ag CLUSTER_NODE_ROLE=()
declare -Ag CLUSTER_NODE_RUNNING=()
declare -Ag CLUSTER_NODE_HEALTH=()
declare -Ag CLUSTER_NODE_PRIMARY_STATUS=()
declare -Ag CLUSTER_NODE_REPLICA_STATUS=()

set_project_root() {
  PROJECT_ROOT="$(cd "${1:-$DEFAULT_PROJECT_ROOT}" && pwd)"
}

run_compose_capture() {
  local allow_failure=0
  if [[ "${1:-}" == "--allow-failure" ]]; then
    allow_failure=1
    shift
  fi

  local output=""
  local exit_code=0

  pushd "$PROJECT_ROOT" >/dev/null
  set +e
  output="$(docker compose "$@" 2>&1)"
  exit_code=$?
  set -e
  popd >/dev/null

  RUN_OUTPUT="$output"
  RUN_EXIT_CODE=$exit_code

  if (( exit_code != 0 && allow_failure == 0 )); then
    echo "docker compose $* failed with exit code $exit_code." >&2
    [[ -n "$output" ]] && echo "$output" >&2
    return "$exit_code"
  fi

  return 0
}

assert_docker_compose_available() {
  run_compose_capture --allow-failure ps
  if (( RUN_EXIT_CODE != 0 )); then
    echo "Docker Compose is not available. Start Docker Desktop or the Docker daemon first." >&2
    [[ -n "$RUN_OUTPUT" ]] && echo "$RUN_OUTPUT" >&2
    return 1
  fi
}

new_chaos_artifacts_directory() {
  local scenario_name="$1"
  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local path="$PROJECT_ROOT/chaos/artifacts/${scenario_name}-${timestamp}"
  mkdir -p "$path"
  printf '%s\n' "$path"
}

write_artifact() {
  local path="$1"
  local content="${2-}"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
}

add_artifact_section() {
  local path="$1"
  local title="$2"
  local content="${3-}"
  mkdir -p "$(dirname "$path")"
  {
    printf '===== %s =====\n' "$title"
    printf '%s\n' "$content"
    printf '\n'
  } >>"$path"
}

sql_escape_literal() {
  local value="$1"
  printf '%s' "${value//\'/\'\'}"
}

json_escape() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

bool_json() {
  if [[ "${1:-false}" == "true" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

get_running_compose_services() {
  run_compose_capture --allow-failure ps --status running --services
  if (( RUN_EXIT_CODE != 0 )) || [[ -z "$RUN_OUTPUT" ]]; then
    return 0
  fi

  printf '%s\n' "$RUN_OUTPUT" | sed '/^[[:space:]]*$/d'
}

test_compose_service_running() {
  local service_name="$1"
  get_running_compose_services | grep -Fxq "$service_name"
}

get_available_patroni_node() {
  local node
  for node in patroni1 patroni2; do
    if test_compose_service_running "$node"; then
      printf '%s\n' "$node"
      return 0
    fi
  done

  echo "No running Patroni node is available." >&2
  return 1
}

invoke_patroni_http_status() {
  local node="$1"
  local path="$2"

  if ! test_compose_service_running "$node"; then
    return 1
  fi

  run_compose_capture --allow-failure exec -T "$node" sh -lc "curl -s -o /dev/null -w '%{http_code}' http://localhost:8008${path}"
  if (( RUN_EXIT_CODE != 0 )); then
    return 1
  fi

  local status
  status="$(printf '%s' "$RUN_OUTPUT" | tr -d '\r\n ')"
  [[ "$status" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$status"
}

refresh_cluster_state() {
  local node health_status primary_status replica_status role line

  CLUSTER_PRIMARY_COUNT=0
  CLUSTER_REPLICA_COUNT=0
  CLUSTER_STATE_TEXT=""
  CLUSTER_PRIMARY_NODES=()
  CLUSTER_REPLICA_NODES=()
  CLUSTER_NODE_ROLE=()
  CLUSTER_NODE_RUNNING=()
  CLUSTER_NODE_HEALTH=()
  CLUSTER_NODE_PRIMARY_STATUS=()
  CLUSTER_NODE_REPLICA_STATUS=()

  for node in patroni1 patroni2; do
    health_status=""
    primary_status=""
    replica_status=""
    role="down"

    if test_compose_service_running "$node"; then
      CLUSTER_NODE_RUNNING["$node"]="true"
      health_status="$(invoke_patroni_http_status "$node" "/health" || true)"
      primary_status="$(invoke_patroni_http_status "$node" "/primary" || true)"
      replica_status="$(invoke_patroni_http_status "$node" "/replica" || true)"

      if [[ "$primary_status" == "200" ]]; then
        role="primary"
        ((CLUSTER_PRIMARY_COUNT+=1))
        CLUSTER_PRIMARY_NODES+=("$node")
      elif [[ "$replica_status" == "200" ]]; then
        role="replica"
        ((CLUSTER_REPLICA_COUNT+=1))
        CLUSTER_REPLICA_NODES+=("$node")
      elif [[ "$health_status" == "200" ]]; then
        role="running"
      else
        role="unknown"
      fi
    else
      CLUSTER_NODE_RUNNING["$node"]="false"
    fi

    CLUSTER_NODE_ROLE["$node"]="$role"
    CLUSTER_NODE_HEALTH["$node"]="$health_status"
    CLUSTER_NODE_PRIMARY_STATUS["$node"]="$primary_status"
    CLUSTER_NODE_REPLICA_STATUS["$node"]="$replica_status"

    printf -v line '%s | running=%s | role=%s | health=%s | primary=%s | replica=%s' \
      "$node" "${CLUSTER_NODE_RUNNING[$node]}" "$role" "$health_status" "$primary_status" "$replica_status"

    if [[ -z "$CLUSTER_STATE_TEXT" ]]; then
      CLUSTER_STATE_TEXT="$line"
    else
      CLUSTER_STATE_TEXT+=$'\n'"$line"
    fi
  done

  CLUSTER_STATE_TEXT="PrimaryCount=${CLUSTER_PRIMARY_COUNT}"$'\n'"ReplicaCount=${CLUSTER_REPLICA_COUNT}"$'\n'"${CLUSTER_STATE_TEXT}"
}

get_leader_node() {
  refresh_cluster_state
  if (( CLUSTER_PRIMARY_COUNT == 1 )); then
    printf '%s\n' "${CLUSTER_PRIMARY_NODES[0]}"
    return 0
  fi

  echo "Leader node was not found." >&2
  return 1
}

wait_for_leader_change() {
  local previous_leader="$1"
  local timeout_seconds="${2:-90}"
  local poll_interval_seconds="${3:-2}"
  local deadline=$((SECONDS + timeout_seconds))
  local leader=""

  while (( SECONDS < deadline )); do
    sleep "$poll_interval_seconds"
    if leader="$(get_leader_node 2>/dev/null)"; then
      if [[ "$leader" != "$previous_leader" ]]; then
        printf '%s\n' "$leader"
        return 0
      fi
    fi
  done

  return 1
}

wait_for_stable_cluster() {
  local timeout_seconds="${1:-150}"
  local expected_replica_node="${2:-}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    refresh_cluster_state
    if (( CLUSTER_PRIMARY_COUNT == 1 && CLUSTER_REPLICA_COUNT == 1 )); then
      if [[ -z "$expected_replica_node" || "${CLUSTER_NODE_ROLE[$expected_replica_node]:-}" == "replica" ]]; then
        return 0
      fi
    fi
    sleep 3
  done

  echo "Cluster did not return to stable primary/replica state within ${timeout_seconds} seconds." >&2
  return 1
}

get_sql_client_service() {
  local service
  for service in backup-scheduler patroni1 patroni2; do
    if test_compose_service_running "$service"; then
      printf '%s\n' "$service"
      return 0
    fi
  done

  echo "No running service with psql client is available." >&2
  return 1
}

run_sql_via_haproxy() {
  local allow_failure=0
  local max_attempts=8
  local delay_seconds=2

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-failure)
        allow_failure=1
        shift
        ;;
      --max-attempts)
        max_attempts="$2"
        shift 2
        ;;
      --delay)
        delay_seconds="$2"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  local sql="$1"
  local client_service
  client_service="$(get_sql_client_service)"
  local command='export PGPASSWORD="$POSTGRES_PASSWORD"; psql -h haproxy -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -P pager=off -X'
  local output=""
  local exit_code=0
  local attempt=0

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
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

    if (( attempt < max_attempts )); then
      sleep "$delay_seconds"
    fi
  done

  if (( allow_failure == 1 )); then
    return 0
  fi

  echo "Failed to execute SQL through HAProxy after ${max_attempts} attempts." >&2
  [[ -n "$output" ]] && echo "$output" >&2
  return "$exit_code"
}

new_chaos_marker_sql() {
  local scenario_literal phase_literal note_literal
  scenario_literal="$(sql_escape_literal "$1")"
  phase_literal="$(sql_escape_literal "$2")"
  note_literal="$(sql_escape_literal "$3")"

  cat <<EOF
CREATE TABLE IF NOT EXISTS public.chaos_lab_log (
  id bigserial PRIMARY KEY,
  scenario text NOT NULL,
  phase text NOT NULL,
  note text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.chaos_lab_log (scenario, phase, note)
VALUES ('$scenario_literal', '$phase_literal', '$note_literal');
SELECT id, scenario, phase, note, created_at
FROM public.chaos_lab_log
ORDER BY id DESC
LIMIT 5;
EOF
}

get_chaos_sql_check() {
  cat <<'EOF'
SELECT
  now() AS checked_at,
  current_database() AS db_name,
  current_user AS db_user,
  pg_is_in_recovery() AS in_recovery,
  inet_server_addr()::text AS server_addr,
  inet_server_port() AS server_port;

SELECT id, scenario, phase, note, created_at
FROM public.chaos_lab_log
ORDER BY id DESC
LIMIT 5;
EOF
}

run_patronictl_list() {
  local allow_failure=0
  if [[ "${1:-}" == "--allow-failure" ]]; then
    allow_failure=1
    shift
  fi

  local node
  if ! node="$(get_available_patroni_node)"; then
    RUN_OUTPUT="No running Patroni node is available."
    RUN_EXIT_CODE=1
    if (( allow_failure == 1 )); then
      return 0
    fi
    return 1
  fi

  if (( allow_failure == 1 )); then
    run_compose_capture --allow-failure exec -T "$node" patronictl -c /etc/patroni/patroni.yml list
  else
    run_compose_capture exec -T "$node" patronictl -c /etc/patroni/patroni.yml list
  fi
}

capture_patroni_list_artifact() {
  local path="$1"
  local allow_failure="${2:-false}"
  local patronictl_output=""
  local patronictl_exit_code=0

  if [[ "$allow_failure" == "true" ]]; then
    run_patronictl_list --allow-failure
  else
    run_patronictl_list
  fi
  patronictl_output="$RUN_OUTPUT"
  patronictl_exit_code="$RUN_EXIT_CODE"

  refresh_cluster_state
  write_artifact "$path" "${patronictl_output}"$'\n\n'"----- CLUSTER STATE -----"$'\n'"${CLUSTER_STATE_TEXT}"
  RUN_OUTPUT="$patronictl_output"
  RUN_EXIT_CODE="$patronictl_exit_code"
}

capture_sql_check_artifact() {
  local path="$1"
  local allow_failure="${2:-false}"

  if [[ "$allow_failure" == "true" ]]; then
    run_sql_via_haproxy --allow-failure "$(get_chaos_sql_check)"
  else
    run_sql_via_haproxy "$(get_chaos_sql_check)"
  fi

  write_artifact "$path" "$SQL_LAST_OUTPUT"
}

capture_compose_ps_section() {
  local path="$1"
  local title="$2"

  run_compose_capture --allow-failure ps
  add_artifact_section "$path" "$title" "$RUN_OUTPUT"
}

capture_service_logs_artifact() {
  local path="$1"
  local since="$2"
  shift 2
  local services=("$@")

  run_compose_capture --allow-failure logs --no-color --since "$since" "${services[@]}"
  write_artifact "$path" "$RUN_OUTPUT"
}
