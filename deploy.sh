#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE_FILE="${SCRIPT_DIR}/.env.example"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1091
  set -a; source "${ENV_FILE}"; set +a
fi

show_usage() {
  cat <<EOF
Usage:
  $0 <app-name> <target-ip> <subdomain>
  $0 --resume <app-name>
  $0 --wizard

Examples:
  $0 gitea 10.0.0.50 git.example.com
  $0 --resume gitea
  $0 --wizard
EOF
}

prompt_default() {
  local __var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local secret="${4:-0}"
  local input_value=""

  if [[ "${secret}" == "1" ]]; then
    if [[ -n "${default_value}" ]]; then
      read -r -s -p "${label} [***]: " input_value
    else
      read -r -s -p "${label}: " input_value
    fi
    echo ""
  else
    if [[ -n "${default_value}" ]]; then
      read -r -p "${label} [${default_value}]: " input_value
    else
      read -r -p "${label}: " input_value
    fi
  fi

  if [[ -z "${input_value}" ]]; then
    input_value="${default_value}"
  fi
  printf -v "${__var_name}" '%s' "${input_value}"
}

env_set_value() {
  local key="$1"
  local value="$2"
  local tmp_file old_umask

  old_umask="$(umask)"
  umask 077
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/homelab-env.${key}.XXXXXX")"
  umask "${old_umask}"
  if [[ -f "${ENV_FILE}" ]]; then
    grep -v "^${key}=" "${ENV_FILE}" > "${tmp_file}" || true
  fi
  printf "%s=%q\n" "${key}" "${value}" >> "${tmp_file}"
  mv "${tmp_file}" "${ENV_FILE}"
}

