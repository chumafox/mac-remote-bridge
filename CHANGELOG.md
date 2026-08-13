# Changelog

## 2.1.1 — 2026-08-13

Audit pass: lock cleanup hardening, CLI help accuracy, and combined target test.

### Security & Reliability

- `release_start_lock` is now ownership-aware (checks PID in `lock.d/pid` matches `$$`). A delayed `EXIT` trap from a long `--foreground` run can no longer clear a newer concurrent `start` process's lock.
- `cmd_start` registers an `EXIT` trap for `release_start_lock` immediately after acquiring the lock, so premature `die()` exits (such as SSH failure or prompt cancel) do not leave stale `lock.d` directories behind.
- Added combined `--token` + `--allow-ip` test case to `__selftest`.

### UX & Documentation

- Clarified `--no-vnc` help and `README.md` wording (skips the VNC prompt and leaves Screen Sharing off).

## 2.1.0 — 2026-08-13

Audit pass: fix behaviour that contradicted the docs, harden parsers,
and keep README / SECURITY / `--help` in sync with the script.

### Security

- VNC commands are printed only when Screen Sharing is actually on.
  The card no longer advertises desktop access we did not enable.
- `--allow-ip` is a real IPv4/CIDR check (not a character-class filter).
- Parsed broker hostnames are restricted to `[A-Za-z0-9._-]`.
- `persist_self` no longer silently re-fetches `bridge.sh` from GitHub.
  It copies the running file, or `BASH_EXECUTION_STRING` for
  `bash -c "$(curl …)"`. Last resort is a local stop/status/logs/revert
  stub, never a second network download.
- `kickstart` no longer runs `-configure -access -on` (that is ARD
  access, not Screen Sharing).
- Users we added to `com.apple.access_ssh` are removed on `revert`.
- Notification text is AppleScript-escaped.
- `--yes` is documented as a footgun next to `curl | bash`.

### Reliability

- Supervisor and parent share one parser (`declare -f`). “Allocated
  port” no longer hardcodes `a.pinggy.io` when `PINGGY_HOST` is custom.
- `LogLevel=INFO` so OpenSSH’s “Allocated port” line is visible.
- Reconnects keep retrying with exponential backoff while the run file
  exists, instead of exiting after three failures.
- Log parse uses only the last `----` session block, so a reconnect
  cannot reuse a stale `tcp://` URL.
- Concurrent `start` is serialised with a directory lock.
- `disable_remote_login` has the same launchctl fallbacks as enable.
- Foreground mode now fails if the supervisor exits non-zero.
- `umask` is restored after writing `supervise.sh`.

### UX

- `revert` no longer prints “No active session” after it just stopped
  a tunnel that had not enabled SSH/VNC.
- `status` shows the last host:port when the session is stale/stopped.
- `status --json` includes `vnc` and emits `null` for missing numbers.
- `--lang` accepts only `en` / `ru`. `--help` always wins over `start`.
- Banner stop command is `~/.mac-remote-bridge/bridge.sh stop`.
  `pkill -f pinggy` remains a last resort in `--help` only.
- Documented `--no-vnc`, `-q`, `-V`, `MRB_LANG`, `NO_COLOR`.

### Tests / docs

- `__selftest` covers allow-list / hostname validation, last-block
  parse, custom broker fallback, and supervisor embedding.
- `scripts/check.sh` runs `bash -n`, `__selftest`, and a docs/version
  consistency check (the same assertions a CI job would run).
- README, SECURITY.md, and CHANGELOG agree with the 2.1.0 behaviour.

## 2.0.0 — 2026-08-13

Rewrite after a full security and reliability audit of the original
one-shot script.

### Security

- Consent and sudo now always use `/dev/tty`, so `curl | bash` can no
  longer skip the warning banner (without `--yes`).
- Replaced `StrictHostKeyChecking=no` with `accept-new` and a
  per-session known_hosts file.
- Broker SSH is launched with `-F /dev/null` and without the user agent
  or pubkey identities.
- Screen Sharing is opt-in (`--vnc`); we no longer claim desktop access
  we did not enable.
- Session files live in `~/.mac-remote-bridge/` with mode `0700`.
- `--allow-ip` can pin the broker to the operator's IPv4/CIDR.
- `stop` kills recorded PIDs only; `pkill -f pinggy` remains documented
  as a last resort.
- `revert` turns off SSH/VNC if *this* tool was the one that enabled them.
- LICENSE restored to unmodified MIT (the previous text was not valid MIT).

### Reliability

- Official Pinggy TCP target: `tcp@free.pinggy.io`.
- Keepalives, `ExitOnForwardFailure`, and a supervisor that restarts a
  dropped tunnel and rewrites the session file.
- Closing Terminal no longer kills the session (`nohup` + ignore `SIGHUP`).
- Port/URL parsing polls the log instead of a fixed `sleep 4`.
- Remote Login enablement falls back through `systemsetup`, `launchctl`,
  and `com.apple.access_ssh` ACL repair.
- `start` is a no-op if a healthy session is already running (`--force`
  to replace).

### UX

- Real CLI: `start`, `stop`, `status`, `logs`, `revert`, `doctor`.
- Bilingual UI (`en` / `ru`), auto-detected from the locale.
- Clipboard copy (`pbcopy`) and a Notification Center banner.
- `--json` status, `--foreground`, `--token`, `--yes`.
- `doctor` reports sshd/VNC, FileVault, ACL, and Pinggy reachability.
- `__selftest` covers parsers and target construction (Linux-safe).

## 1.0.0 — 2026-08-13

Initial one-shot Russian script: enable Remote Login, open a Pinggy
tunnel, print SSH/VNC commands.
