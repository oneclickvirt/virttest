#!/usr/bin/env bash
set -euo pipefail

REPORTS_DIR="${1:-}"
OUT_HTML="${2:-}"

if [[ -z "$REPORTS_DIR" || -z "$OUT_HTML" ]]; then
  echo "usage: $0 <reports_dir> <output_html>" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "missing local command: jq" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUT_HTML")"

classify_group() {
  local env_name="$1"
  case "$env_name" in
    local-*|amd64|arm64|x86_64|aarch64)
      printf 'local\n'
      ;;
    *)
      printf 'integration\n'
      ;;
  esac
}

result_status() {
  local result_file="$1"
  if [[ ! -s "$result_file" ]]; then
    printf 'UNKNOWN\n'
    return 0
  fi
  jq -rs '
    if length == 0 then "UNKNOWN"
    elif any(.[]; .status == "FAIL") then "FAIL"
    elif any(.[]; .status == "WARN") then "WARN"
    elif any(.[]; .status == "SKIP") then "SKIP"
    else "PASS"
    end
  ' "$result_file"
}

result_counts() {
  local result_file="$1"
  if [[ ! -s "$result_file" ]]; then
    jq -cn '{total:0, pass:0, fail:0, warn:0, skip:0}'
    return 0
  fi
  jq -cs '{
    total: length,
    pass: map(select(.status == "PASS")) | length,
    fail: map(select(.status == "FAIL")) | length,
    warn: map(select(.status == "WARN")) | length,
    skip: map(select(.status == "SKIP")) | length
  }' "$result_file"
}

file_type() {
  local name="$1"
  case "$name" in
    *.md) printf 'report\n' ;;
    *.jsonl) printf 'results\n' ;;
    *-resources.json|*-preflight.json|*-cleanup-stale.json) printf 'resource\n' ;;
    *.prom) printf 'prometheus\n' ;;
    *.log) printf 'log\n' ;;
    *.html) printf 'html\n' ;;
    *) printf 'file\n' ;;
  esac
}

file_list_json() {
  local run_dir="$1"
  local files_json="[]"
  local f rel name type item

  while IFS= read -r f; do
    rel="${f#"${REPORTS_DIR}/"}"
    name="$(basename "$f")"
    type="$(file_type "$name")"
    item="$(jq -cn --arg name "$name" --arg path "$rel" --arg type "$type" \
      '{name:$name, path:$path, type:$type}')"
    files_json="$(jq -cn --argjson arr "$files_json" --argjson item "$item" '$arr + [$item]')"
  done < <(find "$run_dir" -maxdepth 1 -type f | sort)

  printf '%s\n' "$files_json"
}

find_results_file() {
  local env_name="$1"
  local run_dir="$2"
  local preferred="${run_dir}/${env_name}-results.jsonl"
  if [[ -f "$preferred" ]]; then
    printf '%s\n' "$preferred"
    return 0
  fi
  find "$run_dir" -maxdepth 1 -type f -name '*-results.jsonl' | sort | head -n 1
}

