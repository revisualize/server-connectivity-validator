#!/usr/bin/env bash
#
# ---------------------------------------------------------------------
# Path:         server_connectivity_validator.sh
# Filename:     server_connectivity_validator.sh
# Project:      server_connectivity_validator
# Description:  A layered connectivity validator that climbs from ICMP
#               through TCP, HTTP, and SMTP to real NFS and SMB data
#               path tests, counts consecutive failures per check, and
#               alerts once per incident with a recovery notice.
# Status:       production
# Revision:     2
# Updated:      2026-08-05
# Requires:     Bash 4.2 or newer, GNU coreutils, nc, curl, timeout,
#               flock; showmount for NFS, smbclient for SMB
# Included by:  standalone command line tool; sourceable for testing
# Provides:     read_failure_count, record_check_result,
#               send_notification_email, dispatch_pending_alerts,
#               run_enabled_check, and the individual check_ functions
# ---------------------------------------------------------------------
#
# Portability
#   Target shells:  bash 4.2+ (arrays; /dev/tcp for the SMTP banner
#                   check, which is a bash builtin feature and is not
#                   available under dash or ash).
#   Tested on:      bash 5.2 on Ubuntu 24.04. The state machine, alert
#                   dispatch, and result recording are covered by the
#                   test suite. The network-facing checks require real
#                   infrastructure and are declared untested.
#
# Exit codes:
#   0  every enabled check passed
#   1  one or more checks failed
#   2  configuration, dependency, lock, or state directory error
#
# Environment (all optional; defaults shown):
#   VALIDATOR_TARGET_HOST         storage01.example.net
#   VALIDATOR_HTTP_URL            http://storage01.example.net:8080/health
#   VALIDATOR_NFS_SERVER          storage01.example.net
#   VALIDATOR_NFS_EXPORT          /export/data
#   VALIDATOR_SMB_SERVER          storage01.example.net
#   VALIDATOR_SMB_SHARE           data
#   VALIDATOR_SMB_CREDENTIALS     /etc/server_connectivity_validator/smb_credentials
#   VALIDATOR_FAILURE_THRESHOLD   3
#   VALIDATOR_TIMEOUT             5
#   VALIDATOR_RECIPIENTS          storage-alerts@example.net
#   VALIDATOR_STATE_DIR           /var/lib/server_connectivity_validator
#   VALIDATOR_LOG_FILE            /var/log/server_connectivity_validator.log
#   VALIDATOR_LOCK_FILE           /var/lock/server_connectivity_validator.lock
#   VALIDATOR_MAIL_COMMAND        mail
#   VALIDATOR_ENABLE_*            true/false per check (see below)
#   VALIDATOR_LIB_ONLY            set to 1 to source functions for testing
#

set -u

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------
target_host="${VALIDATOR_TARGET_HOST:-storage01.example.net}"
http_endpoint_url="${VALIDATOR_HTTP_URL:-http://storage01.example.net:8080/health}"
nfs_server="${VALIDATOR_NFS_SERVER:-storage01.example.net}"
nfs_export_path="${VALIDATOR_NFS_EXPORT:-/export/data}"
smb_server="${VALIDATOR_SMB_SERVER:-storage01.example.net}"
smb_share_name="${VALIDATOR_SMB_SHARE:-data}"
smb_credentials_file="${VALIDATOR_SMB_CREDENTIALS:-/etc/server_connectivity_validator/smb_credentials}"

enable_icmp_ping_check="${VALIDATOR_ENABLE_ICMP:-true}"
enable_tcp_port_8080_check="${VALIDATOR_ENABLE_TCP_8080:-true}"
enable_tcp_port_25_check="${VALIDATOR_ENABLE_TCP_25:-true}"
enable_http_endpoint_check="${VALIDATOR_ENABLE_HTTP:-true}"
enable_smtp_banner_check="${VALIDATOR_ENABLE_SMTP:-true}"
enable_nfs_export_check="${VALIDATOR_ENABLE_NFS:-true}"
enable_nfs_mount_test="${VALIDATOR_ENABLE_NFS_MOUNT:-false}"
enable_smb_share_check="${VALIDATOR_ENABLE_SMB:-true}"

failure_threshold="${VALIDATOR_FAILURE_THRESHOLD:-3}"
check_timeout_seconds="${VALIDATOR_TIMEOUT:-5}"
alert_recipients="${VALIDATOR_RECIPIENTS:-storage-alerts@example.net}"
mail_command="${VALIDATOR_MAIL_COMMAND:-mail}"

