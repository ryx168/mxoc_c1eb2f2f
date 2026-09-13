#!/bin/bash
# Run the OpenCart admin behind the Cloudflare tunnel until it goes idle.
# Idle is measured by admin566 requests (a person editing), not scanner noise.
set -uo pipefail
cd "${GITHUB_WORKSPACE:-$PWD}/webroot"

# PHP built-in server (E_DEPRECATED/E_NOTICE silenced - 1.5.4 on PHP 5.6 is noisy)
php -d error_reporting="E_ALL & ~E_DEPRECATED & ~E_NOTICE & ~E_STRICT" \
    -d display_errors=0 -S 127.0.0.1:8080 router.php >/tmp/php.log 2>&1 &
sleep 3
echo "php -S started; local admin probe:"
curl -s -o /dev/null -w "  /admin566/ -> %{http_code}\n" "http://127.0.0.1:8080/${ADMIN_DIR:-admin566}/index.php?route=common/login" || true

# cloudflared with the named-tunnel token
if [ -n "${TUNNEL_TOKEN:-}" ]; then
  curl -fsSL -o /tmp/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  chmod +x /tmp/cloudflared
  /tmp/cloudflared tunnel --no-autoupdate --loglevel info run --token "$TUNNEL_TOKEN" >/tmp/cfd.log 2>&1 &
  echo "cloudflared started; editor at https://${EDIT_HOST}/${ADMIN_DIR:-admin566}/"
else
  echo "no TUNNEL_TOKEN - local only"
fi

IDLE_MIN="${IDLE_MINUTES:-15}"
idle_limit=$(( IDLE_MIN * 60 ))
AD="${ADMIN_DIR:-admin566}"; adm() { grep -c "$AD" /tmp/php.log 2>/dev/null || echo 0; }
last_count=$(adm); last_active=$(date +%s)
echo "watching for idle (${IDLE_MIN} min of no admin activity)"
MAX=$(( 340 * 60 )); start=$(date +%s)
while true; do
  sleep 20
  now=$(date +%s)
  c=$(adm)
  if [ "$c" != "$last_count" ]; then last_count=$c; last_active=$now; fi
  idle=$(( now - last_active ))
  [ $idle -ge $idle_limit ] && { echo "idle ${idle}s >= ${idle_limit}s - stopping"; break; }
  [ $(( now - start )) -ge $MAX ] && { echo "max session time - stopping"; break; }
done
echo "session ended (admin requests seen: $(adm))"