build_report_jsonl() {
  local env_dir env_name group runs_json run_dir ts result_file counts status files run_json latest_status latest_counts env_json

  if [[ ! -d "$REPORTS_DIR" ]]; then
    return 0
  fi

  while IFS= read -r env_dir; do
    env_name="$(basename "$env_dir")"
    group="$(classify_group "$env_name")"
    runs_json="[]"

    while IFS= read -r run_dir; do
      ts="$(basename "$run_dir")"
      result_file="$(find_results_file "$env_name" "$run_dir")"
      counts="$(result_counts "$result_file")"
      status="$(result_status "$result_file")"
      files="$(file_list_json "$run_dir")"
      run_json="$(jq -cn \
        --arg timestamp "$ts" \
        --arg status "$status" \
        --argjson counts "$counts" \
        --argjson files "$files" \
        '{timestamp:$timestamp, status:$status, counts:$counts, files:$files}')"
      runs_json="$(jq -cn --argjson arr "$runs_json" --argjson item "$run_json" '$arr + [$item]')"
    done < <(find "$env_dir" -mindepth 1 -maxdepth 1 -type d | sort -r)

    latest_status="$(jq -r 'if length > 0 then .[0].status else "UNKNOWN" end' <<<"$runs_json")"
    latest_counts="$(jq -c 'if length > 0 then .[0].counts else {total:0, pass:0, fail:0, warn:0, skip:0} end' <<<"$runs_json")"
    env_json="$(jq -cn \
      --arg environment "$env_name" \
      --arg group "$group" \
      --arg latest_status "$latest_status" \
      --argjson latest_counts "$latest_counts" \
      --argjson runs "$runs_json" \
      '{environment:$environment, group:$group, latest_status:$latest_status, latest_counts:$latest_counts, runs:$runs}')"
    printf '%s\n' "$env_json"
  done < <(find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
}

REPORT_JSONL_FILE="$(mktemp "${TMPDIR:-/tmp}/virttest-report-jsonl.XXXXXX")"
cleanup() {
  rm -f "$REPORT_JSONL_FILE"
}
trap cleanup EXIT
build_report_jsonl >"$REPORT_JSONL_FILE"
GENERATED_AT="$(date -u '+%Y-%m-%d %H:%M:%S')"

{
  cat <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Virttest Reports</title>
  <style>
    :root {
      --bg: #f6f7fb;
      --panel: #ffffff;
      --text: #18202f;
      --muted: #667085;
      --line: #d8dee8;
      --ok: #0f8a5f;
      --bad: #c4314b;
      --warn: #a15c00;
      --link: #275dcc;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
    }
    .wrap { max-width: 1180px; margin: 0 auto; padding: 28px 16px 40px; }
    header { display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; margin-bottom: 18px; }
    h1 { margin: 0; font-size: 28px; line-height: 1.15; letter-spacing: 0; }
    .muted { color: var(--muted); }
    .summary { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 10px; margin: 14px 0; }
    .metric, .env {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: 0 1px 2px rgba(24, 32, 47, 0.05);
    }
    .metric { padding: 12px; }
    .metric b { display: block; font-size: 22px; }
    .metric span { color: var(--muted); font-size: 13px; }
    .controls {
      display: grid;
      grid-template-columns: minmax(220px, 1fr) 170px 170px 170px;
      gap: 10px;
      margin: 16px 0;
    }
    input, select {
      width: 100%;
      min-height: 40px;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 8px 10px;
      background: #fff;
      color: var(--text);
      font: inherit;
    }
    .env { margin: 12px 0; overflow: hidden; }
    .env-head {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      padding: 14px;
      border-bottom: 1px solid var(--line);
    }
    .env-title { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
    .env-title h2 { margin: 0; font-size: 18px; letter-spacing: 0; }
    .badge {
      display: inline-flex;
      align-items: center;
      min-height: 24px;
      padding: 2px 8px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      border: 1px solid currentColor;
    }
    .PASS { color: var(--ok); }
    .FAIL { color: var(--bad); }
    .WARN { color: var(--warn); }
    .SKIP { color: var(--warn); }
    .UNKNOWN { color: var(--muted); }
    .counts { display: flex; flex-wrap: wrap; gap: 10px; color: var(--muted); font-size: 13px; }
    .runs { width: 100%; border-collapse: collapse; }
    .runs th, .runs td { padding: 10px 14px; border-bottom: 1px solid var(--line); text-align: left; vertical-align: top; }
    .runs th { color: var(--muted); font-size: 12px; text-transform: uppercase; }
    .files { display: flex; flex-wrap: wrap; gap: 6px; }
    a.file {
      color: var(--link);
      border: 1px solid #c8d6f3;
      border-radius: 6px;
      padding: 3px 7px;
      text-decoration: none;
      background: #f8fbff;
      font-size: 13px;
    }
    a.file:hover { border-color: var(--link); }
    .empty { padding: 18px; background: var(--panel); border: 1px solid var(--line); border-radius: 8px; }
    @media (max-width: 760px) {
      header { display: block; }
      .summary { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .controls { grid-template-columns: 1fr; }
      .env-head { display: block; }
      .runs th:nth-child(3), .runs td:nth-child(3) { display: none; }
    }
  </style>
</head>
<body>
<div class="wrap">
  <header>
    <div>
      <h1>Virttest Reports</h1>
      <div class="muted">Generated at UTC:
EOF
  printf ' %s' "$GENERATED_AT"
  cat <<'EOF'
      </div>
    </div>
    <div class="muted">Latest visible runs are summarized below.</div>
  </header>

  <section class="summary" id="summary"></section>

  <section class="controls" aria-label="Report filters">
    <input id="query" type="search" placeholder="Filter environment, run, or file" />
    <select id="status">
      <option value="all">All statuses</option>
      <option value="failing">Failing latest</option>
      <option value="warning">Warning latest</option>
      <option value="passing">Passing latest</option>
      <option value="skipped">Skipped latest</option>
    </select>
    <select id="group">
      <option value="all">All groups</option>
      <option value="integration">Remote integration</option>
      <option value="local">Local architecture</option>
    </select>
    <select id="fileType">
      <option value="all">All file types</option>
      <option value="report">Reports</option>
      <option value="results">JSONL results</option>
      <option value="log">Logs</option>
      <option value="prometheus">Prometheus</option>
      <option value="resource">Resource JSON</option>
    </select>
  </section>

  <main id="reports"></main>
</div>

<script id="report-data" type="application/json">
EOF
  printf '[\n'
  first=1
  while IFS= read -r env_json; do
    [[ -n "$env_json" ]] || continue
    if [[ "$first" -eq 0 ]]; then
      printf ',\n'
    fi
    first=0
    printf '%s' "$env_json" | sed 's#</#<\\/#g'
  done <"$REPORT_JSONL_FILE"
  printf '\n]\n'
  cat <<'EOF'
</script>
<script>
const DATA = JSON.parse(document.getElementById("report-data").textContent);
const query = document.getElementById("query");
const status = document.getElementById("status");
const group = document.getElementById("group");
const fileType = document.getElementById("fileType");
const reports = document.getElementById("reports");
const summary = document.getElementById("summary");

function esc(value) {
  return String(value).replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  }[ch]));
}

function fileHref(path) {
  return "./reports/" + String(path).split("/").map(encodeURIComponent).join("/");
}

function statusMatches(env, selected) {
  if (selected === "all") return true;
  if (selected === "failing") return env.latest_status === "FAIL";
  if (selected === "warning") return env.latest_status === "WARN";
  if (selected === "passing") return env.latest_status === "PASS";
  if (selected === "skipped") return env.latest_status === "SKIP";
  return true;
}

function fileTypeMatches(env, selected) {
  if (selected === "all") return true;
  return env.runs.some((run) => run.files.some((file) => file.type === selected));
}

function queryMatches(env, needle) {
  if (!needle) return true;
  const haystack = [
    env.environment,
    env.group,
    env.latest_status,
    ...env.runs.flatMap((run) => [
      run.timestamp,
      run.status,
      ...run.files.flatMap((file) => [file.name, file.path, file.type])
    ])
  ].join(" ").toLowerCase();
  return haystack.includes(needle);
}

function renderSummary(items) {
  const aggregate = items.reduce((acc, env) => {
    acc.envs += 1;
    acc.total += env.latest_counts.total || 0;
    acc.fail += env.latest_counts.fail || 0;
    acc.warn += env.latest_counts.warn || 0;
    acc.skip += env.latest_counts.skip || 0;
    return acc;
  }, { envs: 0, total: 0, fail: 0, warn: 0, skip: 0 });
  summary.innerHTML = [
    ["Environments", aggregate.envs],
    ["Latest Checks", aggregate.total],
    ["Latest Failures", aggregate.fail],
    ["Latest Warnings", aggregate.warn],
    ["Latest Skips", aggregate.skip]
  ].map(([label, value]) => `<div class="metric"><b>${value}</b><span>${label}</span></div>`).join("");
}

function renderFiles(files, selectedType) {
  if (selectedType !== "all") {
    files = files.filter((file) => file.type === selectedType);
  }
  if (!files.length) return '<span class="muted">No files</span>';
  return `<div class="files">${files.map((file) => (
    `<a class="file" href="${fileHref(file.path)}">${esc(file.type)}: ${esc(file.name)}</a>`
  )).join("")}</div>`;
}

function render() {
  const needle = query.value.trim().toLowerCase();
  const selectedStatus = status.value;
  const selectedGroup = group.value;
  const selectedType = fileType.value;
  const filtered = DATA.filter((env) => (
    (selectedGroup === "all" || env.group === selectedGroup) &&
    statusMatches(env, selectedStatus) &&
    fileTypeMatches(env, selectedType) &&
    queryMatches(env, needle)
  ));

  renderSummary(filtered);
  if (!filtered.length) {
    reports.innerHTML = '<div class="empty muted">No reports match the current filters.</div>';
    return;
  }

  reports.innerHTML = filtered.map((env) => {
    const latest = env.runs[0];
    const latestText = latest ? esc(latest.timestamp) : "none";
    const rows = env.runs.map((run) => `
      <tr>
        <td>${esc(run.timestamp)}</td>
        <td><span class="badge ${esc(run.status)}">${esc(run.status)}</span></td>
        <td>${run.counts.total} total / ${run.counts.pass} pass / ${run.counts.fail} fail / ${(run.counts.warn || 0)} warn / ${run.counts.skip} skip</td>
        <td>${renderFiles(run.files, selectedType)}</td>
      </tr>
    `).join("");
    return `
      <section class="env">
        <div class="env-head">
          <div class="env-title">
            <h2>${esc(env.environment)}</h2>
            <span class="badge ${esc(env.latest_status)}">${esc(env.latest_status)}</span>
            <span class="badge UNKNOWN">${esc(env.group)}</span>
          </div>
          <div class="counts">
            <span>Latest: ${latestText}</span>
            <span>${env.latest_counts.total} total</span>
            <span>${env.latest_counts.pass} pass</span>
            <span>${env.latest_counts.fail} fail</span>
            <span>${env.latest_counts.warn || 0} warn</span>
            <span>${env.latest_counts.skip} skip</span>
          </div>
        </div>
        <table class="runs">
          <thead><tr><th>Run</th><th>Status</th><th>Counts</th><th>Files</th></tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </section>
    `;
  }).join("");
}

[query, status, group, fileType].forEach((el) => el.addEventListener("input", render));
render();
</script>
</body>
</html>
EOF
} >"$OUT_HTML"
