#!/usr/bin/env bats
#
# ---------------------------------------------------------------------
# Path:         test/server_connectivity_validator.bats
# Filename:     server_connectivity_validator.bats
# Project:      server_connectivity_validator
# Description:  Behavioural tests for the consecutive-failure state
#               machine, alert dispatch, and delivery-gated flagging.
# Status:       production
# Revision:     1
# Updated:      2026-08-05
# Requires:     bats, bash 4.2 or newer
# Included by:  .github/workflows/ci.yml
# Provides:     test coverage for server_connectivity_validator.sh
# ---------------------------------------------------------------------
#
# Run with:  bats test/
#
# The network-facing checks need real infrastructure and are not covered
# here. The state machine is, and the state machine is where the tool's
# actual behaviour lives.
#

setup() {
  export VALIDATOR_LIB_ONLY=1
  WORK="$(mktemp -d)"
  export WORK
  export VALIDATOR_STATE_DIR="${WORK}/state"
  export VALIDATOR_LOG_FILE="${WORK}/validator.log"
  export VALIDATOR_FAILURE_THRESHOLD=3
  mkdir -p "${VALIDATOR_STATE_DIR}"

  source "${BATS_TEST_DIRNAME}/../server_connectivity_validator.sh"
  state_directory="${WORK}/state"
  log_file="${WORK}/validator.log"
  failure_threshold=3

  pending_alert_checks=(); pending_alert_lines=()
  pending_recovery_checks=(); pending_recovery_lines=()
  any_check_failed="false"

  # Delivery is driven through a real command on PATH rather than by
  # stubbing send_notification_email, so every test exercises the actual
  # send path including its failure branch.
  mkdir -p "${WORK}/bin"
  printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 0\n' > "${WORK}/bin/mail_ok"
  printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 1\n' > "${WORK}/bin/mail_broken"
  chmod +x "${WORK}/bin"/*
  mail_command="${WORK}/bin/mail_ok"
}

teardown() { rm -rf "${WORK}"; }

fail_n_times() {
  local name="${1}" count="${2}" i
  for ((i = 0; i < count; i++)); do
    record_check_result "${name}" 1 "target unreachable"
  done
}

# ---------------------------------------------------------------------
# Counter handling
# ---------------------------------------------------------------------

@test "a missing state file reads as a zero count" {
  run read_failure_count "${state_directory}/absent.failure_count"
  [ "${output}" = "0" ]
}

@test "a valid state file reads its count" {
  printf '4\n' > "${state_directory}/probe.failure_count"
  run read_failure_count "${state_directory}/probe.failure_count"
  [ "${output}" = "4" ]
}

@test "REGRESSION a corrupt state file reads as zero and is logged, not evaluated silently" {
  printf 'garbage\n' > "${state_directory}/probe.failure_count"
  run read_failure_count "${state_directory}/probe.failure_count"
  [ "${output}" = "0" ]
  grep -q "corrupt" "${log_file}"
}

@test "a failing check increments the consecutive counter" {
  fail_n_times icmp_ping 2
  [ "$(cat "${state_directory}/icmp_ping.failure_count")" = "2" ]
}

@test "a passing check resets the counter to zero" {
  fail_n_times icmp_ping 2
  record_check_result icmp_ping 0 "reply received"
  [ "$(cat "${state_directory}/icmp_ping.failure_count")" = "0" ]
}

# ---------------------------------------------------------------------
# Flap suppression and alert-once behaviour
# ---------------------------------------------------------------------

@test "failures below the threshold queue no alert" {
  fail_n_times nfs_export 2
  [ "${#pending_alert_lines[@]}" -eq 0 ]
}

@test "a blip that recovers before the threshold alerts nobody" {
  fail_n_times nfs_export 2
  record_check_result nfs_export 0 "export advertised"
  [ "${#pending_alert_lines[@]}" -eq 0 ]
  [ "${#pending_recovery_lines[@]}" -eq 0 ]
}

@test "reaching the threshold queues exactly one alert" {
  fail_n_times smb_share 3
  [ "${#pending_alert_lines[@]}" -eq 1 ]
}

@test "a sustained outage alerts once, not once per run" {
  fail_n_times smb_share 3
  dispatch_pending_alerts
  pending_alert_checks=(); pending_alert_lines=()
  fail_n_times smb_share 10
  [ "${#pending_alert_lines[@]}" -eq 0 ]
}

@test "recovery after an alerted outage queues a recovery notice" {
  fail_n_times http_endpoint 3
  dispatch_pending_alerts
  record_check_result http_endpoint 0 "HTTP 200"
  [ "${#pending_recovery_lines[@]}" -eq 1 ]
}

@test "the recovery notice names how many runs failed" {
  fail_n_times http_endpoint 5
  dispatch_pending_alerts
  record_check_result http_endpoint 0 "HTTP 200"
  [[ "${pending_recovery_lines[0]}" == *"5 consecutive failed runs"* ]]
}

@test "a second incident after recovery alerts again" {
  fail_n_times tcp_port_25 3
  dispatch_pending_alerts
  record_check_result tcp_port_25 0 "connect succeeded"
  dispatch_pending_alerts
  pending_alert_checks=(); pending_alert_lines=()
  fail_n_times tcp_port_25 3
  [ "${#pending_alert_lines[@]}" -eq 1 ]
}

# ---------------------------------------------------------------------
# Regression: the alerted flag is written only on confirmed delivery
# ---------------------------------------------------------------------

@test "a successful delivery writes the alerted flag" {
  fail_n_times icmp_ping 3
  dispatch_pending_alerts
  [ -f "${state_directory}/icmp_ping.alerted" ]
}

@test "REGRESSION a failed delivery does NOT write the alerted flag" {
  mail_command="${WORK}/bin/mail_broken"
  fail_n_times icmp_ping 3
  run dispatch_pending_alerts
  [ "${status}" -eq 1 ]
  [ ! -f "${state_directory}/icmp_ping.alerted" ]
}

@test "REGRESSION a failed delivery leaves the alert to retry on the next run" {
  mail_command="${WORK}/bin/mail_broken"
  fail_n_times icmp_ping 3
  dispatch_pending_alerts || true
  pending_alert_checks=(); pending_alert_lines=()
  fail_n_times icmp_ping 1
  [ "${#pending_alert_lines[@]}" -eq 1 ]
}

@test "an undelivered alert is printed to stderr rather than lost" {
  mail_command="${WORK}/bin/mail_broken"
  fail_n_times icmp_ping 3
  run dispatch_pending_alerts
  [[ "${output}" == *"ALERT UNDELIVERED"* ]]
}

@test "a failed recovery delivery keeps the alerted flag for a retry" {
  fail_n_times smb_share 3
  dispatch_pending_alerts
  mail_command="${WORK}/bin/mail_broken"
  record_check_result smb_share 0 "share listed"
  run dispatch_pending_alerts
  [ "${status}" -eq 1 ]
  [ -f "${state_directory}/smb_share.alerted" ]
}

@test "a successful recovery delivery clears the alerted flag" {
  fail_n_times smb_share 3
  dispatch_pending_alerts
  record_check_result smb_share 0 "share listed"
  dispatch_pending_alerts
  [ ! -f "${state_directory}/smb_share.alerted" ]
}

@test "send_notification_email reports failure when the mail command is absent" {
  mail_command="definitely_not_a_real_mail_command"
  run send_notification_email "subject" "body"
  [ "${status}" -eq 1 ]
}

@test "send_notification_email reports failure when the mail command errors" {
  mail_command="${WORK}/bin/mail_broken"
  run send_notification_email "subject" "body"
  [ "${status}" -eq 1 ]
}

@test "send_notification_email reports success when delivery works" {
  run send_notification_email "subject" "body"
  [ "${status}" -eq 0 ]
}

# ---------------------------------------------------------------------
# Result recording and dispatch mechanics
# ---------------------------------------------------------------------

@test "a failing check marks the run as failed" {
  fail_n_times icmp_ping 1
  [ "${any_check_failed}" = "true" ]
}

@test "a passing check alone leaves the run marked clean" {
  record_check_result icmp_ping 0 "reply received"
  [ "${any_check_failed}" = "false" ]
}

@test "checks keep independent counters" {
  fail_n_times icmp_ping 3
  fail_n_times smb_share 1
  [ "$(cat "${state_directory}/icmp_ping.failure_count")" = "3" ]
  [ "$(cat "${state_directory}/smb_share.failure_count")" = "1" ]
}

@test "multiple failing checks are combined into one alert message" {
  fail_n_times icmp_ping 3
  fail_n_times smb_share 3
  [ "${#pending_alert_lines[@]}" -eq 2 ]
  dispatch_pending_alerts
  [ -f "${state_directory}/icmp_ping.alerted" ]
  [ -f "${state_directory}/smb_share.alerted" ]
}

@test "a disabled check is not run at all" {
  run_enabled_check "false" "icmp_ping" false
  [ ! -f "${state_directory}/icmp_ping.failure_count" ]
}

@test "an enabled check records the result of its command" {
  run_enabled_check "true" "probe" bash -c 'printf detail; exit 1'
  [ "$(cat "${state_directory}/probe.failure_count")" = "1" ]
}

@test "run_enabled_check captures the check exit status, not the assignment" {
  run_enabled_check "true" "probe_pass" bash -c 'printf ok; exit 0'
  [ "$(cat "${state_directory}/probe_pass.failure_count")" = "0" ]
}

@test "dispatch with nothing pending succeeds and writes no flags" {
  run dispatch_pending_alerts
  [ "${status}" -eq 0 ]
  [ "$(ls -1 "${state_directory}" | wc -l)" -eq 0 ]
}

@test "sourcing with VALIDATOR_LIB_ONLY does not execute a run" {
  run bash -c "VALIDATOR_LIB_ONLY=1 source '${BATS_TEST_DIRNAME}/../server_connectivity_validator.sh' && echo sourced_clean"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"sourced_clean"* ]]
}
