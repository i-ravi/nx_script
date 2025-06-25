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
https://github.com/i-ravi/nx_script.git
cd nx_script-main
chmod +x pe_user_pass_change.sh
./pe_user_pass_change.sh --login_user admin --login_password 'OldPass' --change_user nutanix --change_password 'NewPass123!' --ips 10.0.0.5,10.0.0.6,...


## Script Options

| Flag                     | Default    | Description                                                                                 |
|--------------------------|------------|---------------------------------------------------------------------------------------------|
| --login_user \<user\>        | _n/a_      | **Required.** SSH username to connect to each host.                                         |
| --login_password \<pass\>    | _n/a_      | **Required.** Password for the SSH user.                                                    |
| --change_user \<user\>       | _n/a_      | **Required.** Local account on target hosts whose password you want to reset.               |
| --change_password \<pass\>   | _n/a_      | **Required.** New password to assign to the `--change_user`.                                |
| --ips \<ip1,ip2,…\>          | _n/a_      | **Required.** Comma-separated list of IPv4 addresses to process.                            |
| --ssh-port \<port\>          | 22         | SSH port on the target hosts.                                                               |
| --ssh-timeout \<seconds\>    | 10         | Timeout in seconds for the SSH connection attempt.                                          |
| --max-retries \<count\>      | 1          | Number of ping attempts before giving up on each host.                                      |
| --backoff \<seconds\>        | 5          | Seconds to wait between ping retries.                                                       |
| --dry-run                  | off        | Print out every action without actually performing SSH or changing any passwords.           |
| --verbose                  | off        | Emit extra debug/logging to help trace exactly what’s happening in each step.               |
| -h, --help                 | —          | Show usage help and exit.                                                                   |


