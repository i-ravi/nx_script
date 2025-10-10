#!/usr/bin/env bash
set -euo pipefail
set +H                # disable history expansion so ! in passwords are safe

# Defaults
SSH_PORT=22
SSH_TIMEOUT=10
MAX_RETRIES=1
BACKOFF=5
DRY_RUN=0
VERBOSE=0

# Logs: create a fresh timestamped directory for every run and a stable "latest" symlink
BASE_LOG_ROOT="logs"
TIMESTAMP="$(date +%F_%H%M%S)"
LOG_DIR="${BASE_LOG_ROOT}/${TIMESTAMP}"
LATEST_LINK="${BASE_LOG_ROOT}/latest"

LOGFILE="$LOG_DIR/script.log"
SUCCESS_LOG="$LOG_DIR/success.log"
FAILURE_LOG="$LOG_DIR/failure.log"

mkdir -p "$LOG_DIR"

# update latest symlink atomically (remove existing file/dir/link, then create symlink)
if [ -e "$LATEST_LINK" ] || [ -L "$LATEST_LINK" ]; then
  rm -rf "$LATEST_LINK"
fi
ln -s "$TIMESTAMP" "$LATEST_LINK"

# Start empty logs for this run
: > "$LOGFILE"
: > "$SUCCESS_LOG"
: > "$FAILURE_LOG"

total=0
success_count=0
failure_count=0

log_message() { echo "$(date '+%F %T') $1" | tee -a "$LOGFILE"; }
log_debug() { (( VERBOSE )) && echo "$(date '+%F %T') [DEBUG] $1" >> "$LOGFILE"; }
log_success() { echo "$1" >> "$SUCCESS_LOG"; (( success_count++ )); }
log_failure() { echo "$1" >> "$FAILURE_LOG"; (( failure_count++ )); }

usage() {
  cat <<EOF
Usage: $0 --login_user USER --login_password PASS|@file.txt --change_user TARGET --change_password NEWPASS|@file.txt --ips ip1,ip2,... | @ips.txt [options]
Options:
  --ssh-port PORT
  --ssh-timeout SECS
  --max-retries N
  --backoff SECS
  --dry-run
  --verbose
  -h, --help
EOF
  exit 1
}

[ "$#" -eq 0 ] && usage

while [ "$#" -gt 0 ]; do
  case "$1" in
    --login_user)       SSH_USER="$2"; shift 2 ;;
    --login_password)   RAW_SSH_PASS="$2"; shift 2 ;;
    --change_user)      CHANGE_USER="$2"; shift 2 ;;
    --change_password)  RAW_CHANGE_PASS="$2"; shift 2 ;;
    --ips)              RAW_IPS="$2"; shift 2 ;;
    --ssh-port)         SSH_PORT="$2"; shift 2 ;;
    --ssh-timeout)      SSH_TIMEOUT="$2"; shift 2 ;;
    --max-retries)      MAX_RETRIES="$2"; shift 2 ;;
    --backoff)          BACKOFF="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --verbose)          VERBOSE=1; shift ;;
    -h|--help)          usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Read values: either literal or @file. Preserve literal content.
read_values() {
  local input="$1"
  if [[ -z "${input:-}" ]]; then
    return 1
  fi
  if [[ "$input" == @* ]]; then
    local file="${input:1}"
    [ -f "$file" ] || { echo "ERROR: file not found:$file" >&2; return 1; }
    # strip CR, remove empty lines
    sed 's/\r$//' "$file" | sed '/^[[:space:]]*$/d'
  else
    printf '%s\n' "$input"
  fi
}

# load login password candidates (one per line) and change password (first non-empty)
mapfile -t SSH_PASS_LIST < <(read_values "${RAW_SSH_PASS:-}" 2>/dev/null) || { echo "Missing or invalid --login_password" >&2; usage; }
mapfile -t CHANGE_PASS_LIST < <(read_values "${RAW_CHANGE_PASS:-}" 2>/dev/null) || { echo "Missing or invalid --change_password" >&2; usage; }
CHANGE_PASS="${CHANGE_PASS_LIST[0]:-}"

# load ips (comma-separated string and/or file with one-per-line)
read_ip_values() {
  local raw="$1"
  mapfile -t lines < <(read_values "$raw")
  ip_array=()
  for line in "${lines[@]}"; do
    # split on commas and whitespace, support entries like "1.2.3.4,5.6.7.8" or separate lines
    IFS=',' read -r -a parts <<< "$line"
    for v in "${parts[@]}"; do
      # trim whitespace
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v%"${v##*[![:space:]]}"}"
      [ -n "$v" ] && ip_array+=("$v")
    done
  done
}

