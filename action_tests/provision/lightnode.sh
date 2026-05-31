#!/usr/bin/env bash
set -euo pipefail

LIGHTNODE_API_BASE="${LIGHTNODE_API_BASE:-https://openapi.lightnode.com}"
LIGHTNODE_TOKEN="${LIGHTNODE_TOKEN:-}"
LIGHTNODE_REGION="${LIGHTNODE_REGION:-}"
LIGHTNODE_ZONE="${LIGHTNODE_ZONE:-}"
LIGHTNODE_PASSWORD="${LIGHTNODE_PASSWORD:-CiTest1234!}"
LIGHTNODE_IMAGE_NAME="${LIGHTNODE_IMAGE_NAME:-debian}"
LIGHTNODE_INSTANCE_NAME_PREFIX="${LIGHTNODE_INSTANCE_NAME_PREFIX:-virttest}"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing env: ${name}" >&2
    exit 2
  fi
}

api_request() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local args=( -sS -w "\n%{http_code}" --max-time 120
    -H "x-open-token: ${LIGHTNODE_TOKEN}"
    -H "Content-Type: application/json"
    -X "${method}" )
  [[ -n "$body" ]] && args+=( -d "$body" )
  curl "${args[@]}" "${LIGHTNODE_API_BASE}${endpoint}"
}

parse_body() { sed '$d' <<<"$1"; }
parse_code() { tail -1 <<<"$1"; }

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
  [[ -n "$LIGHTNODE_REGION" ]] && qs="${qs}&regionCode=${LIGHTNODE_REGION}&imageType=System"
  api_request GET "/image/list?${qs}"
}

get_instance_detail() {
  api_request GET "/instance/detail?ecsResourceUUID=$1"
}

get_async_task() {
  api_request GET "/asynctask/getResult?asyncTaskUUID=$1"
}

auto_detect_region() {
  if [[ -n "$LIGHTNODE_REGION" && -n "$LIGHTNODE_ZONE" ]]; then
    return 0
  fi

  local resp body code
  resp="$(get_regions)"
  body="$(parse_body "$resp")"
  code="$(parse_code "$resp")"
  [[ "$code" == "200" || "$code" == "202" ]] || {
    echo "failed to list regions: http ${code}" >&2
    exit 3
  }

  LIGHTNODE_REGION="$(jq -r '.regions[0].regionCode // empty' <<<"$body")"
  LIGHTNODE_ZONE="$(jq -r '.regions[0].zones[0].zoneCode // empty' <<<"$body")"
  [[ -n "$LIGHTNODE_REGION" && -n "$LIGHTNODE_ZONE" ]] || {
    echo "no available lightnode region/zone" >&2
    exit 3
  }
}

get_package_code() {
  local resp body code
  resp="$(get_packages)"
  body="$(parse_body "$resp")"
  code="$(parse_code "$resp")"
  [[ "$code" == "200" || "$code" == "202" ]] || {
    echo "failed to list packages: http ${code}" >&2
    exit 3
  }
  jq -r --arg region "$LIGHTNODE_REGION" '[.packages[]? | select(.regionCode == $region)][0].packageCode // .packages[0].packageCode // empty' <<<"$body"
}

get_image_uuid() {
  local image_name="$1"
  local resp body code
  resp="$(get_images)"
  body="$(parse_body "$resp")"
  code="$(parse_code "$resp")"
  [[ "$code" == "200" || "$code" == "202" ]] || {
    echo "failed to list images: http ${code}" >&2
    exit 3
  }
  jq -r --arg name "$image_name" '[.images[]? | select((.osDistroVersion // "" | test($name; "i")) or (.imageName // "" | test($name; "i")))][0].imageResourceUUID // empty' <<<"$body"
}

