#!/usr/bin/env bash

# Convert dotted IPv4 address to a 32-bit integer.
_ip_to_int() {
  local ip="$1"
  local a b c d
  IFS='.' read -r a b c d <<< "${ip}"
  printf '%d' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

# Return 0 if <ip> falls within <cidr> (e.g. "192.168.1.5" "192.168.1.0/24").
_ip_in_subnet() {
  local ip="$1" cidr="$2"
  local subnet_ip="${cidr%/*}"
  local prefix="${cidr#*/}"

  [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 0 && prefix <= 32 )) || return 1
  (( prefix == 0 )) && return 0

  local ip_int subnet_int mask
  ip_int="$(_ip_to_int "${ip}")"
  subnet_int="$(_ip_to_int "${subnet_ip}")"
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  (( (ip_int & mask) == (subnet_int & mask) ))
}

phase2_dhcp_reserve_kea() {
  log "=== DHCP reservation (OPNsense Kea) ==="

  local mac_address subnet_uuid reservation_result reservation_status reservation_uuid

  mac_address="${MAC_ADDRESS:-$(state_get MAC_ADDRESS)}"
  if [[ -z "${mac_address}" ]]; then
    echo "ERROR: MAC_ADDRESS is missing (did the clone step run?)" >&2
    exit 1
  fi

  log "Finding Kea subnet for target IP ${TARGET_IP}..."
  local subnets_json row_count i row_uuid row_subnet
  subnets_json="$(opn_post "/kea/dhcpv4/searchSubnet" '{}')"
  row_count="$(printf '%s' "${subnets_json}" | jq '.rows | length')"

  subnet_uuid=""
  for (( i=0; i<row_count; i++ )); do
    row_uuid="$(printf '%s' "${subnets_json}" | jq -r ".rows[${i}].uuid")"
    row_subnet="$(printf '%s' "${subnets_json}" | jq -r ".rows[${i}].subnet")"
    if _ip_in_subnet "${TARGET_IP}" "${row_subnet}"; then
      subnet_uuid="${row_uuid}"
      break
    fi
  done

  if [[ -z "${subnet_uuid}" ]]; then
    echo "ERROR: no Kea subnet contains ${TARGET_IP}" >&2
    echo "Check /api/kea/dhcpv4/searchSubnet on OPNsense." >&2
    exit 1
  fi
  state_set KEA_SUBNET_UUID "${subnet_uuid}"
  log "Matched subnet UUID: ${subnet_uuid}"

  log "Creating DHCP reservation ${mac_address} -> ${TARGET_IP} (${APP_NAME})..."
  reservation_result="$(opn_post "/kea/dhcpv4/addReservation" \
    "{\"reservation\":{\"subnet\":\"${subnet_uuid}\",\"hw_address\":\"${mac_address}\",\"ip_address\":\"${TARGET_IP}\",\"hostname\":\"${APP_NAME}\"}}")"
  reservation_status="$(printf '%s' "${reservation_result}" | jq -r '.result // "unknown"')"

  if [[ "${reservation_status}" != "saved" ]]; then
    echo "ERROR: failed to create Kea reservation (result: ${reservation_status})" >&2
    echo "Full API response: ${reservation_result}" >&2
    exit 1
  fi

  reservation_uuid="$(printf '%s' "${reservation_result}" | jq -r '.uuid // ""')"
  if [[ -n "${reservation_uuid}" ]]; then
    state_set KEA_RESERVATION_UUID "${reservation_uuid}"
  fi
  log "Reservation created."

  log "Applying Kea configuration (reconfigure)..."
  opn_post "/kea/service/reconfigure" '{}' > /dev/null
  log "Kea configuration applied."

  state_set RESERVED_IP "${TARGET_IP}"
  log "=== DHCP reservation complete: ${mac_address} -> ${TARGET_IP} ==="
}