state_directory="${VALIDATOR_STATE_DIR:-/var/lib/server_connectivity_validator}"
log_file="${VALIDATOR_LOG_FILE:-/var/log/server_connectivity_validator.log}"
lock_file="${VALIDATOR_LOCK_FILE:-/var/lock/server_connectivity_validator.lock}"

# Alerts carry the name of the check, the count, and the detail. They are
# held here until delivery succeeds, and the alerted flag is written only
# after that, which is the whole point of the rewrite below.
pending_alert_checks=()
pending_alert_lines=()
pending_recovery_checks=()
pending_recovery_lines=()
any_check_failed="false"

# ---------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------

log_message() {
    local log_directory
    log_directory="$(dirname "${log_file}")"
    [ -d "${log_directory}" ] || mkdir -p "${log_directory}" 2>/dev/null || return 0
    printf '%s %s\n' "$(date --iso-8601=seconds)" "${1}" >> "${log_file}" 2>/dev/null || true
}

host_identity() {
    hostname --fqdn 2>/dev/null || hostname 2>/dev/null || printf 'unknown-host'
}

# read_failure_count <path>
# A state file that is missing, empty, or not a whole number reads as
# zero and says so. Silently letting a corrupt counter evaluate to zero
# in arithmetic restarts the countdown mid-outage and delays the alert.
read_failure_count() {
    local counter_file="${1}"
    local raw_value
    [ -f "${counter_file}" ] || { printf '0'; return 0; }
    raw_value="$(tr -d '[:space:]' < "${counter_file}")"
    if ! printf '%s' "${raw_value}" | grep -qE '^[0-9]+$'; then
        log_message "WARN: state file ${counter_file} is corrupt (read as '${raw_value}'); resetting to 0"
        printf '0'
        return 0
    fi
    printf '%s' "${raw_value}"
}

# ---------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------

# record_check_result <check_name> <exit_status> <detail_text>
# Maintains the consecutive-failure counter for one check and queues an
# alert or recovery line when a state transition occurs. It does NOT
# write the alerted flag; that happens only on confirmed delivery.
record_check_result() {
    local check_name="${1}"
    local exit_status="${2}"
    local detail_text="${3}"
    local failure_count_file="${state_directory}/${check_name}.failure_count"
    local alerted_flag_file="${state_directory}/${check_name}.alerted"
    local failure_count
    failure_count="$(read_failure_count "${failure_count_file}")"

    if [ "${exit_status}" -eq 0 ]; then
        if [ -f "${alerted_flag_file}" ]; then
            pending_recovery_checks+=("${check_name}")
            pending_recovery_lines+=("${check_name}: recovered after ${failure_count} consecutive failed runs.")
        fi
        printf '0\n' > "${failure_count_file}"
        log_message "PASS ${check_name}: ${detail_text}"
        return 0
    fi

    any_check_failed="true"
    failure_count=$((failure_count + 1))
    printf '%s\n' "${failure_count}" > "${failure_count_file}"
    log_message "FAIL ${check_name} (consecutive failure ${failure_count}/${failure_threshold}): ${detail_text}"

    if [ "${failure_count}" -ge "${failure_threshold}" ] && [ ! -f "${alerted_flag_file}" ]; then
        pending_alert_checks+=("${check_name}")
        pending_alert_lines+=("${check_name}: ${failure_count} consecutive failed runs. Last detail: ${detail_text}")
    fi
    return 0
}

# send_notification_email <subject> <body>
# Returns nonzero when the message was not handed off successfully.
send_notification_email() {
    local email_subject="${1}"
    local email_body="${2}"
    if ! command -v "${mail_command}" > /dev/null 2>&1; then
        log_message "ERROR: mail command '${mail_command}' not found, cannot send notification."
        return 1
    fi
    if ! printf '%s\n' "${email_body}" \
        | "${mail_command}" -s "${email_subject}" "${alert_recipients}"; then
        log_message "ERROR: '${mail_command}' failed while sending: ${email_subject}"
        return 1
    fi
    log_message "Sent notification: ${email_subject}"
    return 0
}

