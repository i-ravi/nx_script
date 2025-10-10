#!/usr/bin/env bash
set -euo pipefail
set +H                # disable history expansion so ! in passwords are safe

# Defaults
SSH_PORT=22
SSH_TIMEOUT=10
MAX_RETRIES=1
VERBOSE=0

# Logs: new timestamped directory per run, plus stable "latest" symlink
BASE_LOG_ROOT="auth_logs"
TIMESTAMP="$(date +%F_%H%M%S)"
LOG_DIR="${BASE_LOG_ROOT}/${TIMESTAMP}"
LATEST_LINK="${BASE_LOG_ROOT}/latest"

LOGFILE="$LOG_DIR/validate.log"
SUCCESS_LOG="$LOG_DIR/success.log"
FAILURE_LOG="$LOG_DIR/failure.log"

mkdir -p "$LOG_DIR"
if [ -e "$LATEST_LINK" ] || [ -L "$LATEST_LINK" ]; then
  rm -rf "$LATEST_LINK"
fi
ln -s "$TIMESTAMP" "$LATEST_LINK"

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
Usage: $0 --login_user USER --login_password PASS|@pass.txt --ips ip1,ip2,... | @ips.txt [options]
Options:
  --ssh-port PORT
  --ssh-timeout SECS
  --max-retries N
  --verbose
  -h, --help
This script VALIDATES whether any of the provided password candidates works for the single provided user on each IP.
EOF
  exit 1
}

[ "$#" -eq 0 ] && usage

# parse args
while [ "$#" -gt 0 ]; do
  case "$1" in
    --login_user)       SSH_USER="$2"; shift 2 ;;
    --login_password)   RAW_SSH_PASS="$2"; shift 2 ;;
    --ips)              RAW_IPS="$2"; shift 2 ;;
    --ssh-port)         SSH_PORT="$2"; shift 2 ;;
    --ssh-timeout)      SSH_TIMEOUT="$2"; shift 2 ;;
    --max-retries)      MAX_RETRIES="$2"; shift 2 ;;
    --verbose)          VERBOSE=1; shift ;;
    -h|--help)          usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# helpers to read literal or @file, strip CR and empty lines
read_values() {
  local input="$1"
  if [[ -z "${input:-}" ]]; then
    return 1
  fi
  if [[ "$input" == @* ]]; then
    local file="${input:1}"
    [ -f "$file" ] || { echo "ERROR: file not found:$file" >&2; return 1; }
    sed 's/\r$//' "$file" | sed '/^[[:space:]]*$/d'
  else
    printf '%s\n' "$input"
  fi
}

# build arrays: passwords, ips
read_list_to_array() {
  local raw="$1"
  mapfile -t lines < <(read_values "$raw")
  local -n out=$2
  out=()
  for line in "${lines[@]}"; do
    IFS=',' read -r -a parts <<< "$line"
    for v in "${parts[@]}"; do
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v%"${v##*[![:space:]]}"}"
      [ -n "$v" ] && out+=("$v")
    done
  done
}

# load inputs
read_list_to_array "${RAW_SSH_PASS:-}" SSH_PASS_LIST || { echo "Missing or invalid --login_password" >&2; usage; }
read_list_to_array "${RAW_IPS:-}" ip_array || { echo "Missing or invalid --ips" >&2; usage; }

# sanity checks
for cmd in sshpass ssh sed grep awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd not found" >&2; exit 1; }
done

: "${SSH_USER:?--login_user is required}"
[ "${#SSH_PASS_LIST[@]}" -gt 0 ] || { echo "--login_password is required" >&2; usage; }
[ "${#ip_array[@]}" -gt 0 ] || { echo "--ips is required" >&2; usage; }

validate_ip() {
  local ip=$1
  log_debug "Validating IP: $ip"
  if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 0
  fi
  log_message "❌ $ip – invalid format"
  return 1
}

# Try passwords for the single user@ip. Sets WORKING_PASS and returns 0 on success.
try_passwords_for_user() {
  local ip="$1"
  WORKING_PASS=""
  for pass in "${SSH_PASS_LIST[@]}"; do
    SSH_OPTS=( -o BatchMode=no \
               -o StrictHostKeyChecking=no \
               -o ConnectTimeout="${SSH_TIMEOUT}" \
               -o NumberOfPasswordPrompts=1 \
               -o PreferredAuthentications=password \
               -o PubkeyAuthentication=no \
               -o ControlMaster=no \
               -o ControlPath=none \
               -p "${SSH_PORT}" )
    log_debug "Trying ${SSH_USER}@${ip} with a password candidate"
    if sshpass -p"$pass" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" 'true' >/dev/null 2>&1; then
      WORKING_PASS="$pass"
      return 0
    fi
    sleep 1
  done
  return 1
}

process_host_validate() {
  local ip="$1"
  ip="${ip//[[:space:]]/}"
  (( total++ ))
  log_message "--> Validating $ip"

  validate_ip "$ip" || { log_failure "$ip : invalid IP format"; return 1; }

  if try_passwords_for_user "$ip"; then
    log_message "✔ $ip – authentication succeeded for user ${SSH_USER}"
    log_success "$ip : auth OK user=${SSH_USER}"
    return 0
  else
    log_message "❌ $ip – authentication failed for all provided passwords"
    log_failure "$ip : auth failed for user=${SSH_USER}"
    return 1
  fi
}

log_message "=== Validation run started: $(date '+%F %T') ==="

# allow per-host failures without exiting whole script
set +e
for ip in "${ip_array[@]}"; do
  process_host_validate "$ip"
  rc=$?
  if [ $rc -eq 0 ]; then
    log_debug "$ip validated successfully"
  else
    log_message "⚠️  $ip validation failed (exit $rc); continuing"
  fi
done
set -e

success_count=$(wc -l < "$SUCCESS_LOG" 2>/dev/null || echo 0)
failure_count=$(wc -l < "$FAILURE_LOG" 2>/dev/null || echo 0)
log_message "=== Validation complete: total=${total}, success=${success_count}, failure=${failure_count} ==="
echo "Summary: ${total} hosts, ${success_count} authenticated, ${failure_count} failed" | tee -a "$LOGFILE"

if [ -s "$FAILURE_LOG" ]; then
  exit 1
else
  exit 0
fi
