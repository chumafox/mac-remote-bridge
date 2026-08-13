# Security policy

`mac-remote-bridge` turns a Mac into a temporarily reachable SSH (and
optionally VNC) host by opening an **outbound** reverse tunnel. That is
powerful and easy to misuse. Please read this before running the script,
especially via `curl | bash`.

## What the script actually does

1. Asks for explicit consent on `/dev/tty` (the real keyboard). Piped
   stdin — including the `curl | bash` pipe — is **never** treated as
   agreement.
2. Enables macOS **Remote Login** (sshd on port 22) only if it is not
   already listening. sudo is skipped when SSH is already on.
3. Optionally enables **Screen Sharing** (VNC on port 5900). This is
   off unless you pass `--vnc` or answer yes to the prompt.
4. Starts `ssh -R0:127.0.0.1:22` to Pinggy on port 443 and prints the
   public host/port for the operator.
5. Records PIDs under `~/.mac-remote-bridge/` (mode `0700`) so `stop`
   kills *this* session only.

It does **not** install binaries, open inbound firewall ports, create
users, weaken the login password, or enable full Apple Remote Desktop
privileges.

## Trust boundary

Anyone who can reach the printed host:port **and** authenticate as a
macOS user on this machine gets a shell. The tunnel broker (Pinggy)
can also see connection metadata. A free-tier URL is random, but it is
still a capability: treat it like a temporary secret.

Mitigations you should actually use:

- Prefer `--allow-ip 203.0.113.10` (operator's public IPv4) so the
  broker drops everyone else.
- Use a Pinggy Pro token (`--token` / `PINGGY_TOKEN`) for a stable
  endpoint you control, and rotate it if it leaks.
- Stop the session when the job is done: `~/.mac-remote-bridge/bridge.sh stop`.
- If this tool turned SSH/VNC on, turn them back off:
  `~/.mac-remote-bridge/bridge.sh revert`.

## What we fixed relative to v1

| Issue | v1 | v2 |
| --- | --- | --- |
| Consent under `curl \| bash` | Skipped (`[ -t 0 ]` is false on a pipe) | Always read `/dev/tty` |
| sudo under `curl \| bash` | stdin is the script pipe | `sudo -v </dev/tty` |
| `StrictHostKeyChecking=no` | MITM on the broker | `accept-new` + isolated known_hosts |
| User `~/.ssh/config` | Could inject ProxyJump / keys | `ssh -F /dev/null` |
| Agent identities | "Too many authentication failures" | pubkey/agent disabled for the broker |
| Tunnel dies on Terminal close | no `nohup` / `disown` | supervisor ignores `SIGHUP` |
| `pkill -f pinggy` | Kills unrelated processes | PID files |
| VNC advertised | Never enabled Screen Sharing | Opt-in `--vnc` |
| `sleep 4` race | Port often missing | Poll the log up to ~20s |
| HTTP vs TCP tunnel | `a.pinggy.io` without `tcp@` | Official `tcp@free.pinggy.io` |
| SSH ACL | Ignored `com.apple.access_ssh` | Adds the current user if needed |

## Reporting a vulnerability

Open a private security advisory on GitHub, or email the maintainer
listed on the repository. Please do **not** file a public issue for
anything that would make it easier to hijack a live assistance session.
