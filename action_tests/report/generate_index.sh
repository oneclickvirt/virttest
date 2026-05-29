#!/usr/bin/env bash
set -euo pipefail

REPORTS_DIR="${1:-}"
OUT_HTML="${2:-}"

if [[ -z "$REPORTS_DIR" || -z "$OUT_HTML" ]]; then
  echo "usage: $0 <reports_dir> <output_html>" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUT_HTML")"

{
  cat <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Virttest Reports</title>
  <style>
    :root { --bg:#0b1320; --fg:#eaf2ff; --muted:#98a7c7; --card:#111c2e; --ok:#1ecb7b; --bad:#ff6b6b; --link:#7db4ff; }
    body { margin:0; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; background: radial-gradient(circle at top right,#1c2b44,#0b1320 50%); color:var(--fg); }
    .wrap { max-width: 980px; margin: 32px auto; padding: 0 16px; }
    h1 { margin: 0 0 16px; }
    .card { background: var(--card); border: 1px solid #2a3a57; border-radius: 12px; padding: 12px 14px; margin: 10px 0; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .muted { color: var(--muted); }
  </style>
</head>
<body>
<div class="wrap">
  <h1>Virttest Reports</h1>
  <p class="muted">Generated at UTC: 
EOF
  date -u '+%Y-%m-%d %H:%M:%S'
  cat <<'EOF'
  </p>
EOF

  if [[ ! -d "$REPORTS_DIR" ]]; then
    echo "<p>No reports yet.</p>"
  else
    while IFS= read -r env_dir; do
      env_name="$(basename "$env_dir")"
      latest="$(ls -1 "$env_dir" 2>/dev/null | sort -r | head -n 1 || true)"
      if [[ -z "$latest" ]]; then
        continue
      fi
      echo "<div class=\"card\">"
      echo "<div><strong>${env_name}</strong></div>"
      echo "<div class=\"muted\">latest run: ${latest}</div>"
      echo "<ul>"
      while IFS= read -r f; do
        rel="${f#${REPORTS_DIR}/}"
        name="$(basename "$f")"
        echo "<li><a href=\"./reports/${rel}\">${name}</a></li>"
      done < <(find "${env_dir}/${latest}" -maxdepth 1 -type f | sort)
      echo "</ul>"
      echo "</div>"
    done < <(find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
  fi

  cat <<'EOF'
</div>
</body>
</html>
EOF
} >"$OUT_HTML"
