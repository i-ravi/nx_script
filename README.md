# Password-Reset Automation

A robust, idempotent Bash utility to remotely reset user passwords across many Prism Elements — complete with dry-run, retries, per-day logs, and success/failure summaries.

---

## 🎯 Features

- **DRY & Modular**: clear functions for IP validation, ping, SSH, idempotency.  
- **Configurable**: SSH port, timeouts, retries, back-off intervals.  
- **Idempotent**: skips hosts where the password is already set.  
- **Dry-Run & Verbose**: preview actions or turn on debug logging.  
- **Logging**: per-day folders, `script.log`, `success.log`, `failure.log`.  
- **CI-Ready**: ShellCheck linting via GitHub Actions.

---

## 🛠 Prerequisites

- Bash ≥4.0  
- `sshpass`, `ssh`, `ping` installed  
- User on target hosts with `sudo chpasswd` privileges  

---

## 🚀 Quick Start

```bash
git clone https://github.com/your-org/password-reset-script.git
cd password-reset-script
chmod +x bin/reset-password.sh
