#!/usr/bin/env bash
# Seed the showcase server: a library that looks like a person's own, for the website's and the App Store's pictures
# and for what Immich's demo and the contract tests' seed cannot show (saving edits, ratings, comments and likes, a
# partner, the Locked Folder, memories, named people, uploads and backups). Beside the contract tests' server, never
# instead of it: the contract tests assert seed.sh's numbers.
#
#   IMMICH_INSTANCE=ind-immich-show lab/immich-server/up.sh --ml     # first: the server, with machine learning
#   lab/immich-server/showcase.sh                                   # then this
#   lab/immich-server/tunnel.sh open [--mac]                        # reach it from here (and the Mac)
#
# Two users (the admin and a partner who shares with her), their API keys, the admin's PIN, and fixtures/showcase's
# CC0 and public domain photos and videos with dates, places, albums, tags and the rest (fixtures/showcase/
# build-manifest.py has the story). Writes .env.<instance>.local; warm like the other servers: a snapshot of the
# seeded server, which up.sh restores, so the memories' "on this day" is the seed day's.
#
# Env overrides: IMMICH_INSTANCE (default ind-immich-show), EREBUS_DIR, SHOWCASE_PORT (the tunnels' port on this host
#   and on the Mac, default 2290), WIKIMEDIA_UA (User-Agent for Commons downloads).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EREBUS_DIR=${EREBUS_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/erebus}
NAME=${IMMICH_INSTANCE:-ind-immich-show}
PORT=${SHOWCASE_PORT:-2290}
UA=${WIKIMEDIA_UA:-"Verso-lab-showcase/0.1 (showcase fixtures for a private development lab; low volume)"}
P=lab
# shellcheck source=/dev/null
. "$EREBUS_DIR/lib/erebus.sh"

[ "$(state "$P" "$NAME")" = RUNNING ] || die "$NAME is not running; run IMMICH_INSTANCE=$NAME $HERE/up.sh --ml first"
. "$HERE/../warm.sh"
ENV_FILE=$HERE/.env.$NAME.local ASSETS_FILE=$HERE/.assets.$NAME.tsv
if has_fresh "$NAME" && [ -f "$ENV_FILE" ]; then
  step "$NAME is seeded already: up.sh restored its snapshot"
  exit 0
fi
in_ct() { inc exec --project "$P" "$NAME" -- "$@" </dev/null; }
in_ct test -f /opt/immich/ml-enabled || die "$NAME runs without machine learning; build it with up.sh --ml"
IP=$(inc list --project "$P" "^$NAME\$" -f json </dev/null |
     jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet") | .address' | head -1)

step "fixtures: download missing files into fixtures/showcase/cache and verify sha1"
FIXTURES_DIR=$HERE/fixtures/showcase WIKIMEDIA_UA=$UA "$HERE/fixtures.sh"

step "copy fixtures and showcase-container.sh into $NAME; socat for the tunnels"
in_ct mkdir -p /opt/fixtures
tar -C "$HERE/fixtures/showcase" -cf - manifest.json cache | inc exec --project "$P" "$NAME" -- tar -xf - -C /opt/fixtures
inc file push --project "$P" "$HERE/showcase-container.sh" "$NAME/opt/immich/showcase-container.sh" </dev/null
in_ct sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat >/dev/null'

step "setup: the admin and the partner, keys, PIN, preferences"
in_ct bash /opt/immich/showcase-container.sh setup
step "upload, as each owner"
in_ct bash /opt/immich/showcase-container.sh upload
wait_for "$P" "$NAME" "job queues idle (thumbnails, metadata, faces, smart search, OCR)" \
  bash /opt/immich/showcase-container.sh idle
step "organize"
in_ct bash /opt/immich/showcase-container.sh organize
wait_for "$P" "$NAME" "job queues idle (memories)" bash /opt/immich/showcase-container.sh idle

step "write $(basename "$ENV_FILE")"
{
  echo "# Throwaway credentials for the disposable showcase server $NAME. Written by showcase.sh; never leaves this host."
  echo "# IMMICH_URL: from Erebus' other instances. IMMICH_LOCAL_URL and IMMICH_MAC_URL: through tunnel.sh's tunnels."
  echo "IMMICH_URL=http://$IP:2283"
  echo "IMMICH_LOCAL_URL=http://127.0.0.1:$PORT"
  echo "IMMICH_MAC_URL=http://127.0.0.1:$PORT"
  in_ct cat /opt/immich/seed/keys.env
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
in_ct cat /opt/immich/seed/assets.tsv > "$ASSETS_FILE"   # manifest id, asset id, status, owner, upload name, roles
step "$(in_ct bash /opt/immich/showcase-container.sh summary)"
if ! inc list --project "$P" "^$NAME\$" -f json </dev/null | jq -e '.[0].profiles | index("lan")' >/dev/null; then
  step "taking its seeded snapshot"
  snapshot_fresh "$NAME"
  wait_for "$P" "$NAME" "Immich /api/server/ping" \
    sh -c 'curl -fsS --max-time 3 http://127.0.0.1:2283/api/server/ping | grep -q pong'
fi
