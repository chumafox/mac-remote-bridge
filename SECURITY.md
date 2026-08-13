# Security policy

`mac-remote-bridge` turns a Mac into a temporarily reachable SSH (and
optionally VNC) host by opening an **outbound** reverse tunnel. That is
powerful and easy to misuse. Please read this before running the script,
especially via `curl | bash`.

## What the script actually does

1. Asks for explicit consent on `/dev/tty` (the real keyboard). Piped
   stdin — including the `curl | bash` pipe — is **never** treated as
   agreement. `--yes` skips this prompt; do not pass it on a one-liner
   you have not read.
2. Enables macOS **Remote Login** (sshd on port 22) only if it is not
   already listening. sudo is skipped when SSH is already on *and*
   the current user is already allowed to log in (or the ACL group
   does not exist). If the account is missing from
   `com.apple.access_ssh`, sudo is used once to add it.
3. Optionally enables **Screen Sharing** (VNC on port 5900). This is
   off unless you pass `--vnc` or answer yes to the prompt. The printed
   card shows a VNC command only when Screen Sharing is on.
4. Starts `ssh -R0:127.0.0.1:22` to Pinggy on port 443 (via a
   supervisor) and prints the public host/port for the operator.
5. Records PIDs under `~/.mac-remote-bridge/` (mode `0700`) so `stop`
   kills *this* session only.
6. Persists a local copy of **the bytes that just ran**
   (`~/.mac-remote-bridge/bridge.sh`). It does not re-download the
   script from GitHub afterwards.

It does **not** install binaries, open inbound firewall ports, create
users, weaken the login password, or enable full Apple Remote Desktop
privileges.

## Trust boundary

Anyone who can reach the printed host:port **and** authenticate as a
macOS user on this machine gets a shell. The tunnel broker (Pinggy)
can also see connection metadata and, on the free tier, the public
TCP endpoint. Treat that host:port like a temporary secret.

A Pinggy token, if you use one, appears in the broker SSH username
(and therefore in `ps`). The session file is mode `0600`.

Mitigations you should actually use:

- Prefer `--allow-ip 203.0.113.10` (operator's public IPv4) so the
  broker drops everyone else.
- Use a Pinggy Pro token (`--token` / `PINGGY_TOKEN`) for a stable
  endpoint you control, and rotate it if it leaks.
- Stop the session when the job is done: `~/.mac-remote-bridge/bridge.sh stop`.
- If this tool turned SSH/VNC on, or added you to
  `com.apple.access_ssh`, undo that:
  `~/.mac-remote-bridge/bridge.sh revert`.

First-connect host-key checking is TOFU (`accept-new` into
`~/.mac-remote-bridge/known_hosts`). A MITM on the very first broker
connection would be trusted later; later changes are rejected.

Short links (for example `clck.ru`) can be retargeted by whoever
controls the alias. Prefer the raw GitHub URL and read the file.

## What we fixed relative to v1

| Issue | v1 | v2 / v2.1 |
| --- | --- | --- |
| Consent under `curl \| bash` | Skipped (`[ -t 0 ]` is false on a pipe) | Always read `/dev/tty` (`--yes` is explicit) |
| sudo under `curl \| bash` | stdin is the script pipe | `sudo -v </dev/tty` |
| `StrictHostKeyChecking=no` | MITM on the broker | `accept-new` + isolated known_hosts |
| User `~/.ssh/config` | Could inject ProxyJump / keys | `ssh -F /dev/null` |
| Agent identities | "Too many authentication failures" | pubkey/agent disabled for the broker |
| Tunnel dies on Terminal close | no `nohup` / `disown` | supervisor ignores `SIGHUP` |
| `pkill -f pinggy` | Kills unrelated processes | PID files (`pkill` is last-resort only) |
| VNC advertised | Never enabled Screen Sharing | Opt-in `--vnc`; card hides VNC otherwise |
| `sleep 4` race | Port often missing | Poll the log up to ~24s |
| HTTP vs TCP tunnel | `a.pinggy.io` without `tcp@` | Official `tcp@free.pinggy.io` |
| SSH ACL | Ignored `com.apple.access_ssh` | Adds the current user if needed; `revert` removes them |
| Silent self-update | n/a | Persist the running bytes; never re-curl `main` |
| ARD privileges | kickstart `-access -on` in some trees | launchctl Screen Sharing only |
| Allow-list / host parse | loose character class | IPv4/CIDR + hostname charset checks |

## Reporting a vulnerability

Please use a
[private GitHub security advisory](https://github.com/chumafox/mac-remote-bridge/security/advisories/new).
Do **not** file a public issue for anything that would make it easier
to hijack a live assistance session.
