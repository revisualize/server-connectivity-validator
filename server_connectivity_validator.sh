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
# Status:       tested
# Revision:     5
# Updated:      2026-11-06
# Requires:     Bash 4.2 or newer, GNU coreutils, awk, nc, curl,
#               flock, and a mail command. ping for ICMP, showmount for
#               NFS, mount, umount, and mountpoint for the NFS mount
#               test, smbclient for SMB.
# Included by:  standalone command line tool; sourceable for testing
# Provides:     read_failure_count, write_failure_count,
#               is_valid_host_name, validate_configuration,
#               record_check_result, send_notification_email,
#               dispatch_pending_alerts, run_enabled_check, and the
#               individual check_ functions
# ---------------------------------------------------------------------
#
# Portability
#   Target shells:  bash 4.2+ (arrays; /dev/tcp for the SMTP banner
#                   check, which is a bash builtin feature and is not
#                   available under dash or ash).
#   Tested on:      bash 5.2 and 5.3 on Ubuntu. The test suite covers the
#                   state machine, alert dispatch, result recording, the
#                   configuration checks, the state, lock, and log path
#                   checks, hostile input to the SMTP check, and the NFS
#                   check's export matching, deadlines, and mount
#                   cleanup, all against stub commands. No check has been
#                   run against a real server by the suite.
#
# Exit codes:
#   0  every enabled check ran and passed, and every notification was sent
#   1  one or more checks failed
#   2  configuration, dependency, lock (including another run holding
#      it), state directory, or notification delivery error; this
#      outranks 1
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
#   VALIDATOR_TIMEOUT             5 (whole seconds, 1 to 300)
#   VALIDATOR_RECIPIENTS          storage-alerts@example.net
#   VALIDATOR_STATE_DIR           /var/lib/server_connectivity_validator
#   VALIDATOR_LOG_FILE            /var/log/server_connectivity_validator.log
#   VALIDATOR_LOCK_FILE           /var/lock/server_connectivity_validator.lock
#   VALIDATOR_MAIL_COMMAND        mail
#   VALIDATOR_ENABLE_*            exactly true or false per check (see below)
#   VALIDATOR_LIB_ONLY            set to 1 to source functions for testing
#
# Trusted settings: the mail command, the SMB credentials file, and the
# state, log, and lock paths are chosen by whoever runs the tool and are
# not validated beyond the path checks in prepare_state_paths.
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

# Seconds a timed-out mount, read, or unmount gets after SIGTERM before
# SIGKILL. A process stuck in an uninterruptible kernel wait can outlive
# both signals; that case is reported as a cleanup failure if it returns.
kill_after_seconds=5

# Alerts carry the name of the check, the count, and the detail. They are
# held here until delivery succeeds, and the alerted flag is written only
# after that.
pending_alert_checks=()
pending_alert_lines=()
pending_recovery_checks=()
pending_recovery_lines=()
any_check_failed="false"
state_write_failed="false"

# ---------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------

# log_message <text>
# Best effort: a log that cannot be written never stops a run, which is
# why every error that matters is also printed to stderr.
log_message() {
    local log_directory
    log_directory="$(dirname "${log_file}")"
    [ -d "${log_directory}" ] || mkdir -p "${log_directory}" 2>/dev/null || return 0
    printf '%s %s\n' "$(date --iso-8601=seconds)" "${1}" >> "${log_file}" 2>/dev/null || true
}

host_identity() {
    hostname --fqdn 2>/dev/null || hostname 2>/dev/null || printf 'unknown-host'
}

# report_state_error <text>
# Marks the run as a state directory error (main exits 2), logs the
# text, and prints it to stderr.
report_state_error() {
    state_write_failed="true"
    log_message "ERROR: ${1}"
    printf 'ERROR: %s\n' "${1}" >&2
}

# state_file_is_safe <path>
# True when the path does not exist yet, or is a regular file that is
# not a symlink. A symlink or any other kind of object in the state
# directory is never read, written, or followed.
state_file_is_safe() {
    [ ! -L "${1}" ] && { [ ! -e "${1}" ] || [ -f "${1}" ]; }
}

