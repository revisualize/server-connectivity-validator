# server-connectivity-validator

[![ci](https://github.com/revisualize/server-connectivity-validator/actions/workflows/ci.yml/badge.svg)](https://github.com/revisualize/server-connectivity-validator/actions/workflows/ci.yml)
[![test](https://github.com/revisualize/server-connectivity-validator/actions/workflows/test.yml/badge.svg)](https://github.com/revisualize/server-connectivity-validator/actions/workflows/test.yml)
[![shellcheck](https://github.com/revisualize/server-connectivity-validator/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/revisualize/server-connectivity-validator/actions/workflows/shellcheck.yml)
[![bash-compat](https://github.com/revisualize/server-connectivity-validator/actions/workflows/bash-compat.yml/badge.svg)](https://github.com/revisualize/server-connectivity-validator/actions/workflows/bash-compat.yml)
[![markdown-lint](https://github.com/revisualize/server-connectivity-validator/actions/workflows/markdown-lint.yml/badge.svg)](https://github.com/revisualize/server-connectivity-validator/actions/workflows/markdown-lint.yml)
[![links](https://github.com/revisualize/server-connectivity-validator/actions/workflows/links.yml/badge.svg)](https://github.com/revisualize/server-connectivity-validator/actions/workflows/links.yml)
[![content-policy](https://github.com/revisualize/server-connectivity-validator/actions/workflows/content-policy.yml/badge.svg)](https://github.com/revisualize/server-connectivity-validator/actions/workflows/content-policy.yml)
[![license: all rights reserved](https://img.shields.io/badge/license-all%20rights%20reserved-lightgrey)](LICENSE)

**Project page:** [revisualized.com/projects/server-connectivity-validator](https://revisualized.com/projects/server-connectivity-validator)

"Is the server up" is several different questions wearing one trenchcoat. A host can answer ping while its application port is firewalled, accept TCP connections while the application behind them is hung, export an NFS path no client can mount, and advertise an SMB share that rejects every authentication.

This validator tests the whole ladder, in order, so a failure arrives pre-localized. Which layer broke is already known before anyone opens a terminal.

## The ladder

| Check | Layer | Tool |
|-------|-------|------|
| `icmp_ping` | Reachability | `ping` |
| `tcp_port_8080` | Transport | `nc` |
| `tcp_port_25` | Transport | `nc` |
| `http_endpoint` | Application | `curl --fail`, so a 5xx counts as failure |
| `smtp_banner` | Application | Requires a `220` greeting, catching the accepts-but-hung mail daemon |
| `nfs_export` | Storage control plane, optionally data plane | `showmount`, with the export matched exactly against the export column (a trailing slash or carriage return is ignored); optional real read-only mount, where mount, read, and unmount each have a deadline and cleanup counts in the result |
| `smb_share` | Storage data plane | `smbclient` with a credentials file |

Each check is independently enabled and keeps its own consecutive-failure counter.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Every enabled check ran and passed, and every notification was sent |
| 1 | One or more checks failed |
| 2 | Configuration, dependency, lock, state directory, or notification delivery error. This includes another run still holding the lock, in which case no check ran. Code 2 outranks code 1 |

## Alerting behaviour

**The threshold counts consecutive runs, not failures within one run.** A single blip during a switch failover does not page anyone. Three consecutive cycles of failure does. The tradeoff is real and worth stating: detection latency is threshold times cron interval, so at the defaults the first email goes out about 15 minutes (3 x 5) after the outage starts. A slow run, a skipped run, or a failed notification makes it later.

**One alert per incident, then quiet until recovery, while the tool can keep its state.** A new incident always starts unalerted. Without this, a weekend outage generates hundreds of identical emails and the distribution list learns to filter the sender, which is how monitoring dies.

**The alerted flag is written only after delivery succeeds.** This is the correctness point that matters most in the whole tool. Marking a check "alerted" at the moment the alert is queued means a single failed send silences that check for the entire remainder of the outage: the alert never arrived, and the tool will never try again. The local mail command must accept the message first, and the flag is written second. An undelivered alert goes to stderr, the next failed run sends it again, and if the check recovers before that, the recovery notice says the alert was never delivered. Any notification that is not sent makes the run exit 2.

**The alert path must not depend on the thing being monitored.** If port 25 on the target is the same relay this script uses to send mail, the alert fails precisely when it is needed. Deployment requirement, not suggestion: the monitoring host must relay through something other than the monitored server, or run a local queue.

**State that cannot be kept is reported, not silent.** If a check's counter or flag cannot be written, or is a symlink or anything other than a regular file, its consecutive failures cannot be counted reliably. The tool prints the problem on stderr, attempts to log it, raises an alert on every failed run of that check until the state directory is fixed, overriding the one-alert rule, and exits 2. Counters are written to a new file and renamed into place, so a symlink planted in the state directory is replaced, never followed.

## Configuration

Every setting is an environment variable.

| Variable | Default |
|----------|---------|
| `VALIDATOR_TARGET_HOST` | `storage01.example.net` |
| `VALIDATOR_HTTP_URL` | `http://storage01.example.net:8080/health` |
| `VALIDATOR_NFS_SERVER` / `VALIDATOR_NFS_EXPORT` | `storage01.example.net` / `/export/data` |
| `VALIDATOR_SMB_SERVER` / `VALIDATOR_SMB_SHARE` | `storage01.example.net` / `data` |
| `VALIDATOR_SMB_CREDENTIALS` | `/etc/server_connectivity_validator/smb_credentials` |
| `VALIDATOR_FAILURE_THRESHOLD` | `3` |
| `VALIDATOR_TIMEOUT` | `5` (whole seconds, 1 to 300) |
| `VALIDATOR_RECIPIENTS` | `storage-alerts@example.net` |
| `VALIDATOR_STATE_DIR` | `/var/lib/server_connectivity_validator` |
| `VALIDATOR_LOG_FILE` | `/var/log/server_connectivity_validator.log` |
| `VALIDATOR_LOCK_FILE` | `/var/lock/server_connectivity_validator.lock` |
| `VALIDATOR_MAIL_COMMAND` | `mail` |
| `VALIDATOR_ENABLE_ICMP`, `_TCP_8080`, `_TCP_25`, `_HTTP`, `_SMTP`, `_NFS`, `_NFS_MOUNT`, `_SMB` | `true`, except `VALIDATOR_ENABLE_NFS_MOUNT`, which is `false` |

These settings are checked before any check runs, whether or not the check that uses them is enabled, and a bad value exits 2 with one line per problem, before the lock is taken:

- `VALIDATOR_TARGET_HOST`, `VALIDATOR_NFS_SERVER`, `VALIDATOR_SMB_SERVER`: an IPv4 address, an IPv6 address, or a host name of labels made of letters, digits, hyphens, and underscores (underscores are accepted on purpose for private resolvers, although strict host name rules exclude them).
- `VALIDATOR_NFS_EXPORT`: an absolute path with no whitespace or control characters.
- `VALIDATOR_HTTP_URL`: starts with `http://` or `https://`, with no whitespace.
- `VALIDATOR_TIMEOUT`: a whole number of seconds from 1 to 300.
- `VALIDATOR_RECIPIENTS`: not empty, not starting with `-`, no control characters.
- `VALIDATOR_SMB_SHARE`: not empty, no `/`, `\`, or control characters.
- Every `VALIDATOR_ENABLE_*`: exactly `true` or `false`.

The tool also refuses to start if the state directory, log file, or lock file is a symlink, or if the state directory is not owned by the account running the tool or is writable by group or others. It creates the state directory with mode 0700. A missing command needed by an enabled check exits 2 before any check runs.

The mail command, the SMB credentials file, and the state, log, and lock locations are trusted settings: whoever sets them already chooses what the tool runs and where it writes, so the tool does not validate them further.

ICMP is a real check, but expect to disable it in filtered networks. Plenty of environments drop echo requests by policy, and a ping check there produces permanent false failure.

## Known limitations

- No check is tested against a real server. The test suite covers the state machine, alert dispatch, result recording, the configuration and state path checks, hostile input to the SMTP check, and the NFS check's export matching, deadlines, and mount cleanup, all with stub commands. Shake the checks down in a lab before trusting them.
- With working state, a persistently broken check is silent after its single alert until recovery. A configurable re-alert interval is the first roadmap item; until it lands this is a known limitation, not an oversight.
- The NFS mount test requires root and touches kernel mount state, which is why it is a separate flag, off by default. The test mount is read-only and soft, and the mount, the read, and the unmount each get `VALIDATOR_TIMEOUT` seconds, then a kill 5 seconds later. A process stuck in an uninterruptible kernel wait on a dead server can outlive both; the run then keeps the lock, and every later run exits 2 saying another run holds it.
- The SMTP banner check uses bash's `/dev/tcp`, which is a bash builtin feature and is unavailable under dash or ash.

## Requirements

Bash 4.2 or newer, GNU coreutils, `awk`, `nc`, `curl`, `flock`, and a mail command. `ping` for the ICMP check, `showmount` for the NFS check, `mount`, `umount`, and `mountpoint` (util-linux) plus root for the NFS mount test, `smbclient` for the SMB check.

## Tests

```sh
bats test/
```

## Continuous integration

Each badge above is its own GitHub Actions workflow in `.github/workflows/`. Every workflow runs on each push and pull request, can be re-run by hand from the Actions tab, and links to its run history.

| Workflow | A green badge means |
|---|---|
| [`ci`](https://github.com/revisualize/server-connectivity-validator/actions/workflows/ci.yml) | `bash test/run_all_tests.sh` passed in both jobs of the shared workflow matrix (Python 3.9 and 3.12; this tool itself uses no Python) and reported a non-zero count of executed tests, and shellcheck found nothing at style severity. |
| [`test`](https://github.com/revisualize/server-connectivity-validator/actions/workflows/test.yml) | `bash test/run_all_tests.sh` passed in both jobs of the shared workflow matrix (Python 3.9 and 3.12; this tool itself uses no Python). The run fails if any suite fails or if zero tests executed, and the job summary lists each suite with its test count. |
| [`shellcheck`](https://github.com/revisualize/server-connectivity-validator/actions/workflows/shellcheck.yml) | Every shell script outside `test/fixtures/` parses with `bash -n` and has no shellcheck findings at style severity. |
| [`bash-compat`](https://github.com/revisualize/server-connectivity-validator/actions/workflows/bash-compat.yml) | The test suite passed under every Bash release from the floor stated in Requirements through 5.3, each built from its release source. |
| [`markdown-lint`](https://github.com/revisualize/server-connectivity-validator/actions/workflows/markdown-lint.yml) | Every Markdown file passes markdownlint. |
| [`links`](https://github.com/revisualize/server-connectivity-validator/actions/workflows/links.yml) | Every link in every Markdown file resolved on the latest run. It also runs weekly, because a link can break with no commit here. |
| [`content-policy`](https://github.com/revisualize/server-connectivity-validator/actions/workflows/content-policy.yml) | Every tracked file meets the publishing rules: UTF-8, LF line endings, no em dashes, scripts documented as `bash name.sh`, and vendor-neutral wording. |

A badge reports the latest run of those checks. What the tool needs on your own host is listed under Requirements.

## License

See [LICENSE](LICENSE). All rights reserved.
