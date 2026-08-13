# Changelog

## 2.0.0 — 2026-08-13

Rewrite after a full security and reliability audit of the original
one-shot script.

### Security

- Consent and sudo now always use `/dev/tty`, so `curl | bash` can no
  longer skip the warning banner.
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
