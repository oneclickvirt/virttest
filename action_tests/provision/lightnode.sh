#!/usr/bin/env bash
set -euo pipefail

EXIT_OK=0
EXIT_USAGE=2
EXIT_PROVIDER_UNAVAILABLE=3
EXIT_PROVIDER_FAILURE=4

LIGHTNODE_API_BASE="${LIGHTNODE_API_BASE:-https://openapi.lightnode.com}"
LIGHTNODE_TOKEN="${LIGHTNODE_TOKEN:-}"
LIGHTNODE_REGION="${LIGHTNODE_REGION:-}"
LIGHTNODE_ZONE="${LIGHTNODE_ZONE:-}"
LIGHTNODE_PASSWORD="${LIGHTNODE_PASSWORD:-}"
LIGHTNODE_IMAGE_NAME="${LIGHTNODE_IMAGE_NAME:-debian}"
LIGHTNODE_INSTANCE_NAME_PREFIX="${LIGHTNODE_INSTANCE_NAME_PREFIX:-virttest}"
LIGHTNODE_API_RETRIES="${LIGHTNODE_API_RETRIES:-3}"
LIGHTNODE_API_RETRY_DELAY_SECONDS="${LIGHTNODE_API_RETRY_DELAY_SECONDS:-2}"
LIGHTNODE_CLEANUP_STALE_SECONDS="${LIGHTNODE_CLEANUP_STALE_SECONDS:-43200}"
VIRTTEST_ENV_NAME="${VIRTTEST_ENV_NAME:-}"
VIRTTEST_RESOURCE_SUFFIX="${VIRTTEST_RESOURCE_SUFFIX:-}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing env: ${name}" >&2
    exit "$EXIT_USAGE"
  fi
}