validate_app_name() {
  local name="$1"
  if [[ -z "${name}" ]]; then
    echo "ERROR: APP_NAME cannot be empty" >&2
    exit 1
  fi
  if [[ ! "${name}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: APP_NAME '${name}' contains invalid characters (allowed: a-z A-Z 0-9 . _ -)" >&2
    exit 1
  fi
}

validate_ipv4() {
  local ip="$1"
  if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ERROR: invalid IP address '${ip}'" >&2
    exit 1
  fi
  local IFS='.' parts=()
  read -r -a parts <<< "${ip}"
  local p
  for p in "${parts[@]}"; do
    if (( p > 255 )); then
      echo "ERROR: invalid IP address '${ip}' (octet ${p} > 255)" >&2
      exit 1
    fi
  done
}

wizard_configure_env_if_missing() {
  local create_env="y"
  local vmid_mode=""

  if [[ -f "${ENV_FILE}" ]]; then
    return 0
  fi

  echo ""
  echo "No .env file found."
  read -r -p "Create and configure ${ENV_FILE} now? [Y/n]: " create_env
  create_env="$(printf '%s' "${create_env:-y}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${create_env}" == "n" || "${create_env}" == "no" ]]; then
    return 0
  fi

  if [[ -f "${ENV_EXAMPLE_FILE}" ]]; then
    cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
  else
    : > "${ENV_FILE}"
  fi
  chmod 600 "${ENV_FILE}" 2>/dev/null || true

  echo ""
  echo "=== Initial Infrastructure Setup ==="
  prompt_default PROXMOX_HOST "Proxmox host:port" "${PROXMOX_HOST:-pve.example.com:8006}"
  prompt_default PROXMOX_NODE "Proxmox node" "${PROXMOX_NODE:-pve}"
  prompt_default PROXMOX_TEMPLATE_ID "Template VMID" "${PROXMOX_TEMPLATE_ID:-280}"
  prompt_default PROXMOX_STORAGE "Proxmox storage" "${PROXMOX_STORAGE:-local-lvm}"
  prompt_default PROXMOX_TOKEN_ID "Proxmox token ID" "${PROXMOX_TOKEN_ID:-root@pam!deploy}"
  prompt_default PROXMOX_TOKEN_SECRET "Proxmox token secret" "${PROXMOX_TOKEN_SECRET:-}" "1"

  prompt_default OPNSENSE_HOST "OPNsense host/IP" "${OPNSENSE_HOST:-10.0.0.1}"
  prompt_default OPNSENSE_API_KEY "OPNsense API key" "${OPNSENSE_API_KEY:-}"
  prompt_default OPNSENSE_API_SECRET "OPNsense API secret" "${OPNSENSE_API_SECRET:-}" "1"

  prompt_default SSH_KEY_FILE "SSH private key path" "${SSH_KEY_FILE:-$HOME/.ssh/deploy_automation}"
  prompt_default SSH_USER "SSH user" "${SSH_USER:-root}"

  prompt_default PROXMOX_VMID_POLICY "VMID policy (nextid|range_first|range_random|manual)" "${PROXMOX_VMID_POLICY:-nextid}"
  vmid_mode="$(printf '%s' "${PROXMOX_VMID_POLICY}" | tr '[:upper:]' '[:lower:]')"
  case "${vmid_mode}" in
    range_first|range_random)
      prompt_default PROXMOX_VMID_RANGE_START "VMID range start" "${PROXMOX_VMID_RANGE_START:-200}"
      prompt_default PROXMOX_VMID_RANGE_END "VMID range end" "${PROXMOX_VMID_RANGE_END:-299}"
      PROXMOX_VMID=""
      ;;
    manual)
      prompt_default PROXMOX_VMID "Manual VMID" "${PROXMOX_VMID:-200}"
      ;;
    *)
      PROXMOX_VMID_POLICY="nextid"
      PROXMOX_VMID=""
      ;;
  esac

  env_set_value "PROXMOX_HOST" "${PROXMOX_HOST}"
  env_set_value "PROXMOX_NODE" "${PROXMOX_NODE}"
  env_set_value "PROXMOX_TEMPLATE_ID" "${PROXMOX_TEMPLATE_ID}"
  env_set_value "PROXMOX_STORAGE" "${PROXMOX_STORAGE}"
  env_set_value "PROXMOX_TOKEN_ID" "${PROXMOX_TOKEN_ID}"
  env_set_value "PROXMOX_TOKEN_SECRET" "${PROXMOX_TOKEN_SECRET}"
  env_set_value "OPNSENSE_HOST" "${OPNSENSE_HOST}"
  env_set_value "OPNSENSE_API_KEY" "${OPNSENSE_API_KEY}"
  env_set_value "OPNSENSE_API_SECRET" "${OPNSENSE_API_SECRET}"
  env_set_value "SSH_KEY_FILE" "${SSH_KEY_FILE}"
  env_set_value "SSH_USER" "${SSH_USER}"
  env_set_value "PROXMOX_VMID_POLICY" "${PROXMOX_VMID_POLICY}"
  env_set_value "PROXMOX_VMID_RANGE_START" "${PROXMOX_VMID_RANGE_START:-200}"
  env_set_value "PROXMOX_VMID_RANGE_END" "${PROXMOX_VMID_RANGE_END:-299}"
  env_set_value "PROXMOX_VMID" "${PROXMOX_VMID:-}"

  echo ""
  echo "Saved initial configuration to ${ENV_FILE}."
  echo ""
}

# ── Wizard-time resume helpers (available before libs are sourced) ───────────

_wizard_state_file_for() {
  local app_name="$1"
  local safe_name
  safe_name="$(printf '%s' "${app_name}" | tr -c 'A-Za-z0-9._-' '_')"
  if [[ -z "${safe_name}" ]]; then safe_name="app"; fi
  printf '%s/%s.env' "${DEPLOY_STATE_DIR:-${SCRIPT_DIR}/.deploy-state}" "${safe_name}"
}

_wizard_load_state() {
  local state_file="$1"
  if [[ -f "${state_file}" ]]; then
    # shellcheck disable=SC1090
    source "${state_file}"
  fi
}

