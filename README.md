# 🚀 mac-remote-bridge

> **Zero-Config Remote Assistance & Tunneling CLI for macOS**  
> Enables instant, secure remote terminal (SSH) and desktop (VNC) access across any network firewall or NAT without port forwarding, registration, or third-party client installation.

[![macOS](https://img.shields.io/badge/macOS-10.15%2B%20%7C%20Apple%20Silicon-black?style=for-the-badge&logo=apple)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](LICENSE)
[![Zero Dependencies](https://img.shields.io/badge/Dependencies-Zero-brightgreen?style=for-the-badge)](#features)

---

## ⚡ Features

- **🚀 One-Line Execution:** Instant setup via `curl` directly from macOS Terminal.
- **🛡️ Security & Audit Compliant:** Displays explicit risk disclosures and requires interactive user confirmation before opening any tunnel.
- **🔒 Native SSH & VNC Support:** Enables full CLI terminal access and native macOS Screen Sharing (`vnc://`).
- **🌐 Universal NAT & Firewall Bypass:** Operates behind strict CGNAT, mobile hotspots, and corporate networks via secure reverse tunneling (`pinggy.io`).
- **⚡ Zero Dependencies:** Pure Bash script leveraging native macOS utilities (`systemsetup`, `nc`, `ssh`). No Homebrew, Python, or external apps required.

---

## 🚀 One-Line Quick Run

On the remote Mac, simply execute:

```bash
curl -sL https://raw.githubusercontent.com/chumafox/mac-remote-bridge/main/bridge.sh | bash
```

---

## 🛠️ How It Works

1. **Security Audit Disclosure:** Displays an explicit banner informing the user that remote SSH and Screen Sharing access is being enabled.
2. **SSH Service Check:** Verifies if native macOS Remote Login is active; if disabled, requests admin permission to turn it on (`sudo systemsetup -setremotelogin on`).
3. **Background Tunneling:** Initiates an encrypted reverse SSH tunnel in the background (`a.pinggy.io`).
4. **Connection Details:** Generates ready-to-use terminal & VNC connection strings for the operator.

---

## 💻 Operator Connection Commands

### 1. Terminal Access (SSH)
```bash
ssh -p <PORT> <USER>@a.pinggy.io
```

### 2. Full Screen Sharing (VNC Desktop)
```bash
ssh -L 5900:localhost:5900 -p <PORT> <USER>@a.pinggy.io
```
Then open Finder ➔ **Cmd + K** ➔ connect to `vnc://localhost:5900`.

---

## 🛑 How to Terminate Access

The user can stop the remote session at any time by running:

```bash
pkill -f pinggy
```

---

## 📄 License

Distributed under the [MIT License](LICENSE).