record_api_call() {
  local method="$1"
  local endpoint="$2"
  local code="$3"
  local attempt="$4"
  if [[ -n "${VIRTTEST_LIGHTNODE_API_COUNTER_FILE:-}" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$method" "$endpoint" "$code" "$attempt" >>"$VIRTTEST_LIGHTNODE_API_COUNTER_FILE" 2>/dev/null || true
  fi
}

is_retryable_code() {
  local code="$1"
  [[ "$code" == "000" || "$code" == "408" || "$code" == "409" || "$code" == "425" || "$code" == "429" || "$code" =~ ^5 ]]
}

api_request() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local output code attempt delay
  local args=( -sS -w "\n%{http_code}" --max-time 120
    -H "x-open-token: ${LIGHTNODE_TOKEN}"
    -H "Content-Type: application/json"
    -X "${method}" )
  [[ -n "$body" ]] && args+=( -d "$body" )

  if ! [[ "$LIGHTNODE_API_RETRIES" =~ ^[0-9]+$ ]] || [[ "$LIGHTNODE_API_RETRIES" -lt 1 ]]; then
    LIGHTNODE_API_RETRIES=3
  fi
  delay="$LIGHTNODE_API_RETRY_DELAY_SECONDS"
  if ! [[ "$delay" =~ ^[0-9]+$ ]] || [[ "$delay" -lt 1 ]]; then
    delay=2
  fi

  for ((attempt = 1; attempt <= LIGHTNODE_API_RETRIES; attempt++)); do
    if ! output="$(curl "${args[@]}" "${LIGHTNODE_API_BASE}${endpoint}")"; then
      output=$'{"message":"curl failed"}\n000'
      code="000"
    else
      code="$(parse_code "$output")"
    fi
    record_api_call "$method" "$endpoint" "$code" "$attempt"
    if ! is_retryable_code "$code" || [[ "$attempt" -eq "$LIGHTNODE_API_RETRIES" ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep "$delay"
    if [[ "$delay" -lt 30 ]]; then
      delay=$((delay * 2))
      [[ "$delay" -le 30 ]] || delay=30
    fi
  done
}

parse_body() { sed '$d' <<<"$1"; }
parse_code() { tail -1 <<<"$1"; }
is_success_code() { [[ "$1" == "200" || "$1" == "202" ]]; }

handle_inventory_error() {
  local action="$1"
  local code="$2"
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    echo "${action}: authentication failed, http ${code}" >&2
    exit "$EXIT_PROVIDER_FAILURE"
  fi
  echo "${action}: http ${code}" >&2
  exit "$EXIT_PROVIDER_UNAVAILABLE"
}

get_regions() {
  api_request GET "/region/list"
}

get_packages() {
  local qs=""
  [[ -n "$LIGHTNODE_REGION" ]] && qs="regionCode=${LIGHTNODE_REGION}"
  [[ -n "$LIGHTNODE_ZONE" ]] && qs="${qs:+${qs}&}zoneCode=${LIGHTNODE_ZONE}"
  [[ -n "$qs" ]] && qs="?${qs}"
  api_request GET "/package/list${qs}"
}

get_images() {
  local qs="pageSize=100"
  qs="${qs}&imageType=System"
  [[ -n "$LIGHTNODE_REGION" ]] && qs="${qs}&regionCode=${LIGHTNODE_REGION}"
  api_request GET "/image/list?${qs}"
}

get_instance_detail() {
  api_request GET "/instance/detail?ecsResourceUUID=$1"
}

get_async_task() {
  api_request GET "/asynctask/getResult?asyncTaskUUID=$1"
}

get_instances() {
  local qs="pageSize=100"
  [[ -n "$LIGHTNODE_REGION" ]] && qs="${qs}&regionCode=${LIGHTNODE_REGION}"
  api_request GET "/instance/list?${qs}"
}

auto_detect_region() {
  if [[ -n "$LIGHTNODE_REGION" && -n "$LIGHTNODE_ZONE" ]]; then
    return 0
  fi

  local resp body code detected
  resp="$(get_regions)"
  body="$(parse_body "$resp")"
  code="$(parse_code "$resp")"
  is_success_code "$code" || {
    handle_inventory_error "failed to list regions" "$code"
  }

  detected="$(jq -r --arg region "$LIGHTNODE_REGION" --arg zone "$LIGHTNODE_ZONE" '
    def zone_codes($r): [($r.zones // [])[]? | .zoneCode // empty];
    if $region != "" and $zone != "" then
      [.regions[]? | select(.regionCode == $region) | select(zone_codes(.) | index($zone)) | {regionCode:$region, zoneCode:$zone}][0]
    elif $region != "" then
      [.regions[]? | select(.regionCode == $region) | {regionCode:.regionCode, zoneCode:((.zones // [])[0].zoneCode // "")}][0]
    elif $zone != "" then
      [.regions[]? | select(zone_codes(.) | index($zone)) | {regionCode:.regionCode, zoneCode:$zone}][0]
    else
      [.regions[]? | {regionCode:.regionCode, zoneCode:((.zones // [])[0].zoneCode // "")}][0]
    end
    | select(.regionCode != null and .regionCode != "" and .zoneCode != null and .zoneCode != "")
    | [.regionCode, .zoneCode] | @tsv
  ' <<<"$body")"

  if [[ -n "$detected" ]]; then
    LIGHTNODE_REGION="${detected%%$'\t'*}"
    LIGHTNODE_ZONE="${detected#*$'\t'}"
  fi

  [[ -n "$LIGHTNODE_REGION" && -n "$LIGHTNODE_ZONE" ]] || {
    echo "no matching lightnode region/zone" >&2
    exit "$EXIT_PROVIDER_UNAVAILABLE"
  }
}

get_package_code() {
  local resp body code
  resp="$(get_packages)"
  body="$(parse_body "$resp")"
  code="$(parse_code "$resp")"
  is_success_code "$code" || {
    handle_inventory_error "failed to list packages" "$code"
  }
  jq -r --arg region "$LIGHTNODE_REGION" --arg zone "$LIGHTNODE_ZONE" '
    [.packages[]? | select((.regionCode // "") == $region) | select(($zone == "") or ((.zoneCode // "") == $zone) or ((.zoneCode // "") == ""))][0].packageCode //
    [.packages[]? | select((.regionCode // "") == $region)][0].packageCode //
    (if ([.packages[]? | select((.regionCode // "") != "")] | length) > 0 then empty else (.packages[0].packageCode // empty) end)
  ' <<<"$body"
}

get_image_uuid() {
  local image_name="$1"
  local resp body code
  resp="$(get_images)"
  body="$(parse_body "$resp")"
  code="$(parse_code "$resp")"
  is_success_code "$code" || {
    handle_inventory_error "failed to list images" "$code"
  }
  jq -r --arg name "$image_name" '
    ($name | ascii_downcase) as $needle |
    [.images[]? | select(
      ((.osDistroVersion // "") | ascii_downcase | contains($needle)) or
      ((.imageName // "") | ascii_downcase | contains($needle))
    )][0].imageResourceUUID // empty
  ' <<<"$body"
}

wait_async_task() {
  local task_uuid="$1"
  local max_seconds="${2:-600}"
  local interval="${3:-15}"
  local max_interval="${4:-30}"
  local elapsed=0

  while [[ "$elapsed" -lt "$max_seconds" ]]; do
    local resp body code result status
    resp="$(get_async_task "$task_uuid")"
    body="$(parse_body "$resp")"
    code="$(parse_code "$resp")"
    if ! is_success_code "$code"; then
      echo "failed to query async task ${task_uuid}: http ${code}" >&2
      return 1
    fi
    result="$(jq -r '.asyncTaskInfo.processResult // empty' <<<"$body")"
    status="$(jq -r '.asyncTaskInfo.taskStatus // empty' <<<"$body")"
    if [[ "$result" == "SUCCESS" ]]; then
      return 0
    fi
    if [[ "$result" == "FAIL" || "$result" == "CANCEL" ]]; then
      jq -r '.asyncTaskInfo.errorMessage // .asyncTaskInfo.failMessage // .asyncTaskInfo.remark // .asyncTaskInfo.message // "lightnode async task failed"' <<<"$body" >&2
      return 1
    fi
    [[ -n "$status" ]] || true
    sleep "$interval"
    elapsed=$((elapsed + interval))
    if [[ "$interval" -lt "$max_interval" ]]; then
      interval=$((interval * 2))
      if [[ "$interval" -gt "$max_interval" ]]; then
        interval="$max_interval"
      fi
    fi
  done

  echo "timeout waiting async task ${task_uuid}" >&2
  return 1
}

wait_instance_detail() {
  local ecs_uuid="$1"
  local max_seconds="${2:-300}"
  local interval="${3:-5}"
  local max_interval="${4:-30}"
  local elapsed=0

  while [[ "$elapsed" -lt "$max_seconds" ]]; do
    local detail detail_body code ipv4
    detail="$(get_instance_detail "$ecs_uuid")"
    detail_body="$(parse_body "$detail")"
    code="$(parse_code "$detail")"
    if ! is_success_code "$code"; then
      echo "failed to query instance detail ${ecs_uuid}: http ${code}" >&2
      return 1
    fi
    ipv4="$(jq -r '.instance.publicIpAddress // empty' <<<"$detail_body")"
    if [[ -n "$ipv4" ]]; then
      printf '%s\n' "$detail_body"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    if [[ "$interval" -lt "$max_interval" ]]; then
      interval=$((interval * 2))
      if [[ "$interval" -gt "$max_interval" ]]; then
        interval="$max_interval"
      fi
    fi
  done

  echo "timeout waiting instance detail for ${ecs_uuid}" >&2
  return 1
}

cleanup_created_instance() {
  local server_id="$1"
  [[ -n "$server_id" ]] || return 0
  destroy_instance --server-id "$server_id" >/dev/null 2>&1 || true
}

safe_name_fragment() {
  local value="$1"
  printf '%s' "$value" \
    | tr '[:upper:]_' '[:lower:]-' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

build_instance_name() {
  local stamp env_part suffix_part
  stamp="$(date +%Y%m%d%H%M%S)"
  env_part="$(safe_name_fragment "${VIRTTEST_ENV_NAME:-env}")"
  suffix_part="$(safe_name_fragment "${VIRTTEST_RESOURCE_SUFFIX:-${GITHUB_RUN_ID:-$RANDOM}}")"
  [[ -n "$env_part" ]] || env_part="env"
  [[ -n "$suffix_part" ]] || suffix_part="$RANDOM"
  printf '%s-%s-%s-%s\n' "$LIGHTNODE_INSTANCE_NAME_PREFIX" "$stamp" "$env_part" "$suffix_part"
}

create_instance() {
  require_env LIGHTNODE_TOKEN
  require_env LIGHTNODE_PASSWORD
  auto_detect_region

  local package_code image_uuid instance_name payload resp body code task_uuid ecs_uuid detail_body ipv4 ssh_user
  package_code="$(get_package_code)"
  [[ -n "$package_code" ]] || {
    echo "no lightnode package available" >&2
    exit "$EXIT_PROVIDER_UNAVAILABLE"
  }

  image_uuid="$(get_image_uuid "$LIGHTNODE_IMAGE_NAME")"
  if [[ -z "$image_uuid" && "$LIGHTNODE_IMAGE_NAME" != "ubuntu" ]]; then
    image_uuid="$(get_image_uuid ubuntu)"
  fi
  [[ -n "$image_uuid" ]] || {
    echo "no suitable lightnode image found" >&2
    exit "$EXIT_PROVIDER_UNAVAILABLE"
  }

  instance_name="$(build_instance_name)"
  if [[ -n "${LIGHTNODE_SSH_KEY_UUID:-}" ]]; then
    payload="$(jq -cn --arg package "$package_code" --arg region "$LIGHTNODE_REGION" --arg zone "$LIGHTNODE_ZONE" --arg name "$instance_name" --arg image "$image_uuid" --arg password "$LIGHTNODE_PASSWORD" --arg key "$LIGHTNODE_SSH_KEY_UUID" '{packageConfig:{packageCode:$package,regionCode:$region,zoneCode:$zone,instanceName:$name,imageResourceUUID:$image,sshKeyUUID:$key,password:$password}}')"
  else
    payload="$(jq -cn --arg package "$package_code" --arg region "$LIGHTNODE_REGION" --arg zone "$LIGHTNODE_ZONE" --arg name "$instance_name" --arg image "$image_uuid" --arg password "$LIGHTNODE_PASSWORD" '{packageConfig:{packageCode:$package,regionCode:$region,zoneCode:$zone,instanceName:$name,imageResourceUUID:$image,password:$password}}')"
  fi

  resp="$(api_request POST "/instance/create" "$payload")"
  body="$(parse_body "$resp")"
  code="$(parse_code "$resp")"
  is_success_code "$code" || {
    echo "$body" >&2
    exit "$EXIT_PROVIDER_FAILURE"
  }

  task_uuid="$(jq -r '.asyncTaskInfo.asyncTaskUUID // empty' <<<"$body")"
  ecs_uuid="$(jq -r '.asyncTaskInfo.ecsResourceUUID // empty' <<<"$body")"
  [[ -n "$ecs_uuid" ]] || {
    echo "missing ecsResourceUUID" >&2
    exit "$EXIT_PROVIDER_FAILURE"
  }

  if [[ -n "$task_uuid" ]]; then
    if ! wait_async_task "$task_uuid" 900 15 30; then
      cleanup_created_instance "$ecs_uuid"
      exit "$EXIT_PROVIDER_FAILURE"
    fi
  fi

  if ! detail_body="$(wait_instance_detail "$ecs_uuid" 300 5 30)"; then
    cleanup_created_instance "$ecs_uuid"
    exit "$EXIT_PROVIDER_FAILURE"
  fi

  ipv4="$(jq -r '.instance.publicIpAddress // empty' <<<"$detail_body")"
  ssh_user="$(jq -r '.instance.sysAccount // "root"' <<<"$detail_body")"

  [[ -n "$ipv4" ]] || {
    echo "missing public ip for ${ecs_uuid}" >&2
    cleanup_created_instance "$ecs_uuid"
    exit "$EXIT_PROVIDER_FAILURE"
  }

  jq -cn \
    --arg server_id "$ecs_uuid" \
    --arg ipv4 "$ipv4" \
    --arg password "$LIGHTNODE_PASSWORD" \
    --arg ssh_user "$ssh_user" \
    --arg region "$LIGHTNODE_REGION" \
    --arg zone "$LIGHTNODE_ZONE" \
    '{server_id:$server_id, ipv4:$ipv4, password:$password, ssh_user:$ssh_user, region:$region, zone:$zone, platform:"lightnode"}'
}

destroy_instance() {
  require_env LIGHTNODE_TOKEN

  local server_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-id)
        server_id="$2"
        shift 2
        ;;
      *)
        echo "unknown arg: $1" >&2
        return "$EXIT_USAGE"
        ;;
    esac
  done

  [[ -n "$server_id" ]] || return "$EXIT_OK"

  local payload resp body code task_uuid
  payload="$(jq -cn --arg id "$server_id" '{ecsResourceUUID:$id}')"
  resp="$(api_request POST "/instance/release" "$payload")"
  body="$(parse_body "$resp")"
  code="$(parse_code "$resp")"
  is_success_code "$code" || {
    echo "$body" >&2
    return "$EXIT_PROVIDER_FAILURE"
  }
  task_uuid="$(jq -r '.asyncTaskInfo.asyncTaskUUID // empty' <<<"$body")"
  [[ -z "$task_uuid" ]] || wait_async_task "$task_uuid" 600 10
}

validate_inventory() {
  require_env LIGHTNODE_TOKEN
  require_env LIGHTNODE_PASSWORD
  auto_detect_region

  local package_code image_uuid
  package_code="$(get_package_code)"
  [[ -n "$package_code" ]] || {
    echo "no lightnode package available" >&2
    exit "$EXIT_PROVIDER_UNAVAILABLE"
  }
  image_uuid="$(get_image_uuid "$LIGHTNODE_IMAGE_NAME")"
  if [[ -z "$image_uuid" && "$LIGHTNODE_IMAGE_NAME" != "ubuntu" ]]; then
    image_uuid="$(get_image_uuid ubuntu)"
  fi
  [[ -n "$image_uuid" ]] || {
    echo "no suitable lightnode image found" >&2
    exit "$EXIT_PROVIDER_UNAVAILABLE"
  }

  jq -cn \
    --arg region "$LIGHTNODE_REGION" \
    --arg zone "$LIGHTNODE_ZONE" \
    --arg package "$package_code" \
    --arg image "$image_uuid" \
    --arg image_name "$LIGHTNODE_IMAGE_NAME" \
    '{platform:"lightnode", region:$region, zone:$zone, package_code:$package, image_uuid:$image, image_name:$image_name, status:"ok"}'
}

run_name_epoch() {
  local value="$1"
  local stamp
  if [[ "$value" =~ ([0-9]{14}) ]]; then
    stamp="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  local y="${stamp:0:4}"
  local mo="${stamp:4:2}"
  local d="${stamp:6:2}"
  local h="${stamp:8:2}"
  local mi="${stamp:10:2}"
  local s="${stamp:12:2}"

  if date -u -d "${y}-${mo}-${d} ${h}:${mi}:${s} UTC" +%s >/dev/null 2>&1; then
    date -u -d "${y}-${mo}-${d} ${h}:${mi}:${s} UTC" +%s
    return 0
  fi

  date -u -j -f "%Y%m%d%H%M%S" "$stamp" +%s 2>/dev/null
}

cleanup_stale_instances() {
  require_env LIGHTNODE_TOKEN
  auto_detect_region

  if ! [[ "$LIGHTNODE_CLEANUP_STALE_SECONDS" =~ ^[0-9]+$ ]] || [[ "$LIGHTNODE_CLEANUP_STALE_SECONDS" -lt 1 ]]; then
    LIGHTNODE_CLEANUP_STALE_SECONDS=43200
  fi

  local resp body code now candidates name id created_epoch removed=0 failed=0
  resp="$(get_instances)"
  body="$(parse_body "$resp")"
  code="$(parse_code "$resp")"
  is_success_code "$code" || {
    handle_inventory_error "failed to list instances" "$code"
  }

  now="$(date -u +%s)"
  candidates="$(jq -r --arg prefix "$LIGHTNODE_INSTANCE_NAME_PREFIX" '
    [
      .instances[]?,
      .instanceList[]?,
      .data.records[]?,
      .data.list[]?
    ]
    | .[]
    | {
        id:(.ecsResourceUUID // .instanceUUID // .resourceUUID // .id // ""),
        name:(.instanceName // .name // "")
      }
    | select(.id != "" and (.name | startswith($prefix + "-")))
    | [.id, .name] | @tsv
  ' <<<"$body")"

  while IFS=$'\t' read -r id name; do
    [[ -n "$id" && -n "$name" ]] || continue
    if ! created_epoch="$(run_name_epoch "$name")"; then
      continue
    fi
    if [[ $((now - created_epoch)) -gt "$LIGHTNODE_CLEANUP_STALE_SECONDS" ]]; then
      echo "cleanup stale lightnode instance name=${name} id=${id}" >&2
      if destroy_instance --server-id "$id"; then
        removed=$((removed + 1))
      else
        failed=$((failed + 1))
      fi
    fi
  done <<<"$candidates"

  jq -cn --arg removed "$removed" --arg failed "$failed" \
    '{platform:"lightnode", stale_instances_removed:($removed|tonumber), stale_cleanup_failures:($failed|tonumber)}'
  [[ "$failed" -eq 0 ]] || exit "$EXIT_PROVIDER_FAILURE"
}

main() {
  case "${1:-}" in
    create)
      create_instance
      ;;
    validate)
      validate_inventory
      ;;
    cleanup-stale)
      cleanup_stale_instances
      ;;
    destroy)
      shift
      destroy_instance "$@"
      ;;
    *)
      echo "usage: $0 create|validate|cleanup-stale|destroy [args]" >&2
      exit "$EXIT_USAGE"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
