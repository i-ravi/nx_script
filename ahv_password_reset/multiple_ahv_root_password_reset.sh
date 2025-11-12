#!/bin/bash

# --- Configuration ---
LOG_FILE="password_reset.log"
SUCCESS_FILE="successful_ips.txt"
FAILED_FILE="failed_ips.txt"

# --- Function Definitions ---

# Function to log messages to both console and log file
log() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "$LOG_FILE"
}

# Function to display usage information
usage() {
    echo "Usage: $0 --ip-file <file> --current-passwords <pass1> [pass2...] --new-password <password>"
    echo "  --ip-file             : File containing a list of IP addresses, one per line."
    echo "  --current-passwords   : One or more potential current root passwords."
    echo "  --new-password        : The new root password to set."
    exit 1
}

# --- Argument Parsing ---
if [ "$#" -lt 6 ]; then # Minimum arguments: --ip-file f --current-passwords p --new-password p
    usage
fi

IP_FILE=""
CURRENT_PASSWORDS=()
NEW_PASSWORD=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ip-file)
            IP_FILE="$2"
            shift # past argument
            ;;
        --current-passwords)
            shift # past argument (--current-passwords)
            # Loop to gather all password arguments until the next flag is found
            while [[ "$#" -gt 0 ]] && ! [[ "$1" =~ ^-- ]]; do
                CURRENT_PASSWORDS+=("$1")
                shift # past value
            done
            # The loop will have already shifted past the last password, so no extra shift is needed here.
            continue # continue to next iteration of the main while loop
            ;;
        --new-password)
            NEW_PASSWORD="$2"
            shift # past argument
            ;;
        *)
            log "ERROR: Unknown parameter passed: $1"
            usage
            ;;
    esac
    shift # past value
done

if [[ -z "$IP_FILE" ]] || [[ ${#CURRENT_PASSWORDS[@]} -eq 0 ]] || [[ -z "$NEW_PASSWORD" ]]; then
    log "ERROR: Missing or incorrect arguments. Ensure all flags are provided."
    usage
fi

# --- Prerequisite Check ---
if ! command -v sshpass &> /dev/null; then
    log "ERROR: 'sshpass' is not installed. Please install it to use this script."
    log "On CentOS/RHEL: sudo yum install sshpass"
    log "On Ubuntu/Debian: sudo apt-get install sshpass"
    exit 1
fi

# --- Initialization ---
log "--- Starting Password Reset Script ---"
# Clear previous result files
> "$SUCCESS_FILE"
> "$FAILED_FILE"

if [ ! -f "$IP_FILE" ]; then
    log "ERROR: IP file not found at '$IP_FILE'"
    exit 1
fi

# --- Main Logic ---
mapfile -t IPS < "$IP_FILE"
log "Loaded ${#IPS[@]} IP addresses from ${IP_FILE}."
log "Will attempt ${#CURRENT_PASSWORDS[@]} current password(s) for each node."

for ip in "${IPS[@]}"; do
    if [[ -z "$ip" ]]; then continue; fi

    log "Processing node: ${ip}"
    logged_in=false

    for current_pass in "${CURRENT_PASSWORDS[@]}"; do
        # Attempt to run a simple command to test login, redirecting all output to /dev/null
        sshpass -p "$current_pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@${ip}" 'echo "Connection successful"' &> /dev/null

        if [ $? -eq 0 ]; then
            log "Successfully connected to ${ip}."
            logged_in=true

            # --- Change the password ---
            log "Attempting to change password for root on ${ip}."
            command_to_run="echo '${NEW_PASSWORD}' | passwd --stdin root"

            # Execute password change command
            sshpass -p "$current_pass" ssh "root@${ip}" "$command_to_run"

            if [ $? -eq 0 ]; then
                log "SUCCESS: Password changed successfully for root on ${ip}."
                echo "$ip" >> "$SUCCESS_FILE"
            else
                log "ERROR: Failed to change password on ${ip} after successful login."
                echo "$ip" >> "$FAILED_FILE"
            fi

            break # Exit the inner password loop since we found the right one
        else
            log "Authentication failed for ${ip} with a candidate password."
        fi
    done

    if ! $logged_in; then
        log "ERROR: Could not log in to ${ip} with any of the provided passwords."
        echo "$ip" >> "$FAILED_FILE"
    fi
done

# --- Summary ---
SUCCESS_COUNT=$(wc -l < "$SUCCESS_FILE" | xargs) # xargs trims whitespace
FAILED_COUNT=$(wc -l < "$FAILED_FILE" | xargs)

log "--- Password Reset Summary ---"
log "Total IPs processed: ${#IPS[@]}"
log "Successful resets: ${SUCCESS_COUNT}"
log "Failed resets: ${FAILED_COUNT}"
log "------------------------------"
log "Script finished. Check '${LOG_FILE}', '${SUCCESS_FILE}', and '${FAILED_FILE}' for details."