if [[ "${RAW_IPS:-}" == "" ]]; then
  echo "No IPs provided"; usage
fi
read_ip_values "$RAW_IPS"

# required checks
for cmd in sshpass ssh ping sed grep awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd not found" >&2; exit 1; }
done

: "${SSH_USER:?--login_user is required}"
: "${SSH_PASS_LIST[0]:?--login_password is required}"
: "${CHANGE_USER:?--change_user is required}"
: "${CHANGE_PASS:?--change_password is required}"
[ "${#ip_array[@]}" -gt 0 ] || { echo "No IPs provided"; usage; }

validate_ip() {
  local ip=$1
  log_debug "Validating IP: $ip"
  if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 0
  fi
  log_message "❌ $ip – invalid format"
  log_failure "$ip : invalid IP format"
  return 1
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

try_ssh_passwords() {
  local ip=$1
  WORKING_PASS=""
  for pass in "${SSH_PASS_LIST[@]}"; do
    SSH_OPTS=( -o BatchMode=no -o StrictHostKeyChecking=no -o ConnectTimeout="${SSH_TIMEOUT}" -o NumberOfPasswordPrompts=1 -p "${SSH_PORT}" )
    if (( DRY_RUN )); then
      WORKING_PASS="$pass"
      return 0
    fi
    log_debug "Trying SSH candidate for $ip"
    if sshpass -p"$pass" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" 'true' &>/dev/null; then
      WORKING_PASS="$pass"
      log_debug "Auth succeeded for $ip"
      return 0
    fi
    sleep 1
  done
  log_message "❌ $ip – all provided login passwords failed"
  log_failure "$ip : authentication failed"
  return 1
}

# Conservative idempotency: by default do not skip because reliable remote check is environment-dependent.
# If you have a specific command on targets to verify, replace this function.
check_idempotent_remote() {
  return 1
}

ssh_change() {
  local ip=$1
  local pass="$2"
  local ssh_opts=( -o StrictHostKeyChecking=no -o ConnectTimeout="${SSH_TIMEOUT}" -p "${SSH_PORT}" )
  local remote_cmd="echo '${CHANGE_USER}:${CHANGE_PASS}' | sudo chpasswd"
  if (( DRY_RUN )); then
    log_message "[dry-run] Would run: sshpass -p*** ssh ${ssh_opts[*]} ${SSH_USER}@${ip} \"$remote_cmd\""
    log_success "$ip : dry-run change recorded"
    return 0
  fi
  log_message "🔐 Changing password on $ip"
  log_debug "Running remote chpasswd on $ip"
  if sshpass -p"$pass" ssh "${ssh_opts[@]}" "${SSH_USER}@${ip}" "$remote_cmd" &>> "$LOGFILE"; then
    log_message "✔️  $ip – password change succeeded"
    log_success "$ip : password for user $CHANGE_USER reset"
    return 0
  else
    log_message "❌ $ip – password change FAILED"
    log_failure "$ip : chpasswd failed"
    return 1
  fi
}

process_host() {
  local ip="$1"
  ip="${ip//[[:space:]]/}"
  (( total++ ))
  log_message "--> Processing $ip"

  validate_ip "$ip" || return 1
  ping_host "$ip" || return 1
  try_ssh_passwords "$ip" || return 1

  if check_idempotent_remote "$ip" "$WORKING_PASS"; then
    log_message "⚠️  $ip – password already set for $CHANGE_USER; skipping"
    log_success "$ip : password already set (skipped)"
    return 0
  fi

  ssh_change "$ip" "$WORKING_PASS"
}

log_message "=== Run started: $(date '+%F %T') ==="

set +e

# Iterate all IPs; disable errexit around each host to allow smooth continue on failure
for ip in "${ip_array[@]}"; do
  process_host "$ip"
  rc=$?
  if [ $rc -eq 0 ]; then
    log_debug "$ip processed successfully"
  else
    log_message "⚠️  $ip processing failed with exit code ${rc}; continuing to next host"
    log_debug "$ip processing finished with errors (exit code $rc)"
  fi
done
set -e

success_count=$(wc -l < "$SUCCESS_LOG" 2>/dev/null || echo 0)
failure_count=$(wc -l < "$FAILURE_LOG" 2>/dev/null || echo 0)
log_message "=== Run complete: total=${total}, success=${success_count}, failure=${failure_count} ==="
echo "Summary: ${total} hosts, ${success_count} succeeded, ${failure_count} failed" | tee -a "$LOGFILE"

if [ -s "$FAILURE_LOG" ]; then
  exit 1
else
  exit 0
fi