# read_failure_count <path>
# A state file that is missing, empty, or not a whole number of at most
# nine digits reads as zero and says so. The value is read in base 10,
# so a stored 08 is eight, not an invalid octal number.
read_failure_count() {
    local counter_file="${1}"
    local raw_value
    [ -f "${counter_file}" ] || { printf '0'; return 0; }
    raw_value="$(tr -d '[:space:]' < "${counter_file}")"
    if ! printf '%s' "${raw_value}" | grep -qE '^[0-9]{1,9}$'; then
        log_message "WARN: state file ${counter_file} is corrupt (read as '${raw_value}'); resetting to 0"
        printf '0'
        return 0
    fi
    printf '%s' "$((10#${raw_value}))"
}

# write_failure_count <path> <count>
# Writes the count to a new file in the state directory and renames it
# over the counter, so a symlink planted at the counter is replaced,
# never followed. Returns nonzero, after report_state_error, when the
# counter cannot be written.
write_failure_count() {
    local counter_file="${1}"
    local counter_value="${2}"
    local temporary_counter_file=""
    if ! state_file_is_safe "${counter_file}"; then
        report_state_error "cannot write state file ${counter_file}: it is a symlink or not a regular file"
        return 1
    fi
    if temporary_counter_file="$(mktemp "${state_directory}/.counter.XXXXXX" 2> /dev/null)" \
            && printf '%s\n' "${counter_value}" 2> /dev/null > "${temporary_counter_file}" \
            && mv -f "${temporary_counter_file}" "${counter_file}" 2> /dev/null; then
        return 0
    fi
    [ -n "${temporary_counter_file}" ] && rm -f -- "${temporary_counter_file}" 2> /dev/null
    report_state_error "cannot write state file ${counter_file}; consecutive failures are not being counted"
    return 1
}

# create_state_flag <path>
# Creates a flag file, refusing a symlink or other non-regular object.
create_state_flag() {
    if state_file_is_safe "${1}" && touch -- "${1}" 2> /dev/null && [ -f "${1}" ]; then
        return 0
    fi
    report_state_error "cannot create state file ${1}"
    return 1
}