# dispatch_pending_alerts
# Sends the queued alert and recovery messages, and marks state only on
# success. A failed delivery leaves the check unalerted so the next run
# tries again, and the undelivered content goes to stderr rather than
# being lost. The previous implementation marked the check as alerted at
# the moment the alert was queued, so a single failed send silenced that
# check for the entire remainder of the outage.
dispatch_pending_alerts() {
    local dispatch_status=0
    local check_name
    local host_name
    host_name="$(host_identity)"

    if [ "${#pending_alert_lines[@]}" -gt 0 ]; then
        local alert_body
        alert_body="Connectivity validation failures for ${target_host} at $(date --iso-8601=seconds):"$'\n\n'
        alert_body+="$(printf '%s\n' "${pending_alert_lines[@]}")"
        alert_body+=$'\n\n'"Threshold: ${failure_threshold} consecutive runs. Log: ${log_file} on ${host_name}."
        if send_notification_email "ALERT: connectivity failures on ${target_host}" "${alert_body}"; then
            for check_name in "${pending_alert_checks[@]}"; do
                touch "${state_directory}/${check_name}.alerted"
            done
        else
            printf 'ALERT UNDELIVERED (will retry next run):\n%s\n' "${alert_body}" >&2
            dispatch_status=1
        fi
    fi

    if [ "${#pending_recovery_lines[@]}" -gt 0 ]; then
        local recovery_body
        recovery_body="Recovered checks for ${target_host} at $(date --iso-8601=seconds):"$'\n\n'
        recovery_body+="$(printf '%s\n' "${pending_recovery_lines[@]}")"
        if send_notification_email "RECOVERED: connectivity restored on ${target_host}" "${recovery_body}"; then
            for check_name in "${pending_recovery_checks[@]}"; do
                rm -f "${state_directory}/${check_name}.alerted"
            done
        else
            printf 'RECOVERY NOTICE UNDELIVERED (will retry next run):\n%s\n' "${recovery_body}" >&2
            dispatch_status=1
        fi
    fi

    return "${dispatch_status}"
}

# ---------------------------------------------------------------------
# Checks. Each prints a one line detail to stdout and returns 0 on pass.
# ---------------------------------------------------------------------

check_icmp_ping() {
    if ping -c 2 -W "${check_timeout_seconds}" "${target_host}" > /dev/null 2>&1; then
        printf 'ICMP echo reply received from %s' "${target_host}"
        return 0
    fi
    printf 'No ICMP echo reply from %s within %ss' "${target_host}" "${check_timeout_seconds}"
    return 1
}

check_tcp_port() {
    local port_number="${1}"
    if nc -z -w "${check_timeout_seconds}" "${target_host}" "${port_number}" > /dev/null 2>&1; then
        printf 'TCP connect to %s:%s succeeded' "${target_host}" "${port_number}"
        return 0
    fi
    printf 'TCP connect to %s:%s failed or timed out' "${target_host}" "${port_number}"
    return 1
}

check_http_endpoint() {
    local curl_output
    if curl_output="$(curl --silent --show-error --fail \
            --max-time "${check_timeout_seconds}" \
            --output /dev/null --write-out '%{http_code}' \
            "${http_endpoint_url}" 2>&1)"; then
        printf 'HTTP %s from %s' "${curl_output}" "${http_endpoint_url}"
        return 0
    fi
    printf 'HTTP check failed for %s: %s' "${http_endpoint_url}" "${curl_output}"
    return 1
}

check_smtp_banner() {
    local smtp_banner_line
    smtp_banner_line="$(timeout "${check_timeout_seconds}" bash -c \
        "exec 3<>/dev/tcp/${target_host}/25; head -n 1 <&3" 2> /dev/null)"
    if [ "${smtp_banner_line:0:3}" = "220" ]; then
        printf 'SMTP banner received: %s' "${smtp_banner_line%%$'\r'}"
        return 0
    fi
    printf 'No valid SMTP 220 banner from %s:25 (received: %s)' \
        "${target_host}" "${smtp_banner_line:-nothing}"
    return 1
}

