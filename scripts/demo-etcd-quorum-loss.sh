#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_INPUT="${1:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
PHASE_TIMEOUT_SECONDS="${PHASE_TIMEOUT_SECONDS:-90}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-180}"
LOG_SINCE="${LOG_SINCE:-20m}"
PAUSE_AT_END="${PAUSE_AT_END:-auto}"

# shellcheck source=scripts/chaos-common.sh
source "${SCRIPT_DIR}/chaos-common.sh"
set_project_root "$PROJECT_ROOT_INPUT"

artifact_directory="$(new_chaos_artifacts_directory "scenario2")"
compose_ps_path="${artifact_directory}/compose-ps.txt"
started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
finished_at_utc=""
initial_leader=""
phase_a_writable="false"
phase_a_patronictl_available="false"
phase_b_new_leader="none"
phase_b_haproxy_writable="false"
restored_cluster="false"
success="false"
error_message=""
leader_stopped="false"
stopped_etcd_nodes=()

log_step() {
  printf '[demo-etcd-quorum-loss] %s\n' "$1"
}

write_summary_files() {
  local json_path="${artifact_directory}/summary.json"
  local txt_path="${artifact_directory}/summary.txt"

  cat >"$json_path" <<EOF
{
  "scenario": "scenario2",
  "description": "Loss of etcd quorum and Patroni behavior without DCS",
  "artifact_directory": "$(json_escape "$artifact_directory")",
  "started_at_utc": "$(json_escape "$started_at_utc")",
  "finished_at_utc": "$(json_escape "$finished_at_utc")",
  "initial_leader": "$(json_escape "$initial_leader")",
  "etcd_nodes_stopped": [
    "etcd2",
    "etcd3"
  ],
  "phase_a_writable": $(bool_json "$phase_a_writable"),
  "phase_a_patronictl_available": $(bool_json "$phase_a_patronictl_available"),
  "phase_b_new_leader": "$(json_escape "$phase_b_new_leader")",
  "phase_b_haproxy_writable": $(bool_json "$phase_b_haproxy_writable"),
  "restored_cluster": $(bool_json "$restored_cluster"),
  "success": $(bool_json "$success"),
  "error": "$(json_escape "$error_message")"
}
EOF

  cat >"$txt_path" <<EOF
scenario: scenario2
description: Loss of etcd quorum and Patroni behavior without DCS
artifact_directory: $artifact_directory
started_at_utc: $started_at_utc
finished_at_utc: $finished_at_utc
initial_leader: $initial_leader
etcd_nodes_stopped: etcd2, etcd3
phase_a_writable: $phase_a_writable
phase_a_patronictl_available: $phase_a_patronictl_available
phase_b_new_leader: $phase_b_new_leader
phase_b_haproxy_writable: $phase_b_haproxy_writable
restored_cluster: $restored_cluster
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

  if (( ${#stopped_etcd_nodes[@]} > 0 )); then
    run_compose_capture --allow-failure start "${stopped_etcd_nodes[@]}" || true
    stopped_etcd_nodes=()
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

log_step "Check baseline write through HAProxy"
run_sql_via_haproxy "$(new_chaos_marker_sql "scenario2" "baseline" "baseline write before etcd quorum loss")"
write_artifact "${artifact_directory}/sql-write-before.txt" "$SQL_LAST_OUTPUT"
capture_sql_check_artifact "${artifact_directory}/sql-check-before.txt" "true"

log_step "Stop etcd2 and etcd3 to remove quorum"
run_compose_capture stop etcd2 etcd3
stopped_etcd_nodes=(etcd2 etcd3)
sleep 8

log_step "Capture state while quorum is lost"
capture_compose_ps_section "$compose_ps_path" "PHASE A - QUORUM LOST"
capture_patroni_list_artifact "${artifact_directory}/patroni-list-during.txt" "true"
if (( RUN_EXIT_CODE == 0 )); then
  phase_a_patronictl_available="true"
fi

log_step "Check write attempt while quorum is unavailable"
run_sql_via_haproxy --allow-failure "$(new_chaos_marker_sql "scenario2" "quorum-lost-primary-alive" "write attempt while etcd quorum is unavailable")"
phase_a_writable=$([[ $SQL_LAST_EXIT_CODE -eq 0 ]] && printf 'true' || printf 'false')
write_artifact "${artifact_directory}/sql-write-phase-a.txt" "$SQL_LAST_OUTPUT"
capture_sql_check_artifact "${artifact_directory}/sql-check-during.txt" "true"

log_step "Stop current primary: ${initial_leader}"
run_compose_capture stop "$initial_leader"
leader_stopped="true"
sleep 5

log_step "Wait for leader election without DCS"
if phase_b_candidate="$(wait_for_leader_change "$initial_leader" "$PHASE_TIMEOUT_SECONDS")"; then
  phase_b_new_leader="$phase_b_candidate"
else
  phase_b_new_leader="none"
fi
log_step "Phase B leader: ${phase_b_new_leader}"

log_step "Check write attempt after primary stop while quorum is still unavailable"
run_sql_via_haproxy --allow-failure "$(new_chaos_marker_sql "scenario2" "quorum-lost-primary-stopped" "write attempt after primary stop while etcd quorum is unavailable")"
phase_b_haproxy_writable=$([[ $SQL_LAST_EXIT_CODE -eq 0 ]] && printf 'true' || printf 'false')
write_artifact "${artifact_directory}/sql-write-phase-b.txt" "$SQL_LAST_OUTPUT"

log_step "Restore etcd2 and etcd3"
run_compose_capture start etcd2 etcd3
stopped_etcd_nodes=()
sleep 10

if [[ "$leader_stopped" == "true" && -n "$initial_leader" ]]; then
  log_step "Restore stopped PostgreSQL node: ${initial_leader}"
  run_compose_capture start "$initial_leader"
  leader_stopped="false"
fi

log_step "Wait for cluster recovery"
wait_for_stable_cluster "$RECOVERY_TIMEOUT_SECONDS"
refresh_cluster_state
if (( CLUSTER_PRIMARY_COUNT == 1 && CLUSTER_REPLICA_COUNT == 1 )); then
  restored_cluster="true"
fi

capture_compose_ps_section "$compose_ps_path" "AFTER RECOVERY"
capture_patroni_list_artifact "${artifact_directory}/patroni-list-after.txt" "true"
capture_sql_check_artifact "${artifact_directory}/sql-check-after.txt" "true"

if [[ "$restored_cluster" != "true" ]]; then
  error_message="Cluster did not return to stable primary/replica state after etcd recovery."
  exit 1
fi

success="true"

log_step "Scenario completed successfully"
if [[ "${PAUSE_AT_END,,}" != "false" && -t 0 && -t 1 ]]; then
  printf '[demo-etcd-quorum-loss] Press Enter to close the window... '
  read -r _
fi
