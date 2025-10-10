# SSH Password Validator

A compact, reliable Bash utility that verifies whether a single user’s password candidates authenticate on a list of hosts. Runs through all targets, logs every run to a timestamped folder under `auth_logs/`, and produces clear success and failure outputs for auditing.

## Features
- Validates SSH password authentication for one user across many hosts  
- Accepts password candidates as a literal string or `@file`  
- Accepts IP lists as comma-separated input or `@file` with one per line  
- Fresh timestamped logs for every run and stable `auth_logs/latest` symlink  
- Continues on per-host failures, producing full run results  
- Lightweight, portable, and easy to integrate into automations

## Requirements
- bash (with mapfile)  
- sshpass  
- OpenSSH client (`ssh`)  
- sed, grep, awk (standard POSIX tools)

## Usage
Basic flags:
- **--login_user** USER  
- **--login_password** PASS or `@password_file`  
- **--ips** ip1,ip2,... or `@ips_file`  

Optional flags:
- **--ssh-port** PORT  
- **--ssh-timeout** SECS  
- **--max-retries** N  
- **--verbose**  
- **-h**, **--help**

Examples:
- Inline passwords and IPs  
  ./validate.sh --login_user alice --login_password secret123 --ips 10.0.0.1,10.0.0.2
- From files  
  ./validate.sh --login_user alice --login_password @passwords.txt --ips @ips.txt

## Logs and Exit Codes
- Logs directory per run: `auth_logs/YYYY-MM-DD_HHMMSS/`  
  - **validate.log** combined run log  
  - **success.log** one host per line where auth succeeded  
  - **failure.log** one host per line where auth failed  
- `auth_logs/latest` points to the most recent run  
- Exit code **0** if all hosts authenticated successfully; non-zero if any host failed
