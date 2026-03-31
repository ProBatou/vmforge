#!/usr/bin/env bash

proxmox_collect_used_vmids() {
  pve_get "/cluster/resources?type=vm" \
    | jq -r '.data[] | select(.vmid != null) | .vmid | tostring' \
    | tr '\n' ' '
}

# Pick a free VMID from [range_start..range_end] excluding used_ids (space-separated list).
# policy: range_first | range_random
_proxmox_pick_vmid_from_range() {
  local policy="$1"
  local range_start="$2"
  local range_end="$3"
  local used_ids="$4"

  local -A used_set=()
  local id
  for id in ${used_ids}; do
    [[ "${id}" =~ ^[0-9]+$ ]] && used_set["${id}"]=1
  done

  local -a free=()
  local candidate
  for (( candidate=range_start; candidate<=range_end; candidate++ )); do
    if [[ -z "${used_set["${candidate}"]:-}" ]]; then
      free+=("${candidate}")
    fi
  done

  if (( ${#free[@]} == 0 )); then
    echo "ERROR: VMID range ${range_start}-${range_end} is full" >&2
    exit 1
  fi

  if [[ "${policy}" == "range_random" ]]; then
    local idx=$(( RANDOM % ${#free[@]} ))
    printf '%s' "${free[${idx}]}"
  else
    printf '%s' "${free[0]}"
  fi
}

# Abort if vmid is already present in used_ids (space-separated list).
_proxmox_check_vmid_free() {
  local vmid="$1"
  local used_ids="$2"
  local id
  for id in ${used_ids}; do
    if [[ "${id}" == "${vmid}" ]]; then
      echo "ERROR: manual VMID ${vmid} is already in use" >&2
      exit 1
    fi
  done
}

proxmox_choose_vmid() {
  local vmid_policy vmid used_ids range_start range_end

  vmid_policy="$(printf '%s' "${PROXMOX_VMID_POLICY:-nextid}" | tr '[:upper:]' '[:lower:]')"

  case "${vmid_policy}" in
    nextid)
      log "Requesting next free VMID from Proxmox cluster..."
      vmid="$(pve_get "/cluster/nextid" | jq -r '.data')"
      ;;
    range_first|range_random|range_seq|range_sequential)
      range_start="${PROXMOX_VMID_RANGE_START:-200}"
      range_end="${PROXMOX_VMID_RANGE_END:-299}"

      if [[ ! "${range_start}" =~ ^[0-9]+$ ]] || [[ ! "${range_end}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: PROXMOX_VMID_RANGE_START and PROXMOX_VMID_RANGE_END must be integers." >&2
        exit 1
      fi
      if (( range_start > range_end )); then
        echo "ERROR: invalid VMID range ${range_start}-${range_end} (start > end)." >&2
        exit 1
      fi

      if [[ "${vmid_policy}" == "range_random" ]]; then
        log "Looking for random free VMID in range ${range_start}-${range_end}..."
      else
        log "Looking for first free VMID in range ${range_start}-${range_end}..."
      fi

      used_ids="$(proxmox_collect_used_vmids)"
      vmid="$(_proxmox_pick_vmid_from_range "${vmid_policy}" "${range_start}" "${range_end}" "${used_ids}")"
      ;;
    manual)
      require_var PROXMOX_VMID "set PROXMOX_VMID when PROXMOX_VMID_POLICY=manual"
      vmid="${PROXMOX_VMID}"
      if [[ ! "${vmid}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: PROXMOX_VMID must be an integer when PROXMOX_VMID_POLICY=manual." >&2
        exit 1
      fi
      used_ids="$(proxmox_collect_used_vmids)"
      _proxmox_check_vmid_free "${vmid}" "${used_ids}"
      log "Using manual VMID: ${vmid}"
      ;;
    *)
      echo "ERROR: invalid PROXMOX_VMID_POLICY '${PROXMOX_VMID_POLICY}'" >&2
      echo "Expected: nextid | range_first | range_random | manual" >&2
      exit 1
      ;;
  esac

  printf '%s' "${vmid}"
}

phase1_proxmox_prepare() {
  log "=== Proxmox setup (clone + MAC + cloud-init) ==="

  require_file "${SSH_KEY_FILE}.pub" "Generate with: ssh-keygen -t ed25519 -C 'deploy-automation' -f ${SSH_KEY_FILE} -N ''"
  require_file "${SSH_KEY_FILE}"

  local vmid ssh_pub_key clone_upid net0 mac_address ssh_pub_key_encoded

  vmid="$(proxmox_choose_vmid)"
  state_set VMID "${vmid}"
  log "Selected VMID: ${vmid}"

  ssh_pub_key="$(cat "${SSH_KEY_FILE}.pub")"

  log "Cloning template ${PROXMOX_TEMPLATE_ID} -> VM ${vmid} (${APP_NAME})..."
  clone_upid="$(pve_post "/nodes/${PROXMOX_NODE}/qemu/${PROXMOX_TEMPLATE_ID}/clone" \
    --data-urlencode "newid=${vmid}" \
    --data-urlencode "name=${APP_NAME}" \
    --data-urlencode "full=1" \
    --data-urlencode "storage=${PROXMOX_STORAGE}" \
    | jq -r '.data')"
  log "Clone task UPID: ${clone_upid}"
  pve_wait_task "${clone_upid}"

  log "Reading VM MAC address from net0..."
  net0="$(pve_get "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" | jq -r '.data.net0')"
  # net0 format: "virtio=BC:24:11:AA:BB:CC,bridge=vmbr0,..." or "e1000=..."
  mac_address="${net0#*=}"       # strip driver type and '='
  mac_address="${mac_address%%,*}" # strip everything from first ','
  state_set MAC_ADDRESS "${mac_address}"
  log "MAC address: ${mac_address}"

  log "Applying cloud-init SSH key..."
  # Proxmox expects the sshkeys value to be URL-encoded within the form data
  ssh_pub_key_encoded="$(urlencode "${ssh_pub_key}")"
  pve_put "/nodes/${PROXMOX_NODE}/qemu/${vmid}/config" \
    --data-urlencode "sshkeys=${ssh_pub_key_encoded}" \
    > /dev/null
  log "Cloud-init updated."

  log "=== Proxmox setup complete: VM ${APP_NAME} (${vmid}), MAC ${mac_address} ==="
}

phase3_proxmox_boot_and_wait() {
  log "=== Boot VM and wait for SSH ==="

  local vmid start_upid
  local ssh_timeout="${SSH_WAIT_TIMEOUT:-300}"
  local ssh_interval=5
  local elapsed=0
  local ci_timeout="${CLOUD_INIT_TIMEOUT:-120}"
  local ci_elapsed=0

  vmid="${VMID:-$(state_get VMID)}"
  if [[ -z "${vmid}" ]]; then
    echo "ERROR: VMID is missing (did the clone step run?)" >&2
    exit 1
  fi

  log "Starting VM ${vmid}..."
  start_upid="$(pve_post "/nodes/${PROXMOX_NODE}/qemu/${vmid}/status/start" \
    | jq -r '.data')"
  log "Start task UPID: ${start_upid}"
  pve_wait_task "${start_upid}"

  log "Waiting for SSH on ${TARGET_IP}:22 (timeout ${ssh_timeout}s)..."
  until ssh-keyscan -T 3 -p 22 "${TARGET_IP}" &>/dev/null; do
    if (( elapsed >= ssh_timeout )); then
      echo "ERROR: SSH is not reachable on ${TARGET_IP} after ${ssh_timeout}s" >&2
      exit 1
    fi
    sleep "${ssh_interval}"
    elapsed=$(( elapsed + ssh_interval ))
    log "  ...${elapsed}s elapsed, SSH still not reachable"
  done
  log "SSH is reachable on ${TARGET_IP} (${elapsed}s)."

  log "Waiting for cloud-init completion marker..."
  until ssh_remote "test -f /var/lib/cloud/instance/boot-finished" 2>/dev/null; do
    if (( ci_elapsed >= ci_timeout )); then
      log "  cloud-init wait timeout reached; continuing."
      break
    fi
    sleep 5
    ci_elapsed=$(( ci_elapsed + 5 ))
  done
  log "Cloud-init completed (or timeout reached)."

  state_set PROVISION_STATUS "ssh_ready"
  log "=== VM is ready on ${TARGET_IP} ==="
}
