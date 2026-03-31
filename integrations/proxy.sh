#!/usr/bin/env bash

proxy_apply() {
  local provider="${PROXY_PROVIDER:-none}"
  case "${provider}" in
    none|off|disabled|skip)
      log "Proxy integration skipped (PROXY_PROVIDER=${provider})."
      state_set PROXY_STATUS "skipped"
      state_set PROXY_PROVIDER "none"
      return 0
      ;;
    zoraxy_api)
      proxy_apply_zoraxy_api
      ;;
    *)
      echo "ERROR: unknown proxy provider '${provider}' (expected: zoraxy_api|none)" >&2
      return 1
      ;;
  esac
}

proxy_endpoint_responds() {
  local host="$1"
  local port="$2"
  local use_tls="$3"
  local probe_timeout="${4:-2}"
  local code="000"

  if [[ "${use_tls}" == "true" ]]; then
    code="$(curl -ks --max-time "${probe_timeout}" -o /dev/null -w "%{http_code}" "https://${host}:${port}/" || true)"
    [[ "${code}" != "000" ]]
    return
  fi

  code="$(curl -s --max-time "${probe_timeout}" -o /dev/null -w "%{http_code}" "http://${host}:${port}/" || true)"
  if [[ "${code}" == "000" ]]; then
    code="$(curl -ks --max-time "${probe_timeout}" -o /dev/null -w "%{http_code}" "https://${host}:${port}/" || true)"
  fi
  [[ "${code}" != "000" ]]
}