_wizard_detect_resume_phase() {
  # Returns: "1" "2" "3" "proxy" or "done"
  if [[ -z "${VMID:-}" || -z "${MAC_ADDRESS:-}" ]]; then echo "1"; return; fi
  if [[ -z "${KEA_RESERVATION_UUID:-}" ]];            then echo "2"; return; fi
  if [[ "${PROVISION_STATUS:-}" != "ssh_ready" ]];    then echo "3"; return; fi
  if [[ -z "${PROXY_STATUS:-}" ]];                    then echo "proxy"; return; fi
  echo "done"
}

should_run_flag() {
  local flag_raw="$1"
  local provider_raw="$2"
  local flag
  local provider

  flag="$(printf '%s' "${flag_raw}" | tr '[:upper:]' '[:lower:]')"
  provider="$(printf '%s' "${provider_raw}" | tr '[:upper:]' '[:lower:]')"

  case "${flag}" in
    1|true|yes|on)
      return 0
      ;;
    0|false|no|off)
      return 1
      ;;
    auto|"")
      case "${provider}" in
        ""|none|off|disabled|skip)
          return 1
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    *)
      echo "ERROR: invalid flag '${flag_raw}' (expected: auto|1|0|true|false|yes|no|on|off)" >&2
      exit 1
      ;;
  esac
}

