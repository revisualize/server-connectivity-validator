#!/usr/bin/env bats
#
# ---------------------------------------------------------------------
# Path:         test/server_connectivity_validator.bats
# Filename:     server_connectivity_validator.bats
# Project:      server_connectivity_validator
# Description:  Behavioural tests for the consecutive-failure state
#               machine, alert dispatch, delivery-gated flagging, the
#               configuration and state path checks, and the input
#               handling, deadlines, and cleanup of the SMTP and NFS
#               checks.
# Status:       tested
# Revision:     5
# Updated:      2026-11-07
# Requires:     bats, bash 4.2 or newer
# Included by:  .github/workflows/ci.yml
# Provides:     test coverage for server_connectivity_validator.sh
# ---------------------------------------------------------------------
#
# Run with:  bats test/
#
# No test here talks to a real server. The state machine is covered
# directly. The SMTP and NFS checks are covered for what they do with
# their inputs, deadlines, and cleanup, using stub commands placed first
# on PATH (showmount, mount, umount, mountpoint, rmdir, ping, nc, touch,
# rm). The mount stubs keep a marker file, so mountpoint answers from
# what mount and umount did. Whether the checks behave correctly against
# real NFS, SMB, SMTP, and HTTP servers still needs a lab run.
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
  lock_file="${WORK}/validator.lock"
  failure_threshold=3

  pending_alert_checks=(); pending_alert_lines=()
  pending_recovery_checks=(); pending_recovery_lines=()
  any_check_failed="false"
  state_write_failed="false"

  # Delivery is driven through a real command on PATH rather than by
  # stubbing send_notification_email, so every test exercises the actual
  # send path including its failure branch.
  mkdir -p "${WORK}/bin"
  printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 0\n' > "${WORK}/bin/mail_ok"
  printf '#!/usr/bin/env bash\ncat > /dev/null\nexit 1\n' > "${WORK}/bin/mail_broken"
  chmod +x "${WORK}/bin"/*
  mail_command="${WORK}/bin/mail_ok"

  # Stub commands written by a test into WORK/bin are found before the
  # real ones. Tests that never write a stub are unaffected.
  PATH="${WORK}/bin:${PATH}"
}

# command -p finds the real rm even when a test has stubbed it.
teardown() { command -p rm -rf -- "${WORK}"; }

# write_stub <command_name> <script_body>
# Writes an executable stub for one command into WORK/bin.
write_stub() {
  local command_name="${1}"
  local script_body="${2}"
  printf '#!/usr/bin/env bash\n%s\n' "${script_body}" > "${WORK}/bin/${command_name}"
  chmod +x "${WORK}/bin/${command_name}"
  # Forget cached command paths, so the stub wins over a real command
  # this shell already ran.
  hash -r
}

# remove_stub <command_name>
# Removes a stub so the real command is found again.
remove_stub() {
  command -p rm -f -- "${WORK}/bin/${1}"
  hash -r
}

# showmount_lists <line>...
# Makes the showmount stub print the given lines, as showmount -e would.
showmount_lists() {
  printf '%s\n' "$@" > "${WORK}/showmount_output"
  write_stub showmount "cat '${WORK}/showmount_output'"
}

# prepare_mount_test
# Exact export advertised, mount test on, and stateful mount stubs:
# mount creates WORK/mounted, umount removes it, and mountpoint reports
# whether it exists. A test overrides one stub to inject a failure.
prepare_mount_test() {
  showmount_lists "Export list for storage01.example.net:" "/export/data 10.0.0.0/24"
  nfs_export_path="/export/data"
  enable_nfs_mount_test="true"
  write_stub mount "touch '${WORK}/mounted'; exit 0"
  write_stub umount "command -p rm -f '${WORK}/mounted'; exit 0"
  write_stub mountpoint "[ -e '${WORK}/mounted' ]"
}

# leftover_mount_directories
# Prints how many temporary mount directories remain in the state
# directory, where the mount test creates them.
leftover_mount_directories() {
  find "${state_directory}" -mindepth 1 -maxdepth 1 -type d -name 'mount.*' | wc -l
}

# disable_every_check
# Turns every check off, for tests of main itself.
disable_every_check() {
  enable_icmp_ping_check="false"
  enable_tcp_port_8080_check="false"
  enable_tcp_port_25_check="false"
  enable_http_endpoint_check="false"
  enable_smtp_banner_check="false"
  enable_nfs_export_check="false"
  enable_nfs_mount_test="false"
  enable_smb_share_check="false"
}

# run_nfs_check_with_watchdog <seconds>
# Runs check_nfs_export in a fresh bash under an outer timeout, so a
# check that never returns fails the test with status 124 instead of
# hanging the suite.
run_nfs_check_with_watchdog() {
  run timeout "${1}" env PATH="${PATH}" VALIDATOR_LIB_ONLY=1 \
    VALIDATOR_STATE_DIR="${state_directory}" VALIDATOR_LOG_FILE="${log_file}" \
    VALIDATOR_NFS_EXPORT=/export/data VALIDATOR_ENABLE_NFS_MOUNT=true VALIDATOR_TIMEOUT=1 \
    bash -c 'source "${1}"; kill_after_seconds=1; check_nfs_export' \
    watchdog "${BATS_TEST_DIRNAME}/../server_connectivity_validator.sh"
}

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

# ---------------------------------------------------------------------
# S04: configured values never run as code or reach a command as an
# option. Each test here failed on Revision 3.
# ---------------------------------------------------------------------

@test "S04 a hostile target host runs no command from check_smtp_banner" {
  local hostile_value
  check_timeout_seconds=2
  for hostile_value in \
      "127.0.0.1/1; touch ${WORK}/marker_semicolon; :" \
      "\$(touch ${WORK}/marker_substitution)" \
      "\`touch ${WORK}/marker_backtick\`"; do
    target_host="${hostile_value}"
    run check_smtp_banner
    [ "${status}" -eq 1 ]
  done
  [ ! -e "${WORK}/marker_semicolon" ]
  [ ! -e "${WORK}/marker_substitution" ]
  [ ! -e "${WORK}/marker_backtick" ]
}

@test "S04 validate_configuration refuses a target host that is not a host name or IP literal" {
  local hostile_value
  for hostile_value in "" "-oProxyCommand=touch" "-" "storage01;id" "storage01 example" \
      '$(id)' "storage01/25" ".." "a..b" "-storage01.example.net"; do
    target_host="${hostile_value}"
    run validate_configuration
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"VALIDATOR_TARGET_HOST"* ]]
  done
}

@test "S04 validate_configuration accepts host names and IP literals" {
  local good_value
  for good_value in storage01.example.net storage01 localhost "storage01.example.net." \
      192.0.2.10 "2001:db8::1" "::1" "file_server_02.lab"; do
    target_host="${good_value}"
    nfs_server="${good_value}"
    smb_server="${good_value}"
    run validate_configuration
    [ "${status}" -eq 0 ]
  done
}

@test "S04 validate_configuration refuses a bad NFS server, SMB server, export path, or HTTP URL" {
  nfs_server="-o"
  run validate_configuration
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"VALIDATOR_NFS_SERVER"* ]]
  nfs_server="storage01.example.net"

  smb_server="storage01/share"
  run validate_configuration
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"VALIDATOR_SMB_SERVER"* ]]
  smb_server="storage01.example.net"

  nfs_export_path="export/data"
  run validate_configuration
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"VALIDATOR_NFS_EXPORT"* ]]
  nfs_export_path="/export/my data"
  run validate_configuration
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"VALIDATOR_NFS_EXPORT"* ]]
  nfs_export_path="/export/data"

  http_endpoint_url="-K/etc/passwd"
  run validate_configuration
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"VALIDATOR_HTTP_URL"* ]]
}

@test "S04 main exits 2 on an invalid target host, before taking the lock or running a check" {
  write_stub nc "exit 0"
  lock_file="${WORK}/validator.lock"
  target_host="storage01;id"
  run main
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"VALIDATOR_TARGET_HOST"* ]]
  [ ! -e "${WORK}/validator.lock" ]
  [ ! -e "${state_directory}/icmp_ping.failure_count" ]
}

# ---------------------------------------------------------------------
# S05: the NFS export is matched exactly, by its column.
# ---------------------------------------------------------------------

@test "S05 a near-match export does not pass the NFS check" {
  showmount_lists "Export list for storage01.example.net:" \
    "/export/database 10.0.0.0/24" "/export/data2 *"
  nfs_export_path="/export/data"
  enable_nfs_mount_test="false"
  run check_nfs_export
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not advertised"* ]]
}

@test "S05 the export path appearing only in the client column does not pass" {
  showmount_lists "Export list for storage01.example.net:" "/srv/other /export/data.example.net"
  nfs_export_path="/export/data"
  enable_nfs_mount_test="false"
  run check_nfs_export
  [ "${status}" -eq 1 ]
}

@test "S05 the exact export passes the NFS check among near-matches" {
  showmount_lists "Export list for storage01.example.net:" \
    "/export/database 10.0.0.0/24" "/export/data 10.0.0.0/24" "/export/data2 *"
  nfs_export_path="/export/data"
  enable_nfs_mount_test="false"
  run check_nfs_export
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"control plane only"* ]]
}

@test "S05 an unreachable mountd fails with its own detail" {
  write_stub showmount "echo 'clnt_create: RPC: Unable to receive' >&2; exit 1"
  nfs_export_path="/export/data"
  run check_nfs_export
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"unavailable"* ]]
}

# ---------------------------------------------------------------------
# S12: mount test cleanup counts in the check result.
# ---------------------------------------------------------------------

@test "S12 a umount failure fails the check and names the mount left behind" {
  prepare_mount_test
  write_stub umount "echo 'umount: target is busy.' >&2; exit 32"
  run check_nfs_export
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"still mounted"* ]]
}

@test "S12 an rmdir failure fails the check" {
  prepare_mount_test
  write_stub rmdir "exit 1"
  run check_nfs_export
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"rmdir"* ]]
}

@test "S12 a failed mount is never unmounted and leaves no directory behind" {
  prepare_mount_test
  write_stub mount "exit 32"
  write_stub umount "touch '${WORK}/umount_was_called'; exit 0"
  run check_nfs_export
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"mount or read test failed"* ]]
  [ ! -e "${WORK}/umount_was_called" ]
  [ "$(leftover_mount_directories)" -eq 0 ]
}

@test "the mount test passes, unmounts, and leaves nothing behind when every step works" {
  prepare_mount_test
  run check_nfs_export
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"mounted and read successfully"* ]]
  [ ! -e "${WORK}/mounted" ]
  [ "$(leftover_mount_directories)" -eq 0 ]
}

# ---------------------------------------------------------------------
# N01: a counter that cannot be written is reported, never silent.
# The counter path is made a directory, which fails the write for root
# and for an ordinary user alike.
# ---------------------------------------------------------------------

@test "N01 a counter that cannot be written still raises an alert" {
  mkdir -p "${state_directory}/icmp_ping.failure_count"
  record_check_result icmp_ping 1 "target unreachable" 2> /dev/null
  [ "${#pending_alert_lines[@]}" -eq 1 ]
  [[ "${pending_alert_lines[0]}" == *"cannot be written"* ]]
  [ "${state_write_failed}" = "true" ]
}

@test "N01 the alert repeats on every failed run while the counter cannot be written" {
  mkdir -p "${state_directory}/icmp_ping.failure_count"
  record_check_result icmp_ping 1 "target unreachable" 2> /dev/null
  dispatch_pending_alerts
  pending_alert_checks=(); pending_alert_lines=()
  record_check_result icmp_ping 1 "target unreachable" 2> /dev/null
  [ "${#pending_alert_lines[@]}" -eq 1 ]
}

@test "N01 main exits 2 when a counter cannot be written" {
  write_stub nc "exit 0"
  write_stub ping "exit 1"
  lock_file="${WORK}/validator.lock"
  enable_tcp_port_8080_check="false"
  enable_tcp_port_25_check="false"
  enable_http_endpoint_check="false"
  enable_smtp_banner_check="false"
  enable_nfs_export_check="false"
  enable_smb_share_check="false"
  mkdir -p "${state_directory}/icmp_ping.failure_count"
  run main
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"cannot write state file"* ]]
}

# ---------------------------------------------------------------------
# Round 2 (R2-A01 to R2-A19). Each test below failed on Revision 4,
# except those named as guards.
# ---------------------------------------------------------------------

@test "R2-A01 a hanging umount is cut off and reported, not waited on" {
  prepare_mount_test
  write_stub umount "sleep 30"
  run_nfs_check_with_watchdog 20
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"umount failed or timed out"* ]]
  [[ "${output}" == *"still mounted"* ]]
}

@test "R2-A01 a hanging mount is cut off and fails the check" {
  prepare_mount_test
  write_stub mount "sleep 30"
  run_nfs_check_with_watchdog 20
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"mount or read test failed"* ]]
}

@test "R2-A02 another run holding the lock exits 2, not 0" {
  write_stub nc "exit 0"
  disable_every_check
  exec 9>> "${lock_file}"
  flock -n 9
  run main
  exec 9>&-
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"another run holds the lock"* ]]
}

@test "R2-A03 a counter symlinked to /dev/null cannot silently lose failures" {
  ln -s /dev/null "${state_directory}/probe.failure_count"
  fail_n_times probe 4 2> /dev/null
  [ "${state_write_failed}" = "true" ]
  [ "${#pending_alert_lines[@]}" -gt 0 ]
}

@test "R2-A03 a counter symlinked to another file never writes through it" {
  printf 'keep\n' > "${WORK}/victim"
  ln -s "${WORK}/victim" "${state_directory}/probe.failure_count"
  record_check_result probe 0 "reply received" 2> /dev/null
  record_check_result probe 1 "unreachable" 2> /dev/null
  [ "$(cat "${WORK}/victim")" = "keep" ]
}

@test "R2-A03 a counter write leaves no temporary file behind (guard)" {
  fail_n_times probe 2
  [ "$(cat "${state_directory}/probe.failure_count")" = "2" ]
  [ "$(find "${state_directory}" -name '.counter.*' | wc -l)" -eq 0 ]
}

@test "R2-A03 a lock file symlink is refused and its target is not truncated" {
  write_stub nc "exit 0"
  disable_every_check
  printf 'keep\n' > "${WORK}/victim"
  ln -s "${WORK}/victim" "${lock_file}"
  run main
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"lock file"*"symlink"* ]]
  [ "$(cat "${WORK}/victim")" = "keep" ]
}

@test "R2-A03 a state directory writable by others is refused" {
  write_stub nc "exit 0"
  disable_every_check
  chmod 777 "${state_directory}"
  run main
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"writable by group or others"* ]]
}

@test "R2-A03 a new state directory is private even under umask 000" {
  write_stub nc "exit 0"
  disable_every_check
  state_directory="${WORK}/new_state"
  umask 000
  run main
  umask 022
  [ "${status}" -eq 0 ]
  [ "$(stat -c '%a' "${state_directory}")" = "700" ]
}

@test "R2-A04 a failed alerted-flag write is a state error and fails dispatch" {
  fail_n_times icmp_ping 3
  write_stub touch "exit 1"
  run dispatch_pending_alerts
  remove_stub touch
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cannot create state file"* ]]
}

@test "R2-A04 a failed flag removal after recovery cannot suppress the next incident" {
  fail_n_times smb_share 3
  dispatch_pending_alerts
  write_stub rm "exit 1"
  record_check_result smb_share 0 "share listed"
  run dispatch_pending_alerts
  remove_stub rm
  [ "${status}" -ne 0 ]
  pending_alert_checks=(); pending_alert_lines=()
  pending_recovery_checks=(); pending_recovery_lines=()
  fail_n_times smb_share 3
  [ "${#pending_alert_lines[@]}" -eq 1 ]
}

@test "R2-A04 a stale alerted flag from an earlier incident is cleared when a new one starts" {
  touch "${state_directory}/icmp_ping.alerted"
  fail_n_times icmp_ping 3
  [ "${#pending_alert_lines[@]}" -eq 1 ]
}

@test "R2-A05 an alert that was never delivered is named in the recovery notice" {
  mail_command="${WORK}/bin/mail_broken"
  fail_n_times icmp_ping 3
  dispatch_pending_alerts 2> /dev/null || true
  [ -f "${state_directory}/icmp_ping.undelivered" ]
  pending_alert_checks=(); pending_alert_lines=()
  mail_command="${WORK}/bin/mail_ok"
  record_check_result icmp_ping 0 "reply received"
  [ "${#pending_recovery_lines[@]}" -eq 1 ]
  [[ "${pending_recovery_lines[0]}" == *"never delivered"* ]]
  dispatch_pending_alerts
  [ ! -e "${state_directory}/icmp_ping.undelivered" ]
}

@test "R2-A06 malformed IPv6 and IPv4 values are refused" {
  local bad_value
  for bad_value in ":" ":::" "::::" "2001:::1" "1.2.3.4:" "1:2:3:4:5:6:7:8:9" \
      "1:2:3:4:5:6:7" "2001::db8::1" "12345::1" "::1.2.3.999" "fe80::1%eth0" \
      "999.999.999.999" "1.2.3.4.5" "1.2.3"; do
    run is_valid_host_name "${bad_value}"
    [ "${status}" -ne 0 ]
  done
}

@test "R2-A06 valid IPv6 and IPv4 forms are accepted (guard)" {
  local good_value
  for good_value in "::" "::1" "fe80::1" "2001:db8:0:0:0:0:0:1" "2001:DB8::8:800:200C:417A" \
      "::ffff:192.0.2.1" "1:2:3:4:5:6:7::" "0.0.0.0" "255.255.255.255" "10.0.0.08"; do
    run is_valid_host_name "${good_value}"
    [ "${status}" -eq 0 ]
  done
}

@test "R2-A06 host name length limits: 63-character labels, 253 characters, 254 with a trailing dot" {
  local label_63 label_64 name_253 name_254_dot name_254
  label_63="$(printf 'a%.0s' {1..63})"
  label_64="$(printf 'a%.0s' {1..64})"
  name_253="${label_63}.${label_63}.${label_63}.$(printf 'd%.0s' {1..61})"
  name_254_dot="${name_253}."
  name_254="${name_253}e"
  [ "${#name_253}" -eq 253 ]
  [ "${#name_254_dot}" -eq 254 ]
  is_valid_host_name "${label_63}"
  ! is_valid_host_name "${label_64}"
  is_valid_host_name "${name_253}"
  is_valid_host_name "${name_254_dot}"
  ! is_valid_host_name "${name_254}"
}

@test "R2-A07 an IPv6 NFS server is bracketed in the mount source" {
  prepare_mount_test
  nfs_server="2001:db8::1"
  write_stub mount "printf '%s\n' \"\$@\" > '${WORK}/mount_arguments'; exit 32"
  run check_nfs_export
  grep -qF '[2001:db8::1]:/export/data' "${WORK}/mount_arguments"
}

@test "R2-A08 a timeout that is zero, not a whole number, or over 300 is refused" {
  local bad_value
  for bad_value in 0 garbage --help -1 2.5 301 0005; do
    check_timeout_seconds="${bad_value}"
    run validate_configuration
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"VALIDATOR_TIMEOUT"* ]]
  done
  for check_timeout_seconds in 1 5 300; do
    run validate_configuration
    [ "${status}" -eq 0 ]
  done
}

@test "R2-A09 recipients that are empty, start with -, or hold control characters are refused" {
  local bad_value
  for bad_value in "" "-Ssendwait" "--help" $'ops@example.net\nbcc@example.net'; do
    alert_recipients="${bad_value}"
    run validate_configuration
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"VALIDATOR_RECIPIENTS"* ]]
  done
  alert_recipients="ops@example.net,storage@example.net"
  run validate_configuration
  [ "${status}" -eq 0 ]
}

@test "R2-A10 an SMB share name that is empty or holds a path separator or control character is refused" {
  local bad_value
  for bad_value in "" "data/sub" 'data\sub' $'data\nother'; do
    smb_share_name="${bad_value}"
    run validate_configuration
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"VALIDATOR_SMB_SHARE"* ]]
  done
  for smb_share_name in "data" "Shared Docs" 'admin$'; do
    run validate_configuration
    [ "${status}" -eq 0 ]
  done
}

@test "R2-A11 an enable value other than exactly true or false is refused" {
  local bad_value
  for bad_value in TRUE yes 1 ""; do
    enable_icmp_ping_check="${bad_value}"
    run validate_configuration
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"VALIDATOR_ENABLE_ICMP"* ]]
  done
  enable_icmp_ping_check="true"
  enable_nfs_mount_test="maybe"
  run validate_configuration
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"VALIDATOR_ENABLE_NFS_MOUNT"* ]]
}

@test "R2-A12 a tool missing for an enabled check is a dependency error, exit 2" {
  local command_name
  for command_name in nc curl timeout flock date mktemp mv stat awk; do
    write_stub "${command_name}" "exit 0"
  done
  disable_every_check
  enable_nfs_export_check="true"
  # Restore PATH straight after the run: bats needs rm and other tools
  # for its own cleanup, and a stub-only PATH fails the whole suite.
  local saved_path="${PATH}"
  PATH="${WORK}/bin"
  run main
  PATH="${saved_path}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"missing required command(s): showmount"* ]]
}

@test "R2-A13 trailing slashes and a carriage return do not defeat the export match" {
  enable_nfs_mount_test="false"
  showmount_lists "Export list for storage01.example.net:" "/export/data/ 10.0.0.0/24"
  nfs_export_path="/export/data"
  run check_nfs_export
  [ "${status}" -eq 0 ]
  showmount_lists "Export list for storage01.example.net:" "/export/data *"
  nfs_export_path="/export/data/"
  run check_nfs_export
  [ "${status}" -eq 0 ]
  showmount_lists "Export list for storage01.example.net:" $'/export/data\r'
  nfs_export_path="/export/data"
  run check_nfs_export
  [ "${status}" -eq 0 ]
}

@test "R2-A13 normalising slashes still never matches a longer export (guard)" {
  enable_nfs_mount_test="false"
  showmount_lists "Export list for storage01.example.net:" "/export/data/sub *" "/ *"
  nfs_export_path="/export/data"
  run check_nfs_export
  [ "${status}" -eq 1 ]
  nfs_export_path="/"
  run check_nfs_export
  [ "${status}" -eq 0 ]
}

@test "R2-A14 a mount command that fails after attaching a mount is still unmounted" {
  prepare_mount_test
  write_stub mount "touch '${WORK}/mounted'; exit 32"
  run check_nfs_export
  [ "${status}" -eq 1 ]
  [ ! -e "${WORK}/mounted" ]
  [ "$(leftover_mount_directories)" -eq 0 ]
}

@test "R2-A14 umount reporting success while the mount remains fails the check" {
  prepare_mount_test
  write_stub umount "exit 0"
  run check_nfs_export
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"umount reported success but"*"still mounted"* ]]
}

@test "R2-A15 the mount point is created in the state directory, not under TMPDIR" {
  prepare_mount_test
  write_stub umount "exit 32"
  mkdir -p "${WORK}/elsewhere"
  export TMPDIR="${WORK}/elsewhere"
  run check_nfs_export
  [ "$(leftover_mount_directories)" -eq 1 ]
  [ "$(find "${WORK}/elsewhere" -mindepth 1 | wc -l)" -eq 0 ]
}

@test "R2-A16 a stored count with a leading zero is read in base 10" {
  printf '08\n' > "${state_directory}/probe.failure_count"
  record_check_result probe 1 "unreachable"
  [ "$(cat "${state_directory}/probe.failure_count")" = "9" ]
  printf '1234567890\n' > "${state_directory}/probe.failure_count"
  run read_failure_count "${state_directory}/probe.failure_count"
  [ "${output}" = "0" ]
}

@test "R2-A18 the README carries no self-promotional sentence" {
  run grep -F "sample of the author's work" "${BATS_TEST_DIRNAME}/../README.md"
  [ "${status}" -eq 1 ]
}

@test "R2-A19 a notification that was not sent makes main exit 2" {
  write_stub nc "exit 0"
  write_stub ping "exit 1"
  disable_every_check
  enable_icmp_ping_check="true"
  failure_threshold=1
  mail_command="${WORK}/bin/mail_broken"
  run main
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"notifications were not sent"* ]]
}