# remove_state_file <path>
# Removes a flag file and confirms it is gone.
remove_state_file() {
    rm -f -- "${1}" 2> /dev/null
    if [ -e "${1}" ] || [ -L "${1}" ]; then
        report_state_error "cannot remove state file ${1}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------
# Configuration checks
# ---------------------------------------------------------------------

# is_valid_ipv4_literal <value>
# Four decimal octets, each 0 to 255.
is_valid_ipv4_literal() {
    local octet
    [[ "${1}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        [ "$((10#${octet}))" -le 255 ] || return 1
    done
    return 0
}

# count_ipv6_groups <part>
# Prints how many groups a colon-separated part holds, each 1 to 4 hex
# digits. Returns 1 for an empty group or a leading or trailing colon.
count_ipv6_groups() {
    local ipv6_part="${1}"
    local ipv6_group
    local ipv6_group_count=0
    local -a ipv6_groups
    if [ -z "${ipv6_part}" ]; then
        printf '0'
        return 0
    fi
    if [[ "${ipv6_part}" == :* ]] || [[ "${ipv6_part}" == *: ]] || [[ "${ipv6_part}" == *::* ]]; then
        return 1
    fi
    IFS=':' read -ra ipv6_groups <<< "${ipv6_part}"
    for ipv6_group in "${ipv6_groups[@]}"; do
        [[ "${ipv6_group}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        ipv6_group_count=$((ipv6_group_count + 1))
    done
    printf '%s' "${ipv6_group_count}"
}

# is_valid_ipv6_literal <value>
# An IPv6 address in text form (RFC 4291 section 2.2): eight groups of
# 1 to 4 hex digits, or fewer with a single "::", optionally ending in
# a dotted IPv4 address that stands for the last two groups. Zone
# identifiers (%eth0) are not accepted.
is_valid_ipv6_literal() {
    local ipv6_candidate="${1}"
    local ipv4_tail
    local head_count
    local tail_count
    local compression_marks
    [[ "${ipv6_candidate}" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    if [[ "${ipv6_candidate}" == *.* ]]; then
        ipv4_tail="${ipv6_candidate##*:}"
        is_valid_ipv4_literal "${ipv4_tail}" || return 1
        ipv6_candidate="${ipv6_candidate%"${ipv4_tail}"}0:0"
    fi
    if [[ "${ipv6_candidate}" == *:::* ]]; then
        return 1
    fi
    compression_marks="${ipv6_candidate//::/@}"
    compression_marks="${compression_marks//[^@]/}"
    if [ "${#compression_marks}" -eq 0 ]; then
        head_count="$(count_ipv6_groups "${ipv6_candidate}")" || return 1
        [ "${head_count}" -eq 8 ]
        return
    fi
    [ "${#compression_marks}" -eq 1 ] || return 1
    head_count="$(count_ipv6_groups "${ipv6_candidate%%::*}")" || return 1
    tail_count="$(count_ipv6_groups "${ipv6_candidate#*::}")" || return 1
    [ $((head_count + tail_count)) -le 7 ]
}

# is_valid_host_name <value>
# True for an IPv4 literal, an IPv6 literal, or a resolver host name:
# labels of 1 to 63 letters, digits, underscores, and inner hyphens,
# joined by dots, at most 253 characters, or 254 with a trailing dot.
# Underscores are accepted on purpose for names some private resolvers
# serve, although RFC 1123 host names do not allow them. A dotted value
# made only of digits must be a valid IPv4 literal. Everything else is
# refused, so a configured host never reaches a command as an option
# (a leading -) and never carries shell syntax, a path separator, or
# whitespace.
is_valid_host_name() {
    local candidate_host="${1}"
    local host_label_pattern='[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?'
    local maximum_length=253
    [ -n "${candidate_host}" ] || return 1
    [[ "${candidate_host}" == *. ]] && maximum_length=254
    [ "${#candidate_host}" -le "${maximum_length}" ] || return 1
    if [[ "${candidate_host}" == *:* ]]; then
        is_valid_ipv6_literal "${candidate_host}"
        return
    fi
    if [[ "${candidate_host}" =~ ^[0-9.]+$ ]]; then
        is_valid_ipv4_literal "${candidate_host}"
        return
    fi
    [[ "${candidate_host}" =~ ^${host_label_pattern}(\.${host_label_pattern})*\.?$ ]]
}

# validate_configuration
# Checks the configured hosts, export path, URL, timeout, recipients,
# share name, and every enable flag, whether or not the check that uses
# a value is enabled, so a bad value is found before the day someone
# enables its check. Prints one FAIL line per problem to stderr and
# returns 1 if there is any; main turns that into exit code 2 before any
# check runs. The trusted settings listed in the header are not checked
# here.
validate_configuration() {
    local configuration_problems=()
    local enable_setting
    local enable_variable_name
    local enable_value
    is_valid_host_name "${target_host}" \
        || configuration_problems+=("VALIDATOR_TARGET_HOST is not a host name or IP literal: '${target_host}'")
    is_valid_host_name "${nfs_server}" \
        || configuration_problems+=("VALIDATOR_NFS_SERVER is not a host name or IP literal: '${nfs_server}'")
    is_valid_host_name "${smb_server}" \
        || configuration_problems+=("VALIDATOR_SMB_SERVER is not a host name or IP literal: '${smb_server}'")
    if [[ "${nfs_export_path}" != /* ]] || [[ "${nfs_export_path}" =~ [[:space:][:cntrl:]] ]]; then
        configuration_problems+=("VALIDATOR_NFS_EXPORT must be an absolute path with no whitespace or control characters: '${nfs_export_path}'")
    fi
    if { [[ "${http_endpoint_url}" != http://* ]] && [[ "${http_endpoint_url}" != https://* ]]; } \
            || [[ "${http_endpoint_url}" =~ [[:space:][:cntrl:]] ]]; then
        configuration_problems+=("VALIDATOR_HTTP_URL must start with http:// or https:// and contain no whitespace: '${http_endpoint_url}'")
    fi
    if ! [[ "${check_timeout_seconds}" =~ ^[1-9][0-9]{0,2}$ ]] || [ "${check_timeout_seconds}" -gt 300 ]; then
        configuration_problems+=("VALIDATOR_TIMEOUT must be a whole number of seconds from 1 to 300: '${check_timeout_seconds}'")
    fi
    if [ -z "${alert_recipients}" ] || [[ "${alert_recipients}" == -* ]] \
            || [[ "${alert_recipients}" =~ [[:cntrl:]] ]]; then
        configuration_problems+=("VALIDATOR_RECIPIENTS must be non-empty, must not start with -, and must contain no control characters")
    fi
    if [ -z "${smb_share_name}" ] || [[ "${smb_share_name}" == */* ]] \
            || [[ "${smb_share_name}" == *\\* ]] || [[ "${smb_share_name}" =~ [[:cntrl:]] ]]; then
        configuration_problems+=("VALIDATOR_SMB_SHARE must be a non-empty share name with no / or \\ or control characters")
    fi
    for enable_setting in \
            "VALIDATOR_ENABLE_ICMP=${enable_icmp_ping_check}" \
            "VALIDATOR_ENABLE_TCP_8080=${enable_tcp_port_8080_check}" \
            "VALIDATOR_ENABLE_TCP_25=${enable_tcp_port_25_check}" \
            "VALIDATOR_ENABLE_HTTP=${enable_http_endpoint_check}" \
            "VALIDATOR_ENABLE_SMTP=${enable_smtp_banner_check}" \
            "VALIDATOR_ENABLE_NFS=${enable_nfs_export_check}" \
            "VALIDATOR_ENABLE_NFS_MOUNT=${enable_nfs_mount_test}" \
            "VALIDATOR_ENABLE_SMB=${enable_smb_share_check}"; do
        enable_variable_name="${enable_setting%%=*}"
        enable_value="${enable_setting#*=}"
        if [ "${enable_value}" != "true" ] && [ "${enable_value}" != "false" ]; then
            configuration_problems+=("${enable_variable_name} must be exactly true or false: '${enable_value}'")
        fi
    done
    if [ "${#configuration_problems[@]}" -gt 0 ]; then
        printf 'FAIL: %s\n' "${configuration_problems[@]}" >&2
        return 1
    fi
    return 0
}

# required_commands
# Prints, one per line, every command the enabled checks need.
required_commands() {
    printf '%s\n' nc curl timeout flock date mktemp mv stat awk "${mail_command}"
    [ "${enable_icmp_ping_check}" = "true" ] && printf '%s\n' ping
    [ "${enable_nfs_export_check}" = "true" ] && printf '%s\n' showmount
    [ "${enable_nfs_export_check}" = "true" ] && [ "${enable_nfs_mount_test}" = "true" ] \
        && printf '%s\n' mount umount mountpoint ls rmdir
    [ "${enable_smb_share_check}" = "true" ] && printf '%s\n' smbclient
    return 0
}

# prepare_state_paths
# Creates the state directory with mode 0700 and refuses paths another
# account could use to redirect the tool's writes: a symlinked state
# directory, log file, or lock file, a state directory this account does
# not own, and a state directory writable by group or others.
prepare_state_paths() {
    local state_directory_mode
    if [ -L "${lock_file}" ]; then
        printf 'FAIL: lock file %s is a symlink\n' "${lock_file}" >&2
        return 1
    fi
    if [ -L "${log_file}" ]; then
        printf 'FAIL: log file %s is a symlink\n' "${log_file}" >&2
        return 1
    fi
    if [ -L "${state_directory}" ]; then
        printf 'FAIL: state directory %s is a symlink\n' "${state_directory}" >&2
        return 1
    fi
    if ! mkdir -p -m 700 "${state_directory}" 2> /dev/null || [ ! -d "${state_directory}" ]; then
        printf 'FAIL: cannot create state directory %s\n' "${state_directory}" >&2
        return 1
    fi
    if [ ! -O "${state_directory}" ]; then
        printf 'FAIL: state directory %s is not owned by the account running this tool\n' "${state_directory}" >&2
        return 1
    fi
    state_directory_mode="$(stat -c '%a' "${state_directory}")"
    if (( 8#${state_directory_mode} & 8#022 )); then
        printf 'FAIL: state directory %s is writable by group or others (mode %s)\n' \
            "${state_directory}" "${state_directory_mode}" >&2
        return 1
    fi
    return 0
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
    local undelivered_flag_file="${state_directory}/${check_name}.undelivered"
    local failure_count=0
    local state_usable="true"

    if state_file_is_safe "${failure_count_file}"; then
        failure_count="$(read_failure_count "${failure_count_file}")"
    else
        state_usable="false"
        report_state_error "cannot write state file ${failure_count_file}: it is a symlink or not a regular file"
    fi

    if [ "${exit_status}" -eq 0 ]; then
        if [ -f "${undelivered_flag_file}" ]; then
            pending_recovery_checks+=("${check_name}")
            pending_recovery_lines+=("${check_name}: recovered after ${failure_count} consecutive failed runs. The alert for this incident was never delivered.")
        elif [ -f "${alerted_flag_file}" ]; then
            pending_recovery_checks+=("${check_name}")
            pending_recovery_lines+=("${check_name}: recovered after ${failure_count} consecutive failed runs.")
        fi
        log_message "PASS ${check_name}: ${detail_text}"
        # A failed reset is already reported, and main exits 2 for it.
        if [ "${state_usable}" = "true" ]; then
            write_failure_count "${failure_count_file}" 0 || return 0
        fi
        return 0
    fi

    any_check_failed="true"
    failure_count=$((failure_count + 1))
    log_message "FAIL ${check_name} (consecutive failure ${failure_count}/${failure_threshold}): ${detail_text}"

    # A new incident starts unalerted. Flags an earlier incident left
    # behind, for example after a recovery notice that was never sent,
    # are cleared here so they cannot suppress this incident's alert.
    if [ "${state_usable}" = "true" ] && [ "${failure_count}" -eq 1 ]; then
        if ! remove_state_file "${alerted_flag_file}" || ! remove_state_file "${undelivered_flag_file}"; then
            state_usable="false"
        fi
    fi
    if [ "${state_usable}" = "true" ] && ! write_failure_count "${failure_count_file}" "${failure_count}"; then
        state_usable="false"
    fi

    # Without usable state the threshold is never reached reliably, so
    # the alert is raised now, on every failed run, whatever the count
    # and whatever the alerted flag says, until the state is fixed.
    if [ "${state_usable}" = "false" ]; then
        pending_alert_checks+=("${check_name}")
        pending_alert_lines+=("${check_name}: failed, and its state in ${state_directory} cannot be written, so consecutive failures cannot be counted. This alert repeats on every failed run until that is fixed. Last detail: ${detail_text}")
        return 0
    fi

    if [ "${failure_count}" -ge "${failure_threshold}" ] && [ ! -f "${alerted_flag_file}" ]; then
        pending_alert_checks+=("${check_name}")
        pending_alert_lines+=("${check_name}: ${failure_count} consecutive failed runs. Last detail: ${detail_text}")
    fi
    return 0
}

# send_notification_email <subject> <body>
# Returns nonzero when the message was not handed off successfully.
# Success means the local mail command accepted the message, not that
# it reached a mailbox.
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
# Sends the queued alert and recovery messages and marks state only on
# success. A failed alert leaves the check unalerted, so the next failed
# run tries again, and writes an undelivered flag, so a recovery before
# then says the alert never arrived. Undelivered content goes to stderr.
# Returns nonzero when any message was not sent or any flag could not be
# written or removed.
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
                create_state_flag "${state_directory}/${check_name}.alerted" || dispatch_status=1
                remove_state_file "${state_directory}/${check_name}.undelivered" || dispatch_status=1
            done
        else
            printf 'ALERT UNDELIVERED (will retry on the next failed run):\n%s\n' "${alert_body}" >&2
            dispatch_status=1
            for check_name in "${pending_alert_checks[@]}"; do
                create_state_flag "${state_directory}/${check_name}.undelivered" || dispatch_status=1
            done
        fi
    fi

    if [ "${#pending_recovery_lines[@]}" -gt 0 ]; then
        local recovery_body
        recovery_body="Recovered checks for ${target_host} at $(date --iso-8601=seconds):"$'\n\n'
        recovery_body+="$(printf '%s\n' "${pending_recovery_lines[@]}")"
        if send_notification_email "RECOVERED: connectivity restored on ${target_host}" "${recovery_body}"; then
            for check_name in "${pending_recovery_checks[@]}"; do
                remove_state_file "${state_directory}/${check_name}.alerted" || dispatch_status=1
                remove_state_file "${state_directory}/${check_name}.undelivered" || dispatch_status=1
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
    # The target host reaches the inner bash as a positional argument,
    # never as part of its source text, so the host cannot run as code.
    # shellcheck disable=SC2016
    smtp_banner_line="$(timeout "${check_timeout_seconds}" bash -c \
        'exec 3<>"/dev/tcp/${1}/25" && head -n 1 <&3' \
        smtp_banner_probe "${target_host}" 2> /dev/null)"
    if [ "${smtp_banner_line:0:3}" = "220" ]; then
        printf 'SMTP banner received: %s' "${smtp_banner_line%%$'\r'}"
        return 0
    fi
    printf 'No valid SMTP 220 banner from %s:25 (received: %s)' \
        "${target_host}" "${smtp_banner_line:-nothing}"
    return 1
}

# run_bounded <command...>
# Runs one step of the mount test under the check timeout, then SIGKILL
# after kill_after_seconds more. Exit status 124 or 137 means it was cut
# off.
run_bounded() {
    timeout --kill-after="${kill_after_seconds}" "${check_timeout_seconds}" "$@"
}

check_nfs_export() {
    local advertised_exports
    local wanted_export="${nfs_export_path}"
    local nfs_mount_source
    # The export list is captured first, so an unreachable mountd and a
    # missing export give different details. The export is then compared
    # with the first column of each line after removing a trailing
    # carriage return and trailing slashes on both sides, so /export/data
    # and /export/data/ are the same export, while /export/database,
    # /export/data2, and a client list that happens to contain the path
    # never match. The header line cannot match, because a configured
    # export always starts with /.
    while [ "${#wanted_export}" -gt 1 ] && [ "${wanted_export%/}" != "${wanted_export}" ]; do
        wanted_export="${wanted_export%/}"
    done
    if ! advertised_exports="$(timeout "${check_timeout_seconds}" showmount -e "${nfs_server}" 2> /dev/null)"; then
        printf 'Export list from %s unavailable (mountd unreachable or showmount failed)' \
            "${nfs_server}"
        return 1
    fi
    # The awk program is kept on one line so the project page's copy,
    # which ends each statement line with a semicolon, stays valid.
    if ! printf '%s\n' "${advertised_exports}" \
            | wanted_export="${wanted_export}" awk '{ sub(/\r$/, ""); advertised = $1; while (length(advertised) > 1 && substr(advertised, length(advertised)) == "/") { advertised = substr(advertised, 1, length(advertised) - 1) }; if (advertised == ENVIRON["wanted_export"]) { found = 1 } } END { exit (found ? 0 : 1) }'; then
        printf 'Export %s not advertised by %s' "${nfs_export_path}" "${nfs_server}"
        return 1
    fi
    if [ "${enable_nfs_mount_test}" != "true" ]; then
        printf 'Export %s advertised by %s (control plane only)' \
            "${nfs_export_path}" "${nfs_server}"
        return 0
    fi

    # An IPv6 server must be bracketed in an NFS mount source.
    if [[ "${nfs_server}" == *:* ]]; then
        nfs_mount_source="[${nfs_server}]:${nfs_export_path}"
    else
        nfs_mount_source="${nfs_server}:${nfs_export_path}"
    fi
    local temporary_mount_directory
    local mount_succeeded="false"
    local directory_mounted="false"
    local read_succeeded="false"
    local cleanup_problem=""
    # The mount point is created inside the state directory, which only
    # this account can write, never under TMPDIR, where another account
    # could rename or replace it before the mount.
    if ! temporary_mount_directory="$(mktemp -d "${state_directory}/mount.XXXXXX" 2> /dev/null)"; then
        printf 'Export %s mount test could not create a temporary directory' "${nfs_export_path}"
        return 1
    fi
    if run_bounded mount -t nfs -o ro,soft,timeo=30,retrans=2 \
            "${nfs_mount_source}" "${temporary_mount_directory}" 2> /dev/null; then
        mount_succeeded="true"
    fi
    # The mount table, not the mount command's exit status, decides what
    # needs unmounting: a mount command can fail after attaching a mount.
    if [ "${mount_succeeded}" = "true" ] || mountpoint -q "${temporary_mount_directory}" 2> /dev/null; then
        directory_mounted="true"
    fi
    if [ "${mount_succeeded}" = "true" ] && run_bounded ls "${temporary_mount_directory}" > /dev/null 2>&1; then
        read_succeeded="true"
    fi
    # Cleanup counts in the result. Every step has a deadline. A mount
    # that is still in the mount table after cleanup fails the check and
    # names the directory, even when the read worked, and the directory
    # is removed only once the mount table no longer lists it.
    if [ "${directory_mounted}" = "true" ]; then
        if ! run_bounded umount "${temporary_mount_directory}" 2> /dev/null; then
            cleanup_problem="umount failed or timed out"
        fi
        if mountpoint -q "${temporary_mount_directory}" 2> /dev/null; then
            cleanup_problem="${cleanup_problem:-umount reported success but}${cleanup_problem:+,} ${temporary_mount_directory} is still mounted"
        fi
    fi
    if [ -z "${cleanup_problem}" ] && ! rmdir "${temporary_mount_directory}" 2> /dev/null; then
        cleanup_problem="rmdir ${temporary_mount_directory} failed"
    fi
    if [ -n "${cleanup_problem}" ]; then
        printf 'Export %s mount test cleanup failed: %s' "${nfs_export_path}" "${cleanup_problem}"
        return 1
    fi
    if [ "${read_succeeded}" = "true" ]; then
        printf 'Export %s mounted and read successfully' "${nfs_export_path}"
        return 0
    fi
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
    local notification_failed="false"

    # Files and directories this run creates are private to its account.
    umask 077

    if ! validate_configuration; then
        return 2
    fi

    while IFS= read -r required_command; do
        command -v "${required_command}" > /dev/null 2>&1 \
            || missing_commands+=("${required_command}")
    done < <(required_commands)
    if [ "${#missing_commands[@]}" -gt 0 ]; then
        printf 'FAIL: missing required command(s): %s\n' "${missing_commands[*]}" >&2
        return 2
    fi

    if ! printf '%s' "${failure_threshold}" | grep -qE '^[1-9][0-9]{0,8}$'; then
        printf 'FAIL: failure threshold must be a whole number from 1 to 999999999, got: %s\n' \
            "${failure_threshold}" >&2
        return 2
    fi

    if ! prepare_state_paths; then
        return 2
    fi

    mkdir -p "$(dirname "${lock_file}")" 2>/dev/null
    # Opened for append, so the lock file is never truncated.
    if ! exec 200>>"${lock_file}"; then
        printf 'FAIL: cannot open lock file %s\n' "${lock_file}" >&2
        return 2
    fi
    if ! flock -n 200; then
        log_message "Another run holds the lock; no check ran."
        printf 'FAIL: another run holds the lock %s; no check ran\n' "${lock_file}" >&2
        return 2
    fi

    run_enabled_check "${enable_icmp_ping_check}"     "icmp_ping"     check_icmp_ping
    run_enabled_check "${enable_tcp_port_8080_check}" "tcp_port_8080" check_tcp_port 8080
    run_enabled_check "${enable_tcp_port_25_check}"   "tcp_port_25"   check_tcp_port 25
    run_enabled_check "${enable_http_endpoint_check}" "http_endpoint" check_http_endpoint
    run_enabled_check "${enable_smtp_banner_check}"   "smtp_banner"   check_smtp_banner
    run_enabled_check "${enable_nfs_export_check}"    "nfs_export"    check_nfs_export
    run_enabled_check "${enable_smb_share_check}"     "smb_share"     check_smb_share

    if ! dispatch_pending_alerts; then
        notification_failed="true"
    fi

    if [ "${state_write_failed}" = "true" ]; then
        printf 'FAIL: cannot keep state in %s; see the errors above\n' \
            "${state_directory}" >&2
        return 2
    fi
    if [ "${notification_failed}" = "true" ]; then
        printf 'FAIL: one or more notifications were not sent; see the messages above\n' >&2
        return 2
    fi
    [ "${any_check_failed}" = "true" ] && return 1
    return 0
}

if [ "${VALIDATOR_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
    exit $?
fi
