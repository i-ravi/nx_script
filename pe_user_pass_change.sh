#!/usr/bin/env bash
set -euo pipefail

# ================================================
# Password-Reset Automation Script
# ================================================
# Features:
#  1. Modular functions (DRY)
#  2. Configurable SSH port, timeout, retries, back-off
#  3. Daily timestamped logs & summary
#  4. --dry-run and --verbose modes
#  5. Idempotent: skips users already using the target password
# ================================================

# ---- Defaults for configurable parameters ----
SSH_PORT=22
SSH_TIMEOUT=10
MAX_RETRIES=1
BACKOFF=5
DRY_RUN=0
VERBOSE=0

# ---- Log directory & files (per date) ----
LOG_DIR="logs/$(date +%F)"
LOGFILE="$LOG_DIR/script.log"
SUCCESS_LOG="$LOG_DIR/success.log"
FAILURE_LOG="$LOG_DIR/failure.log"

# ---- Counters ----
total=0
success_count=0
failure_count=0

# ----------------------------------------
# Helpers
# ----------------------------------------
mkdir -p "$LOG_DIR"

log_message() {
  echo "$(date '+%F %T') $1" | tee -a "$LOGFILE"
}

log_success() {
  echo "$1" >> "$SUCCESS_LOG"
  (( success_count++ ))
}

log_failure() {
  echo "$1" >> "$FAILURE_LOG"
  (( failure_count++ ))
}

usage() {
  cat <<EOF
Usage: $0 --login_user USER --login_password PASS --change_user TARGET --change_password NEWPASS --ips ip1,ip2,... [options]

Options:
  --ssh-port PORT       SSH port (default $SSH_PORT)
  --ssh-timeout SECS    SSH connect timeout (default $SSH_TIMEOUT)
  --max-retries N       Ping retries (default $MAX_RETRIES)
  --backoff SECS        Seconds between ping retries (default $BACKOFF)
  --dry-run             Print actions without executing
  --verbose             Print extra debug info
  -h, --help            Show this message and exit
EOF
  exit 1
}

# ----------------------------------------
# Parse & validate CLI args
# ----------------------------------------
[ "$#" -eq 0 ] && usage

while [ "$#" -gt 0 ]; do
  case "$1" in
    --login_user)       SSH_USER="$2";      shift 2 ;;
    --login_password)   SSH_PASS="$2";      shift 2 ;;
    --change_user)      CHANGE_USER="$2";   shift 2 ;;
    --change_password)  CHANGE_PASS="$2";   shift 2 ;;
    --ips)              IPS="$2";           shift 2 ;;
    --ssh-port)         SSH_PORT="$2";      shift 2 ;;
    --ssh-timeout)      SSH_TIMEOUT="$2";   shift 2 ;;
    --max-retries)      MAX_RETRIES="$2";   shift 2 ;;
    --backoff)          BACKOFF="$2";       shift 2 ;;
    --dry-run)          DRY_RUN=1;          shift ;;
    --verbose)          VERBOSE=1;          shift ;;
    -h|--help)          usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

for var in SSH_USER SSH_PASS CHANGE_USER CHANGE_PASS IPS; do
  [ -z "${!var-}" ] && echo "Missing required: $var" && usage
done

for cmd in sshpass ssh ping; do
  command -v $cmd >/dev/null 2>&1 || { echo "Error: $cmd not found"; exit 1; }
done

# ----------------------------------------
# Split IPs
# ----------------------------------------
IFS=',' read -r -a ip_array <<< "$IPS"

# ----------------------------------------
# Function Definitions
# ----------------------------------------
validate_ip() {
  local ip=$1
  if ! [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log_message "❌ $ip – invalid format"
    log_failure "$ip : invalid IP format"
    return 1
  fi
}

ping_host() {
  local ip=$1
  local attempt=1
  while (( attempt <= MAX_RETRIES )); do
    if ping -c1 -W2 "$ip" &>/dev/null; then
      log_message "✔ $ip reachable (ping)"
      return 0
    fi
    log_message "… ping $ip failed (attempt $attempt/$MAX_RETRIES), retry in $BACKOFF sec"
    sleep "$BACKOFF"
    (( attempt++ ))
  done
  log_message "❌ $ip unreachable after $MAX_RETRIES attempts"
  log_failure "$ip : unreachable"
  return 1
}

is_idempotent() {
  local ip=$1
  local check_cmd="echo '$CHANGE_PASS' | sudo -u $CHANGE_USER -S -v"
  if sshpass -p"$SSH_PASS" \
       ssh -q -o BatchMode=no \
           -o StrictHostKeyChecking=no \
           -o ConnectTimeout="$SSH_TIMEOUT" \
           -p "$SSH_PORT" "$SSH_USER@$ip" "$check_cmd" &>/dev/null; then
    log_message "⚠️  $ip – password already set for $CHANGE_USER; skipping"
    log_success "$ip : password for user $CHANGE_USER already set (skipped)"
    return 0
  fi
  return 1
}

ssh_change() {
  local ip=$1
  local tmp
  tmp=$(mktemp)

  local ssh_opts="-o StrictHostKeyChecking=no \
                  -o ConnectTimeout=$SSH_TIMEOUT \
                  -p $SSH_PORT"
  (( DRY_RUN )) && {
    log_message "[dry-run] sshpass -p*** ssh $ssh_opts $SSH_USER@$ip chpasswd"
    rm -f "$tmp"
    return 0
  }

  log_message "🔐 Changing password on $ip"
  sshpass -p"$SSH_PASS" ssh $ssh_opts "$SSH_USER@$ip" <<EOF 2>&1 | tee -a "$LOGFILE" "$tmp"
echo "$CHANGE_USER:$CHANGE_PASS" | sudo chpasswd
EOF
  local status=${PIPESTATUS[0]}

  if grep -q ""]"$tmp"; then :; fi  # noop placeholder

  if [ $status -eq 0 ]; then
    log_message "✔️  $ip – password change succeeded"
    log_success "$ip : password for user $CHANGE_USER reset"
  else
    log_message "❌  $ip – password change FAILED (exit $status)"
    log_failure "$ip : chpasswd failed (exit $status)"
  fi

  rm -f "$tmp"
}

# ----------------------------------------
# Main Loop
# ----------------------------------------
log_message "=== Run started: $(date '+%F %T') ==="

for ip in "${ip_array[@]}"; do
  ip="${ip//[[:space:]]/}"
  (( total++ ))
  log_message "--> Processing $ip"

  validate_ip "$ip"     || continue
  ping_host "$ip"       || continue
  is_idempotent "$ip"   && continue

  ssh_change "$ip"
done

# ----------------------------------------
# Summary & Exit
# ----------------------------------------
log_message "=== Run complete: total=$total, success=$success_count, failure=$failure_count ==="
echo "Summary: $total hosts, $success_count succeeded, $failure_count failed" | tee -a "$LOGFILE"

if [ $failure_count -gt 0 ]; then
  echo "See $FAILURE_LOG for details." | tee -a "$LOGFILE"
  exit 1
else
  exit 0
fi