run_interactive_wizard() {
  local mode_choice=""
  local provider_choice=""
  local vmid_choice=""
  local launch_now=""
  local auth_choice_default="n"
  local current_mode="${DEPLOY_FLOW:-full}"
  local current_proxy_provider="${PROXY_PROVIDER:-none}"
  local current_proxy_flag="${ENABLE_PROXY:-${ENABLE_PHASE5:-auto}}"
  local current_port_mode="auto"
  local current_vmid_policy="${PROXMOX_VMID_POLICY:-${PROXMOX_VMID_MODE:-nextid}}"
  local current_vmid_start="${PROXMOX_VMID_RANGE_START:-200}"
  local current_vmid_end="${PROXMOX_VMID_RANGE_END:-299}"

  wizard_configure_env_if_missing

  echo ""
  echo "=== Homelab Deploy Wizard ==="
  echo ""

  prompt_default APP_NAME "App name" "${APP_NAME:-myapp}"

  # ── Resume detection ─────────────────────────────────────────────────────────
  local _state_file _resume_from=""
  _state_file="$(_wizard_state_file_for "${APP_NAME}")"
  if [[ -f "${_state_file}" ]]; then
    _wizard_load_state "${_state_file}"
    _resume_from="$(_wizard_detect_resume_phase)"
    if [[ "${_resume_from}" != "done" && "${_resume_from}" != "1" ]]; then
      echo ""
      echo "  Incomplete deployment found for '${APP_NAME}':"
      [[ -n "${STARTED_AT:-}"  ]]                     && echo "    Started : ${STARTED_AT}"
      [[ -n "${VMID:-}"        ]]                     && echo "    VMID    : ${VMID}"
      [[ -n "${RESERVED_IP:-}" ]]                     && echo "    IP      : ${RESERVED_IP}"
      [[ "${PROVISION_STATUS:-}" == "ssh_ready" ]]    && echo "    VM      : ready (SSH up)"
      echo "    Resume  : starting from phase ${_resume_from}"
      echo ""
      local _do_resume=""
      read -r -p "Resume from phase ${_resume_from}? [Y/n]: " _do_resume
      _do_resume="$(printf '%s' "${_do_resume:-y}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${_do_resume}" != "n" && "${_do_resume}" != "no" ]]; then
        DEPLOY_RESUME="1"
        DEPLOY_RESUME_FROM="${_resume_from}"
        DEPLOY_STATE_FILE="${_state_file}"
        echo ""
        echo "Summary (resume):"
        echo "  App      : ${APP_NAME}"
        echo "  Target   : ${TARGET_IP}"
        echo "  Domain   : ${SUBDOMAIN}"
        echo "  Resume   : phase ${_resume_from}"
        echo ""
        read -r -p "Run now? [Y/n]: " launch_now
        launch_now="$(printf '%s' "${launch_now:-y}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${launch_now}" == "n" || "${launch_now}" == "no" ]]; then
          echo "Cancelled."
          exit 0
        fi
        return
      fi
    fi
  fi
  # ── End resume detection ──────────────────────────────────────────────────────

  prompt_default TARGET_IP "Target IP" "${TARGET_IP:-10.0.0.50}"
  prompt_default SUBDOMAIN "Subdomain" "${SUBDOMAIN:-myapp.example.com}"
  validate_app_name "${APP_NAME}"
  validate_ipv4 "${TARGET_IP}"

  case "${current_mode}" in
    full) mode_choice="1" ;;
    provision) mode_choice="2" ;;
    proxy) mode_choice="3" ;;
    *) mode_choice="1" ;;
  esac

  while true; do
    echo ""
    echo "Execution mode:"
    echo "  1) full      (provision VM + optional proxy)"
    echo "  2) provision (provision VM only)"
    echo "  3) proxy     (proxy only, for existing app)"
    read -r -p "Choice [${mode_choice}]: " current_mode
    current_mode="${current_mode:-${mode_choice}}"
    case "${current_mode}" in
      1) DEPLOY_FLOW="full"; break ;;
      2) DEPLOY_FLOW="provision"; break ;;
      3) DEPLOY_FLOW="proxy"; break ;;
      *) echo "Invalid choice." ;;
    esac
  done

  if [[ "${DEPLOY_FLOW}" == "full" || "${DEPLOY_FLOW}" == "provision" ]]; then
    case "${current_vmid_policy}" in
      nextid) vmid_choice="1" ;;
      range_first|range_seq|range_sequential) vmid_choice="2" ;;
      range_random) vmid_choice="3" ;;
      manual) vmid_choice="4" ;;
      *) vmid_choice="1" ;;
    esac

    while true; do
      echo ""
      echo "VMID allocation:"
      echo "  1) nextid       (Proxmox cluster next free ID)"
      echo "  2) range_first  (first free ID in a custom range)"
      echo "  3) range_random (random free ID in a custom range)"
      echo "  4) manual       (explicit VMID)"
      read -r -p "Choice [${vmid_choice}]: " current_vmid_policy
      current_vmid_policy="${current_vmid_policy:-${vmid_choice}}"
      case "${current_vmid_policy}" in
        1) PROXMOX_VMID_POLICY="nextid"; break ;;
        2) PROXMOX_VMID_POLICY="range_first"; break ;;
        3) PROXMOX_VMID_POLICY="range_random"; break ;;
        4) PROXMOX_VMID_POLICY="manual"; break ;;
        *) echo "Invalid choice." ;;
      esac
    done

    if [[ "${PROXMOX_VMID_POLICY}" == "range_first" || "${PROXMOX_VMID_POLICY}" == "range_random" ]]; then
      prompt_default PROXMOX_VMID_RANGE_START "VMID range start" "${current_vmid_start}"
      prompt_default PROXMOX_VMID_RANGE_END "VMID range end" "${current_vmid_end}"
      PROXMOX_VMID=""
    elif [[ "${PROXMOX_VMID_POLICY}" == "manual" ]]; then
      prompt_default PROXMOX_VMID "Manual VMID" "${PROXMOX_VMID:-200}"
      PROXMOX_VMID_RANGE_START="${current_vmid_start}"
      PROXMOX_VMID_RANGE_END="${current_vmid_end}"
    else
      PROXMOX_VMID=""
      PROXMOX_VMID_RANGE_START="${current_vmid_start}"
      PROXMOX_VMID_RANGE_END="${current_vmid_end}"
    fi
  fi

  if [[ "${DEPLOY_FLOW}" == "full" || "${DEPLOY_FLOW}" == "proxy" ]]; then
    case "${current_proxy_provider}" in
      none|off|disabled|skip) provider_choice="1" ;;
      zoraxy_api) provider_choice="2" ;;
      *) provider_choice="1" ;;
    esac

    while true; do
      echo ""
      echo "Proxy integration:"
      echo "  1) none"
      echo "  2) zoraxy_api"
      read -r -p "Proxy provider [${provider_choice}]: " current_proxy_provider
      current_proxy_provider="${current_proxy_provider:-${provider_choice}}"
      case "${current_proxy_provider}" in
        1) PROXY_PROVIDER="none"; break ;;
        2) PROXY_PROVIDER="zoraxy_api"; break ;;
        *) echo "Invalid choice." ;;
      esac
    done

    if [[ "${PROXY_PROVIDER}" == "zoraxy_api" ]]; then
      prompt_default ZORAXY_API_BASE "Zoraxy API base URL" "${ZORAXY_API_BASE:-http://zoraxy.example.com:8400}"

      if [[ -n "${ZORAXY_USERNAME:-}" || -n "${ZORAXY_PASSWORD:-}" ]]; then
        auth_choice_default="y"
      fi
      read -r -p "Use Zoraxy API login? [${auth_choice_default}/n]: " launch_now
      launch_now="$(printf '%s' "${launch_now:-${auth_choice_default}}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${launch_now}" == "y" || "${launch_now}" == "yes" ]]; then
        prompt_default ZORAXY_USERNAME "Zoraxy username" "${ZORAXY_USERNAME:-}"
        prompt_default ZORAXY_PASSWORD "Zoraxy password" "${ZORAXY_PASSWORD:-}" "1"
      else
        ZORAXY_USERNAME=""
        ZORAXY_PASSWORD=""
      fi

      if [[ -n "${PROXY_UPSTREAM_PORT:-}" ]]; then
        current_port_mode="manual"
      fi
      read -r -p "Upstream port mode (auto/manual) [${current_port_mode}]: " launch_now
      launch_now="$(printf '%s' "${launch_now:-${current_port_mode}}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${launch_now}" == "manual" || "${launch_now}" == "m" ]]; then
        prompt_default PROXY_UPSTREAM_PORT "Upstream port" "${PROXY_UPSTREAM_PORT:-80}"
        PROXY_AUTO_DETECT_PORT="false"
      else
        PROXY_UPSTREAM_PORT=""
        PROXY_AUTO_DETECT_PORT="true"
      fi
    fi
  fi

  if [[ "${DEPLOY_FLOW}" == "full" ]]; then
    prompt_default ENABLE_PROXY "Enable proxy step (auto|1|0)" "${current_proxy_flag}"
  elif [[ "${DEPLOY_FLOW}" == "proxy" ]]; then
    ENABLE_PROXY="1"
  else
    ENABLE_PROXY="0"
  fi

  echo ""
  echo "Summary:"
  echo "  App      : ${APP_NAME}"
  echo "  Target   : ${TARGET_IP}"
  echo "  Domain   : ${SUBDOMAIN}"
  echo "  Mode     : ${DEPLOY_FLOW}"
  echo "  VMID     : ${PROXMOX_VMID_POLICY:-nextid}"
  if [[ "${PROXMOX_VMID_POLICY:-nextid}" == "range_first" || "${PROXMOX_VMID_POLICY:-nextid}" == "range_random" ]]; then
    echo "  VMID rng : ${PROXMOX_VMID_RANGE_START:-200}-${PROXMOX_VMID_RANGE_END:-299}"
  elif [[ "${PROXMOX_VMID_POLICY:-nextid}" == "manual" ]]; then
    echo "  VMID val : ${PROXMOX_VMID:-unset}"
  fi
  echo "  Proxy    : ${PROXY_PROVIDER:-none}"
  echo ""
  read -r -p "Run now? [Y/n]: " launch_now
  launch_now="$(printf '%s' "${launch_now:-y}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${launch_now}" == "n" || "${launch_now}" == "no" ]]; then
    echo "Cancelled."
    exit 0
  fi
}

