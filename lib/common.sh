#!/usr/bin/env bash

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

require_var() {
  local var_name="$1"
  local hint="${2:-}"
  if [[ -z "${!var_name:-}" ]]; then
    if [[ -n "${hint}" ]]; then
      echo "ERROR: missing ${var_name} (${hint})" >&2
    else
      echo "ERROR: missing ${var_name}" >&2
    fi
    exit 1
  fi
}

require_file() {
  local file_path="$1"
  local hint="${2:-}"
  if [[ ! -f "${file_path}" ]]; then
    echo "ERROR: file not found: ${file_path}" >&2
    if [[ -n "${hint}" ]]; then
      echo "${hint}" >&2
    fi
    exit 1
  fi
}

require_tool() {
  local tool="$1"
  local hint="${2:-}"
  if ! command -v "${tool}" &>/dev/null; then
    echo "ERROR: required tool '${tool}' not found in PATH" >&2
    if [[ -n "${hint}" ]]; then
      echo "  Install hint: ${hint}" >&2
    fi
    exit 1
  fi
}

# URL-encode a string (RFC 3986 — encodes everything except unreserved chars)
urlencode() {
  local LC_ALL=C string="$1" i char
  for (( i=0; i<${#string}; i++ )); do
    char="${string:i:1}"
    case "${char}" in
      [a-zA-Z0-9._~-]) printf '%s' "${char}" ;;
      *) printf '%%%02X' "'${char}" ;;
    esac
  done
}

init_common_context() {
  require_tool jq "macOS: brew install jq | Debian/Ubuntu: apt install jq | RHEL/Alpine: package manager"
  PROXMOX_API="https://${PROXMOX_HOST}/api2/json"
  AUTH_HEADER="Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"
  OPNSENSE_API="http://${OPNSENSE_HOST}/api"

  SSH_OPTIONS=(
    -i "${SSH_KEY_FILE}"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    -o BatchMode=yes
  )
}

pve_get() {
  local path="$1"
  curl -fsSL -k \
    -H "${AUTH_HEADER}" \
    "${PROXMOX_API}${path}"
}

pve_post() {
  local path="$1"
  shift
  curl -fsSL -k \
    -X POST \
    -H "${AUTH_HEADER}" \
    "$@" \
    "${PROXMOX_API}${path}"
}

pve_put() {
  local path="$1"
  shift
  curl -fsSL -k \
    -X PUT \
    -H "${AUTH_HEADER}" \
    "$@" \
    "${PROXMOX_API}${path}"
}

pve_delete() {
  local path="$1"
  shift
  curl -fsSL -k \
    -X DELETE \
    -H "${AUTH_HEADER}" \
    "$@" \
    "${PROXMOX_API}${path}"
}

pve_wait_task() {
  local upid="$1"
  local encoded_upid response status exit_status
  encoded_upid="$(urlencode "${upid}")"

  log "  Waiting for Proxmox task..."
  while true; do
    response="$(pve_get "/nodes/${PROXMOX_NODE}/tasks/${encoded_upid}/status")"
    status="$(printf '%s' "${response}" | jq -r '.data.status')"
    if [[ "${status}" == "stopped" ]]; then
      exit_status="$(printf '%s' "${response}" | jq -r '.data.exitstatus // "unknown"')"
      if [[ "${exit_status}" != "OK" ]]; then
        echo "  ERROR: task finished with status '${exit_status}'" >&2
        exit 1
      fi
      log "  Task finished successfully."
      return 0
    fi
    sleep 2
  done
}

opn_post() {
  local path="$1"
  local data="$2"
  curl -fsSL \
    -X POST \
    -u "${OPNSENSE_API_KEY}:${OPNSENSE_API_SECRET}" \
    -H "Content-Type: application/json" \
    -d "${data}" \
    "${OPNSENSE_API}${path}"
}

opn_delete() {
  local path="$1"
  curl -fsSL \
    -X DELETE \
    -u "${OPNSENSE_API_KEY}:${OPNSENSE_API_SECRET}" \
    -H "Content-Type: application/json" \
    "${OPNSENSE_API}${path}"
}

ssh_remote() {
  ssh "${SSH_OPTIONS[@]}" "${SSH_USER}@${TARGET_IP}" "$@"
}