proxy_resolve_upstream_port() {
  local host="$1"
  local use_tls="$2"
  local configured_port="${PROXY_UPSTREAM_PORT:-${APP_PORT:-${HEALTHCHECK_PORT:-}}}"
  local auto_detect="${PROXY_AUTO_DETECT_PORT:-true}"
  local candidates_csv="${PROXY_PORT_CANDIDATES:-80,8080,3000,3001,5000,5173,8000,8081,9000,8443,443}"
  local strategy="${PROXY_AUTO_PORT_STRATEGY:-first}"
  local probe_timeout="${PROXY_PORT_PROBE_TIMEOUT:-2}"
  local candidate
  local -a candidates=()
  local -a detected=()

  auto_detect="$(printf '%s' "${auto_detect}" | tr '[:upper:]' '[:lower:]')"
  strategy="$(printf '%s' "${strategy}" | tr '[:upper:]' '[:lower:]')"

  if [[ -n "${configured_port}" ]]; then
    echo "${configured_port}"
    return 0
  fi

  case "${auto_detect}" in
    1|true|yes|on)
      ;;
    *)
      echo "ERROR: upstream port is unknown. Set PROXY_UPSTREAM_PORT or enable PROXY_AUTO_DETECT_PORT=true." >&2
      return 1
      ;;
  esac

  IFS=',' read -r -a candidates <<< "${candidates_csv}"
  for candidate in "${candidates[@]}"; do
    candidate="${candidate//[[:space:]]/}"
    [[ "${candidate}" =~ ^[0-9]+$ ]] || continue
    if proxy_endpoint_responds "${host}" "${candidate}" "${use_tls}" "${probe_timeout}"; then
      detected+=("${candidate}")
    fi
  done

  if (( ${#detected[@]} == 0 )); then
    echo "ERROR: no HTTP(S) port detected on ${host}. Set PROXY_UPSTREAM_PORT manually." >&2
    return 1
  fi

  if (( ${#detected[@]} == 1 )); then
    echo "INFO: auto-detected upstream port: ${detected[0]}" >&2
    echo "${detected[0]}"
    return 0
  fi

  case "${strategy}" in
    strict)
      echo "ERROR: multiple candidate ports detected (${detected[*]}). Set PROXY_UPSTREAM_PORT." >&2
      return 1
      ;;
    first|*)
      echo "INFO: multiple ports detected (${detected[*]}), selecting ${detected[0]} (set PROXY_AUTO_PORT_STRATEGY=strict to fail instead)." >&2
      echo "${detected[0]}"
      return 0
      ;;
  esac
}

proxy_apply_zoraxy_api() {
  log "=== Proxy integration (Zoraxy API) ==="

  local api_base="${ZORAXY_API_BASE:-}"
  local upstream_host="${PROXY_UPSTREAM_HOST:-${TARGET_IP}}"
  local upstream_port
  local upstream
  local use_tls_upstream="${PROXY_UPSTREAM_TLS:-false}"
  local skip_tls_validation="${PROXY_SKIP_TLS_VALIDATION:-false}"
  local skip_websocket_origin_check="${PROXY_SKIP_WS_ORIGIN_CHECK:-true}"
  local bypass_global_tls="${PROXY_BYPASS_GLOBAL_TLS:-false}"
  local require_basic_auth="${PROXY_REQUIRE_BASIC_AUTH:-false}"
  local require_rate_limit="${PROXY_REQUIRE_RATE_LIMIT:-false}"
  local rate_limit="${PROXY_RATE_LIMIT:-1000}"
  local access_rule="${PROXY_ACCESS_RULE:-default}"
  local sticky_session="${PROXY_STICKY_SESSION:-false}"
  local tags="${PROXY_TAGS:-homelab,${APP_NAME}}"
  local enable_utm="${PROXY_ENABLE_UTM:-true}"
  local disable_log="${PROXY_DISABLE_LOG:-false}"
  local disable_stats="${PROXY_DISABLE_STATS:-false}"
  local block_common_exploits="${PROXY_BLOCK_COMMON_EXPLOITS:-false}"
  local block_ai_crawlers="${PROXY_BLOCK_AI_CRAWLERS:-false}"
  local mitigation_action="${PROXY_MITIGATION_ACTION:-0}"
  local basic_auth_json="${PROXY_BASIC_AUTH_JSON:-[]}"
  local tmp_dir cookie_file html_file csrf_token list_json
  local existing_rule existing_origin existing_tls

  if [[ -z "${api_base}" ]]; then
    echo "ERROR: ZORAXY_API_BASE is not set (example: http://zoraxy.example.com:8400)" >&2
    return 1
  fi

  upstream_port="$(proxy_resolve_upstream_port "${upstream_host}" "${use_tls_upstream}")" || return 1
  upstream="${upstream_host}:${upstream_port}"

  local old_umask
  old_umask="$(umask)"
  umask 077
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zoraxy-proxy.XXXXXX")"
  umask "${old_umask}"
  cookie_file="${tmp_dir}/cookies.txt"
  html_file="${tmp_dir}/index.html"
  trap 'rm -rf "${tmp_dir}"' RETURN

  log "Initializing Zoraxy API session (${api_base})..."
  curl -fsS --max-time 10 -c "${cookie_file}" "${api_base}/" > "${html_file}"

  # Extract CSRF token from the meta tag: <meta name="zoraxy.csrf.Token" content="...">
  csrf_token="$(sed -n 's/.*meta name="zoraxy\.csrf\.Token" content="\([^"]*\)".*/\1/p' "${html_file}" | head -1)"
  if [[ -z "${csrf_token}" ]]; then
    echo "ERROR: could not find Zoraxy CSRF token." >&2
    return 1
  fi

  if [[ -n "${ZORAXY_USERNAME:-}" || -n "${ZORAXY_PASSWORD:-}" ]]; then
    log "Authenticating to Zoraxy API..."
    curl -fsS --max-time 10 \
      -b "${cookie_file}" \
      -H "X-CSRF-Token: ${csrf_token}" \
      -X POST "${api_base}/api/auth/login" \
      --data-urlencode "username=${ZORAXY_USERNAME:-}" \
      --data-urlencode "password=${ZORAXY_PASSWORD:-}" \
      > /dev/null
  fi

  list_json="$(curl -fsS --max-time 10 "${api_base}/api/proxy/list?type=host")"

  # Check for API-level error response
  if printf '%s' "${list_json}" | jq -e 'type == "object" and has("error")' > /dev/null 2>&1; then
    local err_msg
    err_msg="$(printf '%s' "${list_json}" | jq -r '.error')"
    echo "ERROR: /api/proxy/list failed (${err_msg})" >&2
    return 1
  fi

  # Find existing rule for our subdomain (case-insensitive)
  existing_rule="$(printf '%s' "${list_json}" | jq -r \
    --arg domain "${SUBDOMAIN}" \
    '( [ .[] | select( (.RootOrMatchingDomain // "") | ascii_downcase == ($domain | ascii_downcase) ) ] ) as $m |
     if ($m | length) == 0 then
       "MISSING"
     else
       ( $m[0].ActiveOrigins // [] ) as $o |
       if ($o | length) > 0 then
         "FOUND\t" + ($o[0].OriginIpOrDomain // "") + "\t" + (if $o[0].RequireTLS then "true" else "false" end)
       else
         "FOUND\t\tfalse"
       end
     end')"

  if [[ "${existing_rule}" == FOUND$'\t'* ]]; then
    existing_origin="$(printf '%s' "${existing_rule}" | cut -f2)"
    existing_tls="$(printf '%s' "${existing_rule}" | cut -f3)"
    if [[ "${existing_origin}" == "${upstream}" && "${existing_tls}" == "${use_tls_upstream}" ]]; then
      log "Proxy rule already correct for ${SUBDOMAIN} -> ${upstream} (TLS upstream=${use_tls_upstream})."
      state_set PROXY_STATUS "already_present"
      state_set PROXY_PROVIDER "zoraxy_api"
      state_set PROXY_UPSTREAM "${upstream}"
      trap - RETURN
      rm -rf "${tmp_dir}"
      return 0
    fi

    log "Existing rule differs (${existing_origin}, TLS=${existing_tls}); deleting before recreation."
    curl -fsS --max-time 10 \
      -b "${cookie_file}" \
      -H "X-CSRF-Token: ${csrf_token}" \
      -X POST "${api_base}/api/proxy/del" \
      --data-urlencode "ep=${SUBDOMAIN}" \
      > /dev/null
  fi

  log "Creating proxy rule: ${SUBDOMAIN} -> ${upstream} (TLS upstream=${use_tls_upstream})..."
  curl -fsS --max-time 10 \
    -b "${cookie_file}" \
    -H "X-CSRF-Token: ${csrf_token}" \
    -X POST "${api_base}/api/proxy/add" \
    --data-urlencode "type=host" \
    --data-urlencode "rootname=${SUBDOMAIN}" \
    --data-urlencode "tls=${use_tls_upstream}" \
    --data-urlencode "ep=${upstream}" \
    --data-urlencode "tlsval=${skip_tls_validation}" \
    --data-urlencode "bpwsorg=${skip_websocket_origin_check}" \
    --data-urlencode "bypassGlobalTLS=${bypass_global_tls}" \
    --data-urlencode "bauth=${require_basic_auth}" \
    --data-urlencode "rate=${require_rate_limit}" \
    --data-urlencode "ratenum=${rate_limit}" \
    --data-urlencode "cred=${basic_auth_json}" \
    --data-urlencode "access=${access_rule}" \
    --data-urlencode "stickysess=${sticky_session}" \
    --data-urlencode "tags=${tags}" \
    --data-urlencode "enableUtm=${enable_utm}" \
    --data-urlencode "disableLog=${disable_log}" \
    --data-urlencode "dStatisticCollection=${disable_stats}" \
    --data-urlencode "blockCommonExploits=${block_common_exploits}" \
    --data-urlencode "blockAICrawlers=${block_ai_crawlers}" \
    --data-urlencode "mitigationAction=${mitigation_action}" \
    > /dev/null

  # Verify the rule was created correctly
  list_json="$(curl -fsS --max-time 10 "${api_base}/api/proxy/list?type=host")"
  local verify_result
  verify_result="$(printf '%s' "${list_json}" | jq -r \
    --arg domain "${SUBDOMAIN}" \
    --arg target "${upstream}" \
    --argjson tls_target "$([ "${use_tls_upstream}" = "true" ] && echo "true" || echo "false")" \
    '( [ .[] | select( (.RootOrMatchingDomain // "") | ascii_downcase == ($domain | ascii_downcase) ) ] ) as $m |
     if ($m | length) == 0 then "MISSING"
     else
       ( $m[0].ActiveOrigins // [] ) as $o |
       if ($o | length) == 0 then "NO_ORIGINS"
       elif ($o[0].OriginIpOrDomain == $target) and (($o[0].RequireTLS // false) == $tls_target) then "OK"
       else "MISMATCH\t" + ($o[0].OriginIpOrDomain // "") + " tls=" + (($o[0].RequireTLS // false) | tostring)
       end
     end')"

  case "${verify_result}" in
    OK) ;;
    MISSING)
      echo "ERROR: proxy rule is missing after creation" >&2
      return 1
      ;;
    NO_ORIGINS)
      echo "ERROR: proxy rule created but no active upstream found" >&2
      return 1
      ;;
    MISMATCH*)
      echo "ERROR: proxy rule created but upstream mismatch: ${verify_result#MISMATCH	}" >&2
      return 1
      ;;
  esac

  state_set PROXY_STATUS "completed"
  state_set PROXY_PROVIDER "zoraxy_api"
  state_set PROXY_UPSTREAM "${upstream}"
  state_set PROXY_UPSTREAM_TLS "${use_tls_upstream}"
  state_set PROXY_API_BASE "${api_base}"

  log "=== Proxy integration completed: ${SUBDOMAIN} -> ${upstream} ==="

  trap - RETURN
  rm -rf "${tmp_dir}"
}

# Backward-compatible aliases
phase5_proxy_apply() { proxy_apply "$@"; }
phase5_zoraxy_api_apply() { proxy_apply_zoraxy_api "$@"; }
