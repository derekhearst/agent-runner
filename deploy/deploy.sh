#!/bin/bash
# Installs or updates the agent-runner custom app on TrueNAS.
# Needs deploy/.env (see worker/.env.example, plus WORKER_MEM_LIMIT) and the SSH key from the
# homelab notes. After the first run, a new image is picked up with: deploy.sh restart
set -euo pipefail
cd "$(dirname "$0")"
HOST=truenas_admin@192.168.0.2
SSH=(ssh -i ~/.ssh/truenas_ed25519 -o BatchMode=yes "$HOST")
APP=agent-runner

if [[ "${1:-}" == "restart" ]]; then
  "${SSH[@]}" "midclt call -j app.stop $APP && midclt call -j app.start $APP"
  exit 0
fi

# Plain KEY=VALUE lines, not sourced as shell: values may hold spaces, and a Windows editor may add CRs.
while IFS='=' read -r key value; do
  value="${value%$'\r'}"; value="${value#\"}"; value="${value%\"}"
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] && export "$key=$value"
done < <(grep -v '^[[:space:]]*#' .env)
: "${ANTHROPIC_ENVIRONMENT_KEY:?}" "${ANTHROPIC_ENVIRONMENT_ID:?}" "${GH_TOKEN:?}" "${GIT_EMAIL:?}"
export GIT_NAME="${GIT_NAME:-Claude Agent}" WORKER_MEM_LIMIT="${WORKER_MEM_LIMIT:-8g}"

# Render the compose file and wrap it as the JSON payload midclt wants, locally, so secrets never
# touch a file on the NAS other than the app's own config.
PAYLOAD="$(python - <<'PY'
import json, os, string
text = string.Template(open("truenas.compose.yaml").read()).substitute(os.environ)
print(json.dumps({"custom_compose_config_string": text}))
PY
)"

"${SSH[@]}" "mkdir -p /mnt/Apps/Apps/AgentRunner/workspace /mnt/Apps/Apps/AgentRunner/rfs-tools"

if "${SSH[@]}" "midclt call app.query '[[\"name\",\"=\",\"$APP\"]]' | grep -q '\"name\"'"; then
  echo "$PAYLOAD" | "${SSH[@]}" "midclt call -j app.update $APP \"\$(cat)\""
else
  CREATE="$(python -c 'import json,sys; p=json.loads(sys.stdin.read()); p.update({"custom_app":True,"app_name":"'"$APP"'"}); print(json.dumps(p))' <<<"$PAYLOAD")"
  echo "$CREATE" | "${SSH[@]}" "midclt call -j app.create \"\$(cat)\""
fi
echo "Deployed $APP. Logs: TrueNAS UI > Apps > $APP > Logs"