wait_async_task() {
  local task_uuid="$1"
  local max_seconds="${2:-600}"
  local interval="${3:-15}"
  local max_interval="${4:-30}"
  local elapsed=0

  while [[ "$elapsed" -lt "$max_seconds" ]]; do
    local resp body result status
    resp="$(get_async_task "$task_uuid")"
    body="$(parse_body "$resp")"
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
    local detail detail_body ipv4 ssh_user
    detail="$(get_instance_detail "$ecs_uuid")"
    detail_body="$(parse_body "$detail")"
    ipv4="$(jq -r '.instance.publicIpAddress // empty' <<<"$detail_body")"
    ssh_user="$(jq -r '.instance.sysAccount // "root"' <<<"$detail_body")"
    if [[ -n "$ipv4" ]]; then
      jq -cn \
        --arg server_id "$ecs_uuid" \
        --arg ipv4 "$ipv4" \
        --arg password "$LIGHTNODE_PASSWORD" \
        --arg ssh_user "$ssh_user" \
        --arg region "$LIGHTNODE_REGION" \
        --arg zone "$LIGHTNODE_ZONE" \
        '{server_id:$server_id, ipv4:$ipv4, password:$password, ssh_user:$ssh_user, region:$region, zone:$zone, platform:"lightnode"}'
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

create_instance() {
  require_env LIGHTNODE_TOKEN
  auto_detect_region

  local package_code image_uuid instance_name payload resp body code task_uuid ecs_uuid detail detail_body ipv4 ssh_user
  package_code="$(get_package_code)"
  [[ -n "$package_code" ]] || {
    echo "no lightnode package available" >&2
    exit 3
  }

  image_uuid="$(get_image_uuid "$LIGHTNODE_IMAGE_NAME")"
  if [[ -z "$image_uuid" && "$LIGHTNODE_IMAGE_NAME" != "ubuntu" ]]; then
    image_uuid="$(get_image_uuid ubuntu)"
  fi
  [[ -n "$image_uuid" ]] || {
    echo "no suitable lightnode image found" >&2
    exit 3
  }

  instance_name="${LIGHTNODE_INSTANCE_NAME_PREFIX}-$(date +%Y%m%d%H%M%S)"
  if [[ -n "${LIGHTNODE_SSH_KEY_UUID:-}" ]]; then
    payload="$(jq -cn --arg package "$package_code" --arg region "$LIGHTNODE_REGION" --arg zone "$LIGHTNODE_ZONE" --arg name "$instance_name" --arg image "$image_uuid" --arg password "$LIGHTNODE_PASSWORD" --arg key "$LIGHTNODE_SSH_KEY_UUID" '{packageConfig:{packageCode:$package,regionCode:$region,zoneCode:$zone,instanceName:$name,imageResourceUUID:$image,sshKeyUUID:$key,password:$password}}')"
  else
    payload="$(jq -cn --arg package "$package_code" --arg region "$LIGHTNODE_REGION" --arg zone "$LIGHTNODE_ZONE" --arg name "$instance_name" --arg image "$image_uuid" --arg password "$LIGHTNODE_PASSWORD" '{packageConfig:{packageCode:$package,regionCode:$region,zoneCode:$zone,instanceName:$name,imageResourceUUID:$image,password:$password}}')"
  fi

  resp="$(api_request POST "/instance/create" "$payload")"
  body="$(parse_body "$resp")"
  code="$(parse_code "$resp")"
  [[ "$code" == "200" || "$code" == "202" ]] || {
    echo "$body" >&2
    exit 4
  }

  task_uuid="$(jq -r '.asyncTaskInfo.asyncTaskUUID // empty' <<<"$body")"
  ecs_uuid="$(jq -r '.asyncTaskInfo.ecsResourceUUID // empty' <<<"$body")"
  [[ -n "$ecs_uuid" ]] || {
    echo "missing ecsResourceUUID" >&2
    exit 4
  }

  if [[ -n "$task_uuid" ]]; then
    if ! wait_async_task "$task_uuid" 900 15 30; then
      cleanup_created_instance "$ecs_uuid"
      exit 4
    fi
  fi

  if ! detail_body="$(wait_instance_detail "$ecs_uuid" 300 5 30)"; then
    cleanup_created_instance "$ecs_uuid"
    exit 4
  fi

  ipv4="$(jq -r '.instance.publicIpAddress // empty' <<<"$detail_body")"
  ssh_user="$(jq -r '.instance.sysAccount // "root"' <<<"$detail_body")"

  [[ -n "$ipv4" ]] || {
    echo "missing public ip for ${ecs_uuid}" >&2
    cleanup_created_instance "$ecs_uuid"
    exit 4
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
        exit 2
        ;;
    esac
  done

  [[ -n "$server_id" ]] || exit 0

  local payload resp body code task_uuid
  payload="$(jq -cn --arg id "$server_id" '{ecsResourceUUID:$id}')"
  resp="$(api_request POST "/instance/release" "$payload")"
  body="$(parse_body "$resp")"
  code="$(parse_code "$resp")"
  [[ "$code" == "200" || "$code" == "202" ]] || exit 0
  task_uuid="$(jq -r '.asyncTaskInfo.asyncTaskUUID // empty' <<<"$body")"
  [[ -z "$task_uuid" ]] || wait_async_task "$task_uuid" 600 10 || true
}

case "${1:-}" in
  create)
    create_instance
    ;;
  destroy)
    shift
    destroy_instance "$@"
    ;;
  *)
    echo "usage: $0 create|destroy [args]" >&2
    exit 2
    ;;
esac