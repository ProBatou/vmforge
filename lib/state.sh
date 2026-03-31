#!/usr/bin/env bash

state_begin_run() {
  local app_name="$1"
  local target_ip="$2"
  local subdomain="$3"
  local safe_name

  safe_name="$(sanitize_name "${app_name}")"
  if [[ -z "${safe_name}" ]]; then
    safe_name="app"
  fi

  mkdir -p "${DEPLOY_STATE_DIR}"
  DEPLOY_STATE_FILE="${DEPLOY_STATE_DIR}/${safe_name}.env"
  export DEPLOY_STATE_FILE

  local old_umask
  old_umask="$(umask)"
  umask 077
  cat > "${DEPLOY_STATE_FILE}" <<EOF
APP_NAME=$(printf '%q' "${app_name}")
TARGET_IP=$(printf '%q' "${target_ip}")
SUBDOMAIN=$(printf '%q' "${subdomain}")
STARTED_AT=$(printf '%q' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
EOF
  umask "${old_umask}"
}

state_load() {
  if [[ -f "${DEPLOY_STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${DEPLOY_STATE_FILE}"
  fi
}

state_file_for() {
  local app_name="$1"
  local safe_name
  safe_name="$(sanitize_name "${app_name}")"
  if [[ -z "${safe_name}" ]]; then safe_name="app"; fi
  printf '%s/%s.env' "${DEPLOY_STATE_DIR}" "${safe_name}"
}

state_set() {
  local key="$1"
  local value="$2"
  local tmp_file old_umask

  if [[ ! "${key}" =~ ^[A-Z0-9_]+$ ]]; then
    echo "ERROR: invalid state key '${key}'" >&2
    exit 1
  fi

  if [[ -z "${DEPLOY_STATE_FILE:-}" ]]; then
    echo "ERROR: DEPLOY_STATE_FILE is not initialized" >&2
    exit 1
  fi

  old_umask="$(umask)"
  umask 077
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/deploy-state.${key}.XXXXXX")"
  umask "${old_umask}"

  if [[ -f "${DEPLOY_STATE_FILE}" ]]; then
    grep -v "^${key}=" "${DEPLOY_STATE_FILE}" > "${tmp_file}" || true
  fi
  printf "%s=%q\n" "${key}" "${value}" >> "${tmp_file}"
  mv "${tmp_file}" "${DEPLOY_STATE_FILE}"
  export "${key}=${value}"
}

state_get() {
  local key="$1"
  state_load
  printf '%s' "${!key:-}"
}
