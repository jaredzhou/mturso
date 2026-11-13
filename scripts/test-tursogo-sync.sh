#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
server="${MTURSO_NATIVE_SERVER:-$root/_build/native/debug/build/cmd/server/server.exe}"
if [[ ! -x "$server" ]]; then
  echo "native server executable not found: $server" >&2
  echo "run 'moon build cmd/server --target native' first" >&2
  exit 1
fi

tmp="$(mktemp -d)"
address="127.0.0.1:$((18080 + $$ % 1000))"
log="$tmp/native-server.log"
"$server" "$tmp/remote.db" "$address" >"$log" 2>&1 &
pid=$!

cleanup() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
trap cleanup EXIT

ready=false
for _ in $(seq 1 100); do
  if curl -fsS "http://$address/" >/dev/null 2>&1 ||
    curl -sS -X POST -H "content-type: application/json" \
      --data '{}' "http://$address/v2/pipeline" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 0.05
done

if ! kill -0 "$pid" 2>/dev/null; then
  echo "native server exited before the test:" >&2
  cat "$log" >&2
  exit 1
fi
if [[ "$ready" != true ]]; then
  echo "native server did not become ready at $address" >&2
  cat "$log" >&2
  exit 1
fi

(
  cd "$root/tursogo"
  if ! MTURSO_SYNC_URL="http://$address" go test -count=1 ./...; then
    echo "native server log:" >&2
    cat "$log" >&2
    exit 1
  fi
)
