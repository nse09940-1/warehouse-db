#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_INPUT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
FAILOVER_TIMEOUT_SECONDS="${FAILOVER_TIMEOUT_SECONDS:-90}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-150}"
LOG_SINCE="${LOG_SINCE:-15m}"
PAUSE_AT_END="${PAUSE_AT_END:-auto}"

# shellcheck source=scripts/chaos-common.sh
source "${SCRIPT_DIR}/chaos-common.sh"
set_project_root "$PROJECT_ROOT_INPUT"

artifact_directory="$(new_chaos_artifacts_directory "scenario1")"
compose_ps_path="${artifact_directory}/compose-ps.txt"
started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
finished_at_utc=""
initial_leader=""
new_leader=""
writable_before_failover="false"
writable_after_failover="false"
restored_replica="false"
success="false"
error_message=""
leader_stopped="false"

log_step() {
  printf '[demo-failover] %s\n' "$1"
}

write_summary_files() {
  local json_path="${artifact_directory}/summary.json"
  local txt_path="${artifact_directory}/summary.txt"

  cat >"$json_path" <<EOF
{
  "scenario": "scenario1",
  "description": "Primary PostgreSQL failover via Patroni and HAProxy",
  "artifact_directory": "$(json_escape "$artifact_directory")",
  "started_at_utc": "$(json_escape "$started_at_utc")",
  "finished_at_utc": "$(json_escape "$finished_at_utc")",
  "initial_leader": "$(json_escape "$initial_leader")",
  "new_leader": "$(json_escape "$new_leader")",
  "writable_before_failover": $(bool_json "$writable_before_failover"),
  "writable_after_failover": $(bool_json "$writable_after_failover"),
  "restored_replica": $(bool_json "$restored_replica"),
  "success": $(bool_json "$success"),
  "error": "$(json_escape "$error_message")"
}
EOF

  cat >"$txt_path" <<EOF
scenario: scenario1
description: Primary PostgreSQL failover via Patroni and HAProxy
artifact_directory: $artifact_directory
started_at_utc: $started_at_utc
finished_at_utc: $finished_at_utc
initial_leader: $initial_leader
new_leader: $new_leader
writable_before_failover: $writable_before_failover
writable_after_failover: $writable_after_failover
restored_replica: $restored_replica
success: $success
error: $error_message
EOF
}

on_error() {
  local exit_code=$?
  if [[ -z "$error_message" ]]; then
    error_message="Command failed with exit code ${exit_code}."
  fi
  success="false"
}

cleanup() {
  if [[ "$leader_stopped" == "true" && -n "$initial_leader" ]]; then
    run_compose_capture --allow-failure start "$initial_leader" || true
    leader_stopped="false"
  fi

  capture_compose_ps_section "$compose_ps_path" "FINAL" || true
  capture_service_logs_artifact "${artifact_directory}/patroni-logs.txt" "$LOG_SINCE" patroni1 patroni2 || true
  capture_service_logs_artifact "${artifact_directory}/etcd-logs.txt" "$LOG_SINCE" etcd1 etcd2 etcd3 || true
  capture_service_logs_artifact "${artifact_directory}/haproxy-logs.txt" "$LOG_SINCE" haproxy || true

  finished_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_summary_files
}

trap on_error ERR
trap cleanup EXIT

assert_docker_compose_available


initial_leader="$(get_leader_node)"
capture_compose_ps_section "$compose_ps_path" "BEFORE"
capture_patroni_list_artifact "${artifact_directory}/patroni-list-before.txt" "true"

log_step "Check write through HAProxy before failover"
run_sql_via_haproxy "$(new_chaos_marker_sql "scenario1" "before-failover" "write through haproxy before primary stop")"
writable_before_failover=$([[ $SQL_LAST_EXIT_CODE -eq 0 ]] && printf 'true' || printf 'false')
write_artifact "${artifact_directory}/sql-write-before.txt" "$SQL_LAST_OUTPUT"
capture_sql_check_artifact "${artifact_directory}/sql-check-before.txt" "true"

log_step "Stop current primary: ${initial_leader}"
run_compose_capture stop "$initial_leader"
leader_stopped="true"

log_step "Wait for leader switch"
new_leader="$(wait_for_leader_change "$initial_leader" "$FAILOVER_TIMEOUT_SECONDS")"
log_step "New leader: ${new_leader}"
capture_compose_ps_section "$compose_ps_path" "DURING"
capture_patroni_list_artifact "${artifact_directory}/patroni-list-during.txt" "true"

log_step "Check write through HAProxy after failover"
run_sql_via_haproxy \
  --max-attempts 20 \
  --delay 3 \
  "$(new_chaos_marker_sql "scenario1" "after-failover" "write through haproxy after leader switch")"
writable_after_failover=$([[ $SQL_LAST_EXIT_CODE -eq 0 ]] && printf 'true' || printf 'false')
write_artifact "${artifact_directory}/sql-write-after.txt" "$SQL_LAST_OUTPUT"
capture_sql_check_artifact "${artifact_directory}/sql-check-during.txt" "true"

log_step "Start stopped node: ${initial_leader}"
run_compose_capture start "$initial_leader"
leader_stopped="false"

log_step "Wait for stable cluster state"
wait_for_stable_cluster "$RECOVERY_TIMEOUT_SECONDS" "$initial_leader"
refresh_cluster_state
if [[ "${CLUSTER_NODE_ROLE[$initial_leader]:-}" == "replica" ]]; then
  restored_replica="true"
fi

capture_compose_ps_section "$compose_ps_path" "AFTER"
capture_patroni_list_artifact "${artifact_directory}/patroni-list-after.txt" "true"
capture_sql_check_artifact "${artifact_directory}/sql-check-after.txt" "true"

if [[ "$writable_before_failover" != "true" ]]; then
  error_message="Write through HAProxy failed before failover."
  exit 1
fi
if [[ "$writable_after_failover" != "true" ]]; then
  error_message="Write through HAProxy failed after failover."
  exit 1
fi
if [[ "$restored_replica" != "true" ]]; then
  error_message="The former leader did not rejoin as replica."
  exit 1
fi

success="true"

log_step "Scenario completed successfully"
if [[ "${PAUSE_AT_END,,}" != "false" && -t 0 && -t 1 ]]; then
  printf '[demo-failover] Press Enter to close the window... '
  read -r _
fi
