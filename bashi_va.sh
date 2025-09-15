#!/usr/bin/env bash
# bashi_va.sh - Vault Agent for Token Renewal (revised)

set -euo pipefail

# --- Costanti di default (immutabili) ---
readonly DEFAULT_VAULT_ADDR="http://127.0.0.1:8200"
readonly DEFAULT_LOG_FILE="/var/log/bashi_va.log"
readonly DEFAULT_RENEWAL_THRESHOLD_PERCENT=50

# --- Config file di default, può essere sovrascritto da -c ---
CONFIG_FILE="${BASHI_CONFIG:-$(dirname "$(readlink -f "$0")")/bashi_va.cfg}"
QUIET=false

# --- Funzioni di logging ---
log_message() {
    local level=$1 msg=$2 ts
    ts=$(date +'%Y-%m-%d %H:%M:%S')
    echo "$ts [$level] $msg" >>"$LOG_FILE"
    $QUIET && return
    case $level in
      INFO)    echo "$ts [$level] $msg" ;;
      WARNING) echo -e "\e[33m$ts [$level] $msg\e[0m" ;;
      ERROR|CRITICAL) echo -e "\e[31m$ts [$level] $msg\e[0m" ;;
    esac
}

# --- Trap per segnali e uscita ---
trap 'log_message "ERROR" "Script interrupted"; exit 2' INT TERM
trap 'log_message "INFO" "Script finished with exit code $?."' EXIT

# --- Parametri da riga di comando ---
while getopts "c:q" opt; do
  case $opt in
    c) CONFIG_FILE=$OPTARG ;;
    q) QUIET=true ;;
    *) echo "Usage: $0 [-c config_file] [-q]"; exit 1 ;;
  esac
done

# --- Caricamento configurazione ---
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        . "$CONFIG_FILE"
        log_message "INFO" "Configuration loaded from $CONFIG_FILE"
    else
        log_message "WARNING" "Config file not found ($CONFIG_FILE), using defaults"
    fi
    VAULT_ADDR="${VAULT_ADDR:-$DEFAULT_VAULT_ADDR}"
    LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
    RENEWAL_THRESHOLD_PERCENT="${RENEWAL_THRESHOLD_PERCENT:-$DEFAULT_RENEWAL_THRESHOLD_PERCENT}"
}

# --- Chiamata API Vault con curl robusto ---
vault_api_call() {
    local method=$1 endpoint=$2 data=${3:-}
    local opts=(-s -f --connect-timeout 5 --max-time 10 --retry 2 --retry-delay 2 -X "$method")
    [[ -n $data ]] && opts+=(-d "$data" -H "Content-Type: application/json")
    local resp http_code
    resp=$(curl "${opts[@]}" -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/$endpoint" -w "%{http_code}") || true
    http_code="${resp: -3}"
    body="${resp:0:${#resp}-3}"
    if [[ $http_code =~ ^2 ]]; then
        echo "$body"
    else
        log_message "ERROR" "Vault API $endpoint failed ($http_code): ${body:-No body}"
        return 1
    fi
}

# --- Inizio script ---
load_config

# Verifica log file
if ! mkdir -p "$(dirname "$LOG_FILE")" || ! touch "$LOG_FILE" &>/dev/null; then
    echo "Cannot write to $LOG_FILE" >&2
    exit 1
fi

# Pre-flight checks
command -v jq   >/dev/null || { log_message "CRITICAL" "'jq' not found"; exit 1; }
command -v curl >/dev/null || { log_message "CRITICAL" "'curl' not found"; exit 1; }
[[ -n "${VAULT_TOKEN:-}" ]] || { log_message "CRITICAL" "VAULT_TOKEN not set"; exit 1; }

log_message "INFO" "Starting Vault token check against $VAULT_ADDR"

# Lookup token
LOOKUP_RESPONSE=$(vault_api_call GET "auth/token/lookup-self") || exit 1
TOKEN_TTL=$(echo "$LOOKUP_RESPONSE" | jq -r '.data.ttl')      || { log_message "CRITICAL" "Invalid jq parse"; exit 1; }
TOKEN_CREATION_TTL=$(echo "$LOOKUP_RESPONSE" | jq -r '.data.creation_ttl') || { log_message "CRITICAL" "Invalid jq parse"; exit 1; }

[[ $TOKEN_TTL =~ ^[0-9]+$ && $TOKEN_CREATION_TTL =~ ^[0-9]+$ ]] \
    || { log_message "CRITICAL" "TTL parse error"; exit 1; }

log_message "INFO" "Current TTL: ${TOKEN_TTL}s, Creation TTL: ${TOKEN_CREATION_TTL}s"

REQUIRED_TTL=$(( TOKEN_CREATION_TTL * RENEWAL_THRESHOLD_PERCENT / 100 ))

if (( TOKEN_TTL < REQUIRED_TTL )); then
    log_message "WARNING" "TTL below threshold ($REQUIRED_TTL s), renewing token"
    RENEW_RESPONSE=$(vault_api_call POST "auth/token/renew-self") || exit 1
    NEW_TTL=$(echo "$RENEW_RESPONSE" | jq -r '.data.ttl' || echo "")
    [[ $NEW_TTL =~ ^[0-9]+$ ]] && \
        log_message "INFO" "Token renewed successfully, new TTL: ${NEW_TTL}s" || \
        log_message "INFO" "Token renewed, TTL not parsable"
else
    log_message "INFO" "TTL above threshold, no renewal needed"
fi

exit 0