check_nfs_export() {
    if ! timeout "${check_timeout_seconds}" showmount -e "${nfs_server}" 2> /dev/null \
            | grep -q -F "${nfs_export_path}"; then
        printf 'Export %s not advertised by %s or mountd unreachable' \
            "${nfs_export_path}" "${nfs_server}"
        return 1
    fi
    if [ "${enable_nfs_mount_test}" != "true" ]; then
        printf 'Export %s advertised by %s (control plane only)' \
            "${nfs_export_path}" "${nfs_server}"
        return 0
    fi
    local temporary_mount_directory
    temporary_mount_directory="$(mktemp -d)" || return 1
    if mount -t nfs -o ro,soft,timeo=30,retrans=2 \
            "${nfs_server}:${nfs_export_path}" "${temporary_mount_directory}" 2> /dev/null \
            && ls "${temporary_mount_directory}" > /dev/null 2>&1; then
        umount "${temporary_mount_directory}" 2> /dev/null
        rmdir "${temporary_mount_directory}" 2> /dev/null
        printf 'Export %s mounted and read successfully' "${nfs_export_path}"
        return 0
    fi
    umount "${temporary_mount_directory}" 2> /dev/null
    rmdir "${temporary_mount_directory}" 2> /dev/null
    printf 'Export %s advertised but mount or read test failed' "${nfs_export_path}"
    return 1
}

check_smb_share() {
    if [ ! -r "${smb_credentials_file}" ]; then
        printf 'SMB credentials file %s missing or unreadable' "${smb_credentials_file}"
        return 1
    fi
    if timeout "${check_timeout_seconds}" smbclient "//${smb_server}/${smb_share_name}" \
            --authentication-file="${smb_credentials_file}" -c 'ls' > /dev/null 2>&1; then
        printf 'SMB share //%s/%s authenticated and listed' "${smb_server}" "${smb_share_name}"
        return 0
    fi
    printf 'SMB share //%s/%s authentication or listing failed' "${smb_server}" "${smb_share_name}"
    return 1
}

# run_enabled_check <enable_flag> <check_name> <command...>
run_enabled_check() {
    local enable_flag_value="${1}"
    local check_name="${2}"
    shift 2
    local check_detail
    local check_status
    if [ "${enable_flag_value}" != "true" ]; then
        return 0
    fi
    # Captured inside an if, not as a bare assignment. A bare
    # command-substitution assignment aborts the whole function under
    # errexit, which is how bats runs test bodies, so the failure branch
    # of every check was unreachable under test.
    if check_detail="$("$@")"; then
        check_status=0
    else
        check_status=$?
    fi
    record_check_result "${check_name}" "${check_status}" "${check_detail}"
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

main() {
    local required_command
    local missing_commands=()
    for required_command in nc curl timeout flock date mktemp; do
        command -v "${required_command}" > /dev/null 2>&1 \
            || missing_commands+=("${required_command}")
    done
    if [ "${#missing_commands[@]}" -gt 0 ]; then
        printf 'FAIL: missing required command(s): %s\n' "${missing_commands[*]}" >&2
        return 2
    fi

    if ! printf '%s' "${failure_threshold}" | grep -qE '^[1-9][0-9]*$'; then
        printf 'FAIL: failure threshold must be a positive whole number, got: %s\n' \
            "${failure_threshold}" >&2
        return 2
    fi

    mkdir -p "$(dirname "${lock_file}")" 2>/dev/null
    if ! exec 200>"${lock_file}"; then
        printf 'FAIL: cannot open lock file %s\n' "${lock_file}" >&2
        return 2
    fi
    if ! flock -n 200; then
        log_message "Previous run still holds the lock, exiting."
        return 0
    fi

    mkdir -p "${state_directory}" || {
        log_message "ERROR: cannot create ${state_directory}"
        printf 'FAIL: cannot create state directory %s\n' "${state_directory}" >&2
        return 2
    }

    run_enabled_check "${enable_icmp_ping_check}"     "icmp_ping"     check_icmp_ping
    run_enabled_check "${enable_tcp_port_8080_check}" "tcp_port_8080" check_tcp_port 8080
    run_enabled_check "${enable_tcp_port_25_check}"   "tcp_port_25"   check_tcp_port 25
    run_enabled_check "${enable_http_endpoint_check}" "http_endpoint" check_http_endpoint
    run_enabled_check "${enable_smtp_banner_check}"   "smtp_banner"   check_smtp_banner
    run_enabled_check "${enable_nfs_export_check}"    "nfs_export"    check_nfs_export
    run_enabled_check "${enable_smb_share_check}"     "smb_share"     check_smb_share

    dispatch_pending_alerts || true

    [ "${any_check_failed}" = "true" ] && return 1
    return 0
}

if [ "${VALIDATOR_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
    exit $?
fi
