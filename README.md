# server-connectivity-validator

![ci](https://github.com/revisualize/server-connectivity-validator/actions/workflows/ci.yml/badge.svg)

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
| `nfs_export` | Storage control plane, optionally data plane | `showmount`, optional real read-only mount |
| `smb_share` | Storage data plane | `smbclient` with a credentials file |

Each check is independently enabled and keeps its own consecutive-failure counter.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Every enabled check passed |
| 1 | One or more checks failed |
| 2 | Configuration, dependency, lock, or state directory error |

## Alerting behaviour

**The threshold counts consecutive runs, not failures within one run.** A single blip during a switch failover does not page anyone. Three consecutive cycles of failure does. The tradeoff is real and worth stating: detection latency is threshold times cron interval, so 3 x 5 minutes means up to 15 minutes before the first email.

**One alert per incident, then quiet until recovery.** Without this, a weekend outage generates hundreds of identical emails and the distribution list learns to filter the sender, which is how monitoring dies.

**The alerted flag is written only after delivery succeeds.** This is the correctness point that matters most in the whole tool. Marking a check "alerted" at the moment the alert is queued means a single failed send silences that check for the entire remainder of the outage: the alert never arrived, and the tool will never try again. Delivery is confirmed first, the flag is written second, and an undelivered alert goes to stderr and stays queued for the next run.

**The alert path must not depend on the thing being monitored.** If port 25 on the target is the same relay this script uses to send mail, the alert fails precisely when it is needed. Deployment requirement, not suggestion: the monitoring host must relay through something other than the monitored server, or run a local queue.

## Configuration

Every setting is an environment variable.

| Variable | Default |
|----------|---------|
| `VALIDATOR_TARGET_HOST` | `storage01.example.net` |
| `VALIDATOR_HTTP_URL` | `http://storage01.example.net:8080/health` |
| `VALIDATOR_NFS_SERVER` / `VALIDATOR_NFS_EXPORT` | `storage01.example.net` / `/ifs/data/export` |
| `VALIDATOR_SMB_SERVER` / `VALIDATOR_SMB_SHARE` | `storage01.example.net` / `data` |
| `VALIDATOR_FAILURE_THRESHOLD` | `3` |
| `VALIDATOR_TIMEOUT` | `5` |
| `VALIDATOR_RECIPIENTS` | `storage-alerts@example.net` |
| `VALIDATOR_STATE_DIR` | `/var/lib/server_connectivity_validator` |
| `VALIDATOR_MAIL_COMMAND` | `mail` |
| `VALIDATOR_ENABLE_ICMP` and friends | `true`, except `VALIDATOR_ENABLE_NFS_MOUNT` |

ICMP is a real check, but expect to disable it in filtered networks. Plenty of environments drop echo requests by policy, and a ping check there produces permanent false failure.

## Known limitations

- The network-facing checks require real infrastructure and are not covered by the test suite. The state machine, alert dispatch, and result recording are. Shake the checks down in a lab before trusting them.
- After the single alert, a persistently broken check is silent until recovery. A configurable re-alert interval is the first roadmap item; until it lands this is a known limitation, not an oversight.
- The NFS mount test requires root and touches kernel mount state, which is why it is a separate flag, off by default. The test mount is read-only, soft, and bounded, because a validator that can hang forever on a dead server is strictly worse than no validator.
- The SMTP banner check uses bash's `/dev/tcp`, which is a bash builtin feature and is unavailable under dash or ash.

## Requirements

Bash 4.2 or newer, GNU coreutils, `nc`, `curl`, `timeout`, `flock`. `showmount` for the NFS check, `smbclient` for the SMB check.

## Tests

```sh
bats test/
```

## License

See [LICENSE](LICENSE). This code is published for viewing as a sample of the author's work. All rights reserved.