WIZARD_MODE="0"
DEPLOY_RESUME="0"
declare -a POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_usage
      exit 0
      ;;
    -r|--resume)
      DEPLOY_RESUME="1"
      shift
      ;;
    -w|--wizard|--interactive)
      WIZARD_MODE="1"
      shift
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        POSITIONAL_ARGS+=("$1")
        shift
      done
      ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      show_usage
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

if (( ${#POSITIONAL_ARGS[@]} > 0 )); then
  set -- "${POSITIONAL_ARGS[@]}"
else
  set --
fi

if [[ "${WIZARD_MODE}" == "1" || ( $# -eq 0 && -t 0 && -t 1 ) ]]; then
  run_interactive_wizard
elif [[ "${DEPLOY_RESUME}" == "1" ]]; then
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 --resume <app-name>" >&2
    exit 1
  fi
  APP_NAME="$1"
  validate_app_name "${APP_NAME}"
  # TARGET_IP and SUBDOMAIN will be loaded from state after libs are sourced
else
  if [[ $# -ne 3 ]]; then
    show_usage
    exit 1
  fi
  APP_NAME="$1"
  TARGET_IP="$2"
  SUBDOMAIN="$3"
  validate_app_name "${APP_NAME}"
  validate_ipv4 "${TARGET_IP}"
fi

for required_lib in \
  "${SCRIPT_DIR}/lib/common.sh" \
  "${SCRIPT_DIR}/lib/state.sh" \
  "${SCRIPT_DIR}/modules/proxmox.sh" \
  "${SCRIPT_DIR}/modules/dhcp.sh" \
  "${SCRIPT_DIR}/integrations/proxy.sh"
do
  if [[ ! -f "${required_lib}" ]]; then
    echo "ERROR: missing module: ${required_lib}" >&2
    exit 1
  fi
done

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/state.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/modules/proxmox.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/modules/dhcp.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/integrations/proxy.sh"

DEPLOY_RESUME="${DEPLOY_RESUME:-0}"
DEPLOY_RESUME_FROM="${DEPLOY_RESUME_FROM:-1}"

detect_resume_phase() {
  # Returns the first phase not yet completed: "1" "2" "3" "proxy" or "done"
  if [[ -z "${VMID:-}" || -z "${MAC_ADDRESS:-}" ]]; then echo "1"; return; fi
  if [[ -z "${KEA_RESERVATION_UUID:-}" ]];           then echo "2"; return; fi
  if [[ "${PROVISION_STATUS:-}" != "ssh_ready" ]];   then echo "3"; return; fi
  if [[ -z "${PROXY_STATUS:-}" ]];                   then echo "proxy"; return; fi
  echo "done"
}

_should_run_phase() {
  # Returns 0 (true) if the given phase should execute, 1 (false) if it should be skipped.
  # Phase arg: "1" "2" "3" or "proxy"
  [[ "${DEPLOY_RESUME}" != "1" ]] && return 0
  local -a order=("1" "2" "3" "proxy")
  local from_idx=0 phase_idx=0 i
  for i in "${!order[@]}"; do
    [[ "${order[$i]}" == "${DEPLOY_RESUME_FROM}" ]] && from_idx=$i
    [[ "${order[$i]}" == "$1" ]]                    && phase_idx=$i
  done
  [[ "${phase_idx}" -ge "${from_idx}" ]]
}

# Defaults (override via .env)
DEPLOY_FLOW="${DEPLOY_FLOW:-full}"

PROXMOX_HOST="${PROXMOX_HOST:-}"
PROXMOX_NODE="${PROXMOX_NODE:-}"
PROXMOX_TEMPLATE_ID="${PROXMOX_TEMPLATE_ID:-}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-}"
PROXMOX_VMID_POLICY="${PROXMOX_VMID_POLICY:-${PROXMOX_VMID_MODE:-nextid}}"
PROXMOX_VMID_RANGE_START="${PROXMOX_VMID_RANGE_START:-200}"
PROXMOX_VMID_RANGE_END="${PROXMOX_VMID_RANGE_END:-299}"
PROXMOX_VMID="${PROXMOX_VMID:-}"

SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/deploy_automation}"
SSH_USER="${SSH_USER:-root}"

OPNSENSE_HOST="${OPNSENSE_HOST:-}"
OPNSENSE_API_KEY="${OPNSENSE_API_KEY:-}"
OPNSENSE_API_SECRET="${OPNSENSE_API_SECRET:-}"

DEPLOY_STATE_DIR="${DEPLOY_STATE_DIR:-${SCRIPT_DIR}/.deploy-state}"
PROXY_PROVIDER="${PROXY_PROVIDER:-none}"
ZORAXY_API_BASE="${ZORAXY_API_BASE:-}"
ZORAXY_USERNAME="${ZORAXY_USERNAME:-}"
ZORAXY_PASSWORD="${ZORAXY_PASSWORD:-}"

ENABLE_PROXY="${ENABLE_PROXY:-${ENABLE_PHASE5:-auto}}"

DEPLOY_FLOW="$(printf '%s' "${DEPLOY_FLOW}" | tr '[:upper:]' '[:lower:]')"
case "${DEPLOY_FLOW}" in
  full|provision|proxy)
    ;;
  *)
    echo "ERROR: invalid DEPLOY_FLOW '${DEPLOY_FLOW}' (expected: full|provision|proxy)" >&2
    exit 1
    ;;
esac

PROXMOX_VMID_POLICY="$(printf '%s' "${PROXMOX_VMID_POLICY}" | tr '[:upper:]' '[:lower:]')"
case "${PROXMOX_VMID_POLICY}" in
  nextid|range_first|range_random|manual)
    ;;
  range_seq|range_sequential)
    PROXMOX_VMID_POLICY="range_first"
    ;;
  *)
    echo "ERROR: invalid PROXMOX_VMID_POLICY '${PROXMOX_VMID_POLICY}' (expected: nextid|range_first|range_random|manual)" >&2
    exit 1
    ;;
esac

if [[ "${DEPLOY_FLOW}" == "full" || "${DEPLOY_FLOW}" == "provision" ]]; then
  require_var PROXMOX_HOST "example: pve.example.com:8006"
  require_var PROXMOX_NODE "example: pve"
  require_var PROXMOX_TEMPLATE_ID "cloud-init template VMID"
  require_var PROXMOX_STORAGE "example: local-lvm"
  require_var PROXMOX_TOKEN_ID "example: root@pam!deploy"
  require_var PROXMOX_TOKEN_SECRET
  require_var OPNSENSE_HOST "OPNsense host/IP"
  require_var OPNSENSE_API_KEY
  require_var OPNSENSE_API_SECRET
fi

if [[ "${DEPLOY_FLOW}" == "full" || "${DEPLOY_FLOW}" == "proxy" ]]; then
  if should_run_flag "${ENABLE_PROXY}" "${PROXY_PROVIDER}" && [[ "${PROXY_PROVIDER}" == "zoraxy_api" ]]; then
    require_var ZORAXY_API_BASE "example: http://zoraxy.example.com:8400"
  fi
fi

init_common_context

if [[ "${DEPLOY_RESUME}" == "1" ]]; then
  if [[ -z "${DEPLOY_STATE_FILE:-}" ]]; then
    # CLI --resume path: libs are now sourced, resolve state file
    DEPLOY_STATE_FILE="$(state_file_for "${APP_NAME}")"
    export DEPLOY_STATE_FILE
    if [[ ! -f "${DEPLOY_STATE_FILE}" ]]; then
      echo "ERROR: no deployment state found for '${APP_NAME}' at ${DEPLOY_STATE_FILE}" >&2
      exit 1
    fi
    state_load
    TARGET_IP="${TARGET_IP:-}"
    SUBDOMAIN="${SUBDOMAIN:-}"
    if [[ -z "${TARGET_IP}" || -z "${SUBDOMAIN}" ]]; then
      echo "ERROR: state file is missing TARGET_IP or SUBDOMAIN" >&2
      exit 1
    fi
    DEPLOY_RESUME_FROM="$(detect_resume_phase)"
  fi
  log "Resuming '${APP_NAME}' (phase ${DEPLOY_RESUME_FROM}) — rollback disabled."
else
  state_begin_run "${APP_NAME}" "${TARGET_IP}" "${SUBDOMAIN}"
fi

_rollback_on_failure() {
  log "Deploy failed — starting rollback..."

  local vmid
  vmid="$(state_get VMID 2>/dev/null || true)"
  if [[ -n "${vmid}" ]]; then
    log "Rollback: force-stopping VM ${vmid}..."
    pve_post "/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/stop" \
      --data-urlencode "forcestop=1" > /dev/null 2>&1 || true
    sleep 3
    log "Rollback: deleting VM ${vmid}..."
    pve_delete "/nodes/${PROXMOX_NODE}/qemu/${vmid}" > /dev/null 2>&1 || true
    log "Rollback: VM ${vmid} removed."
  fi

  local reservation_uuid
  reservation_uuid="$(state_get KEA_RESERVATION_UUID 2>/dev/null || true)"
  if [[ -n "${reservation_uuid}" ]]; then
    log "Rollback: deleting DHCP reservation ${reservation_uuid}..."
    opn_delete "/kea/dhcpv4/delReservation/${reservation_uuid}" > /dev/null 2>&1 || true
    opn_post "/kea/service/reconfigure" '{}' > /dev/null 2>&1 || true
    log "Rollback: DHCP reservation removed."
  fi
}

case "${DEPLOY_FLOW}" in
  full)
    if [[ "${DEPLOY_RESUME}" != "1" ]]; then trap '_rollback_on_failure' ERR; fi
    if _should_run_phase "1"; then
      phase1_proxmox_prepare
    else
      log "Skipping phase1 — VM already cloned (VMID=${VMID})."
    fi
    if _should_run_phase "2"; then
      phase2_dhcp_reserve_kea
    else
      log "Skipping phase2 — DHCP reservation already exists."
    fi
    if _should_run_phase "3"; then
      phase3_proxmox_boot_and_wait
    else
      log "Skipping phase3 — VM already SSH-ready."
    fi
    trap - ERR

    if should_run_flag "${ENABLE_PROXY}" "${PROXY_PROVIDER}"; then
      proxy_apply
    else
      log "Proxy step skipped (ENABLE_PROXY=${ENABLE_PROXY}, PROXY_PROVIDER=${PROXY_PROVIDER})."
    fi
    ;;
  provision)
    if [[ "${DEPLOY_RESUME}" != "1" ]]; then trap '_rollback_on_failure' ERR; fi
    log "Running in provision mode (VM provisioning only)."
    if _should_run_phase "1"; then
      phase1_proxmox_prepare
    else
      log "Skipping phase1 — VM already cloned (VMID=${VMID})."
    fi
    if _should_run_phase "2"; then
      phase2_dhcp_reserve_kea
    else
      log "Skipping phase2 — DHCP reservation already exists."
    fi
    if _should_run_phase "3"; then
      phase3_proxmox_boot_and_wait
    else
      log "Skipping phase3 — VM already SSH-ready."
    fi
    trap - ERR
    log "Proxy step not executed in provision mode."
    ;;
  proxy)
    log "Running in proxy mode (proxy only)."
    if should_run_flag "${ENABLE_PROXY}" "${PROXY_PROVIDER}"; then
      proxy_apply
    else
      log "Proxy step skipped (ENABLE_PROXY=${ENABLE_PROXY}, PROXY_PROVIDER=${PROXY_PROVIDER})."
    fi
    ;;
esac

VMID="$(state_get VMID)"
MAC_ADDRESS="$(state_get MAC_ADDRESS)"

echo ""
echo "  App       : ${APP_NAME}"
echo "  VM ID     : ${VMID}"
echo "  MAC       : ${MAC_ADDRESS}"
echo "  IP        : ${TARGET_IP}"
echo "  Domain    : ${SUBDOMAIN}"
echo "  Mode      : ${DEPLOY_FLOW}"
echo "  State file: ${DEPLOY_STATE_FILE}"
echo ""
