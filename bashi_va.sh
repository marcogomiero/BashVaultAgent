#!/bin/bash
# bashi_va.sh - Vault Agent for Token Renewal
# This script periodically checks a Vault token's TTL and renews it if necessary.

# --- Strict Mode for Robustness ---
# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error and exit.
# The return value of a pipeline is the status of the last command to exit with a non-zero status,
# or zero if all commands exit successfully.
set -euo pipefail

# --- Configuration ---
# VAULT_ADDR: The address of your Vault server.
# Defaults to http://127.0.0.1:8200 if not set in the environment.
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

# VAULT_TOKEN: The Vault token to manage.
# IMPORTANT: It is highly recommended to set this as an environment variable (e.g., export VAULT_TOKEN="s.yourtoken")
# for security reasons rather than hardcoding it here.

# LOG_FILE: Path to the script's log file.
LOG_FILE="/var/log/bashi_va.log"

# RENEWAL_THRESHOLD_PERCENT: Renew the token when its current TTL drops below this percentage
# of its creation_ttl (maximum allowed TTL for the token).
RENEWAL_THRESHOLD_PERCENT=50 # Renew when TTL is below 50% of creation_ttl

# --- Functions ---

# log_message: Logs messages with a timestamp, level, and optionally to a file and stderr.
# Usage: log_message <LEVEL> <MESSAGE>
# Levels: INFO, WARNING, ERROR, CRITICAL
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    # Print to stderr and append to the log file
    echo "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}" >&2

    # Add color for console output for warning/error/critical messages if running in a terminal
    if [[ -t 1 ]]; then # Check if stdout is a terminal
        case "$level" in
            "ERROR"|"CRITICAL") echo -e "\e[31m${timestamp} [${level}] ${message}\e[0m" >&2 ;; # Red
            "WARNING") echo -e "\e[33m${timestamp} [${level}] ${message}\e[0m" >&2 ;; # Yellow
        esac
    fi
}

# vault_api_call: Makes a cURL request to the Vault API.
# Handles HTTP response codes and returns the JSON body on success, logs error on failure.
# Usage: vault_api_call <METHOD> <ENDPOINT> [DATA]
# Example: vault_api_call "GET" "auth/token/lookup-self"
# Example: vault_api_call "POST" "auth/token/renew-self"
vault_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}" # Optional data for POST/PUT requests

    local curl_opts=("-s" "-f") # -s: Silent, -f: Fail silently on HTTP errors (4xx/5xx)

    if [[ -n "$data" ]]; then
        curl_opts+=("-X" "${method}" -d "${data}" -H "Content-Type: application/json")
    else
        curl_opts+=("-X" "${method}")
    fi

    local response_body_and_code
    local response_code
    local response_body
    local http_code_pattern="%{http_code}"

    # Execute curl and capture both the body and the HTTP status code.
    # Redirect stderr to /dev/null to suppress curl's own error messages from polluting stdout.
    response_body_and_code=$(curl "${curl_opts[@]}" -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/${endpoint}" -w "${http_code_pattern}" 2>/dev/null)

    # Extract the HTTP code (last 3 characters)
    response_code="${response_body_and_code: -3}"
    # Extract the JSON body (everything except the last 3 characters which are the HTTP code)
    response_body="${response_body_and_code:0:${#response_body_and_code}-3}"

    # Check if the HTTP response code indicates success (2xx)
    if [[ "$response_code" -ge 200 && "$response_code" -lt 300 ]]; then
        echo "$response_body" # Print the JSON body to stdout for caller to capture
    else
        log_message "ERROR" "Vault API call to '${endpoint}' failed with HTTP code ${response_code}. Response: ${response_body:-"No response body"}"
        return 1 # Indicate failure
    fi
}

# --- Pre-flight Checks ---

log_message "INFO" "Starting Vault Agent Script..."

# Check if 'jq' command is available for JSON parsing
if ! command -v jq &> /dev/null; then
    log_message "CRITICAL" "'jq' command not found. Please install jq to parse JSON. Exiting."
    exit 1
fi

# Check if 'curl' command is available for API calls
if ! command -v curl &> /dev/null; then
    log_message "CRITICAL" "'curl' command not found. Please install curl. Exiting."
    exit 1
fi

# Check if VAULT_TOKEN environment variable is set
if [[ -z "${VAULT_TOKEN:-}" ]]; then
    log_message "CRITICAL" "VAULT_TOKEN environment variable is not set. Please set it before running the script. Exiting."
    exit 1
fi

# --- Main Logic ---

# 1. Lookup self token details
log_message "INFO" "Looking up self token details..."
LOOKUP_RESPONSE=$(vault_api_call "GET" "auth/token/lookup-self")

# Check if the API call was successful
if [[ $? -ne 0 ]]; then
    log_message "ERROR" "Failed to lookup self token. See previous log messages for details. Exiting."
    exit 1
fi

# Parse TTL and creation_ttl from the JSON response using jq
TOKEN_TTL=$(echo "${LOOKUP_RESPONSE}" | jq -r '.data.ttl')
TOKEN_CREATION_TTL=$(echo "${LOOKUP_RESPONSE}" | jq -r '.data.creation_ttl')

# Validate that TTL values were successfully parsed
if [[ -z "${TOKEN_TTL}" || -z "${TOKEN_CREATION_TTL}" || ! "$TOKEN_TTL" =~ ^[0-9]+$ || ! "$TOKEN_CREATION_TTL" =~ ^[0-9]+$ ]]; then
    log_message "CRITICAL" "Could not parse valid 'ttl' or 'creation_ttl' from token lookup response using jq. Raw response: ${LOOKUP_RESPONSE}. Exiting."
    exit 1
fi

log_message "INFO" "Current token TTL: ${TOKEN_TTL} seconds. Creation TTL: ${TOKEN_CREATION_TTL} seconds."

# 2. Determine if token renewal is needed
REQUIRED_TTL=$(( TOKEN_CREATION_TTL * RENEWAL_THRESHOLD_PERCENT / 100 ))

if [[ "${TOKEN_TTL}" -lt "${REQUIRED_TTL}" ]]; then
    log_message "WARNING" "Token TTL (${TOKEN_TTL}s) is below renewal threshold (${REQUIRED_TTL}s). Attempting to renew token."

    # Perform token renewal
    RENEW_RESPONSE=$(vault_api_call "POST" "auth/token/renew-self")

    # Check if the renewal API call was successful
    if [[ $? -ne 0 ]]; then
        log_message "ERROR" "Failed to renew token. See previous log messages for details. Exiting."
        exit 1
    fi

    # Optionally parse new TTL after renewal (not strictly necessary as we assume it's renewed)
    NEW_TOKEN_TTL=$(echo "${RENEW_RESPONSE}" | jq -r '.data.ttl')
    if [[ -n "${NEW_TOKEN_TTL}" ]]; then
        log_message "INFO" "Token renewed successfully. New TTL: ${NEW_TOKEN_TTL} seconds."
    else
        log_message "INFO" "Token renewed successfully, but could not parse new TTL from response."
    fi

else
    log_message "INFO" "Token TTL (${TOKEN_TTL}s) is above renewal threshold (${REQUIRED_TTL}s). No renewal needed."
fi

log_message "INFO" "Vault Agent Script finished."

exit 0 # Indicate successful execution