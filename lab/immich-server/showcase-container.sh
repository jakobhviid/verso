#!/usr/bin/env bash
# Runs INSIDE the showcase server's container; showcase.sh pushes it and calls it one phase at a time:
#   setup      tools, the admin and the partner, their API keys, the admin's PIN, both users' preferences
#   upload     every manifest entry, as its owner, with the story's EXIF written in (videos transcoded to MP4)
#   idle       exit 0 when Immich's job queues are empty (polled by showcase.sh with wait_for)
#   organize   descriptions, favourites, ratings, tags, albums (shared, with comments and likes), shared links,
#              stacks, archive, the partner sharing, the Locked Folder, named people, memories, the trash
#   summary    one line of counts
# State (tokens, keys, uploaded ids) lives in /opt/immich/seed. Throwaway credentials only; never printed.
set -euo pipefail

API=http://127.0.0.1:2283/api
FIX=/opt/fixtures            # manifest.json + cache/, pushed by showcase.sh
S=/opt/immich/seed
mkdir -p "$S"
ADMIN_EMAIL=maja@example.com ADMIN_NAME="Maja Holm"
PARTNER_EMAIL=jonas@example.com PARTNER_NAME="Jonas Holm"

# api USER METHOD PATH [JSON]: a call in USER's session (admin or partner); prints the body, fails on HTTP >= 400.
api() {
  curl -sS --fail-with-body -X "$2" "$API$3" -H "Authorization: Bearer $(cat "$S/token-$1")" \
    -H 'Content-Type: application/json' ${4:+--data "$4"}
}
secret() { head -c 600 /dev/urandom | tr -dc A-Za-z0-9 | cut -c1-"$1"; }   # no SIGPIPE under pipefail
login() {
  curl -sS --fail-with-body -X POST "$API/auth/login" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg e "$1" --arg p "$2" '{email:$e, password:$p}')" | jq -r .accessToken
}
# The asset ids of one owner whose roles match a jq test on .roles (an array), as a JSON array.
ids() { jq -c --arg o "$1" "[.[] | select(.owner == \$o) | select(.roles | $2) | .assetId]" "$S/assets.json"; }

case ${1:-} in
setup)
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq jq libimage-exiftool-perl ffmpeg >/dev/null
  admin_password=$(secret 20) partner_password=$(secret 20)
  pin=$(head -c 600 /dev/urandom | tr -dc 0-9 | cut -c1-6)
  curl -sS --fail-with-body -X POST "$API/auth/admin-sign-up" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg e "$ADMIN_EMAIL" --arg p "$admin_password" --arg n "$ADMIN_NAME" '{email:$e, password:$p, name:$n}')" >/dev/null
  login "$ADMIN_EMAIL" "$admin_password" > "$S/token-admin"
  api admin POST /admin/users "$(jq -nc --arg e "$PARTNER_EMAIL" --arg p "$partner_password" --arg n "$PARTNER_NAME" \
    '{email:$e, password:$p, name:$n, avatarColor:"blue", storageLabel:"jonas", shouldChangePassword:false}')" >/dev/null
  api admin PUT "/admin/users/$(api admin GET /users/me | jq -r .id)" '{"storageLabel":"maja"}' >/dev/null
  login "$PARTNER_EMAIL" "$partner_password" > "$S/token-partner"
  # Every face becomes a person, so a sitter with one portrait is named too (the default wants three), and faces are
  # found on old plates and under white beards (at the default 0.7, two of Darwin's three and Douglass's
  # daguerreotype had none). The storage template on, so Folders shows maja/2019/2019-04-05/ rather than ids.
  api admin GET /system-config | jq -c '.machineLearning.facialRecognition.minFaces = 1
    | .machineLearning.facialRecognition.minScore = 0.5 | .storageTemplate.enabled = true
    | .storageTemplate.template = "{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}"' > "$S/config.json"
  api admin PUT /system-config "$(cat "$S/config.json")" >/dev/null
  # Everything on in both accounts: ratings, tags, folders, memories, people, shared links.
  preferences='{"ratings":{"enabled":true},"tags":{"enabled":true,"sidebarWeb":true},
    "folders":{"enabled":true,"sidebarWeb":true},"memories":{"enabled":true},
    "people":{"enabled":true,"sidebarWeb":true,"minimumFaces":1},"sharedLinks":{"enabled":true,"sidebarWeb":true},
    "recentlyAdded":{"sidebarWeb":true}}'
  api admin PUT /users/me/preferences "$preferences" >/dev/null
  api partner PUT /users/me/preferences "$preferences" >/dev/null
  api admin POST /auth/pin-code "$(jq -nc --arg p "$pin" '{pinCode:$p}')" >/dev/null
  full=$(api admin POST /api-keys '{"name":"showcase-full","permissions":["all"]}' | jq -r .secret)
  readonly_key=$(api admin POST /api-keys '{"name":"showcase-readonly","permissions":["album.read","asset.read","asset.view","asset.download","person.read"]}' | jq -r .secret)
  partner_key=$(api partner POST /api-keys '{"name":"showcase-partner-full","permissions":["all"]}' | jq -r .secret)
  {
    printf 'IMMICH_ADMIN_NAME="%s"\nIMMICH_ADMIN_EMAIL=%s\nIMMICH_ADMIN_PASSWORD=%s\nIMMICH_ADMIN_PIN=%s\n' \
      "$ADMIN_NAME" "$ADMIN_EMAIL" "$admin_password" "$pin"
    printf 'IMMICH_API_KEY_FULL=%s\nIMMICH_API_KEY_READONLY=%s\n' "$full" "$readonly_key"
    printf 'IMMICH_PARTNER_NAME="%s"\nIMMICH_PARTNER_EMAIL=%s\nIMMICH_PARTNER_PASSWORD=%s\nIMMICH_PARTNER_API_KEY_FULL=%s\n' \
      "$PARTNER_NAME" "$PARTNER_EMAIL" "$partner_password" "$partner_key"
    printf 'IMMICH_ML=1\nIMMICH_SHOWCASE=1\n'
  } > "$S/keys.env"
  chmod 600 "$S/keys.env"
  echo "admin $ADMIN_NAME, partner $PARTNER_NAME, PIN set, keys showcase-full, showcase-readonly, showcase-partner-full"
  ;;

upload)
  # Memories: the seed day's month and day, n years before (29 February becomes the 28th in other years).
  today=$(TZ=Europe/Copenhagen date +%F)
  : > "$S/assets.jsonl"
  jq -c '.files[]' "$FIX/manifest.json" | while read -r entry; do
    id=$(jq -r .id <<<"$entry") owner=$(jq -r .owner <<<"$entry") name=$(jq -r .uploadName <<<"$entry")
    src="$FIX/cache/$(jq -r .cacheName <<<"$entry")"
    taken=$(jq -r .dateTaken <<<"$entry") offset=$(jq -r .timeZoneOffset <<<"$entry")
    zone=$(jq -r .timeZone <<<"$entry")
    years=$(jq -r '[.roles[] | select(startswith("memory=")) | ltrimstr("memory=")][0] // empty' <<<"$entry")
    if [ -n "$years" ]; then
      day="$(( ${today:0:4} - years ))-${today:5:5}"
      date -d "$day" >/dev/null 2>&1 || day="${day%-29}-28"
      taken="${day//-/:} ${taken#* }"
      offset=$(TZ="$zone" date -d "${day} ${taken#* }" +%:z)
    fi
    local_time="$(echo "${taken% *}" | tr : -)T${taken#* }"
    created=$local_time$offset
    [ "$(jq -r '.roles | index("scan")' <<<"$entry")" = null ] || created=${local_time}.000Z
    if jq -e '.roles | index("video")' <<<"$entry" >/dev/null; then
      # A phone's video: H.264 and AAC in MP4, at most 15 s, with its time (UTC) and place.
      work=/tmp/showcase.mp4
      location=$(jq -r 'if .exif.GPSLatitude then
          "\(if .exif.GPSLatitudeRef == "S" then "-" else "+" end)\(.exif.GPSLatitude)\(if .exif.GPSLongitudeRef == "W" then "-" else "+" end)\(.exif.GPSLongitude)/"
        else "" end' <<<"$entry")
      ffmpeg -nostdin -loglevel error -y -i "$src" -t 15 -vf "scale='min(1920,iw)':-2" -c:v libx264 -preset veryfast \
        -crf 23 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart \
        -metadata creation_time="$(date -u -d "$created" +%FT%T.000000Z)" ${location:+-metadata location="$location"} "$work"
    else
      work=/tmp/showcase.jpg
      cp "$src" "$work"
      mapfile -t tags < <(jq -r '.exif | to_entries[] | "-\(.key)=\(.value)"' <<<"$entry")
      exiftool -q -overwrite_original "${tags[@]}" "-DateTimeOriginal=$taken" \
        $([ -n "$years" ] && echo "-OffsetTimeOriginal=$offset") "$work"
    fi
    result=$(curl -sS --fail-with-body -X POST "$API/assets" -H "Authorization: Bearer $(cat "$S/token-$owner")" \
      -F "assetData=@$work;filename=\"$name\"" -F "fileCreatedAt=$created" -F "fileModifiedAt=$created")
    jq -c --arg asset "$(jq -r .id <<<"$result")" --arg status "$(jq -r .status <<<"$result")" \
      '{id, assetId:$asset, status:$status, owner, uploadName, roles, description}' <<<"$entry" >> "$S/assets.jsonl"
    rm -f "$work"
  done
  jq -s . "$S/assets.jsonl" > "$S/assets.json"
  jq -r '.[] | [.id, .assetId, .status, .owner, .uploadName, (.roles | join(","))] | @tsv' "$S/assets.json" > "$S/assets.tsv"
  jq -r 'group_by(.owner)[] | "\(.[0].owner): \(length) (\(map(.status) | group_by(.) | map("\(length) \(.[0])") | join(", ")))"' \
    "$S/assets.json" | tr '\n' ' '; echo
  ;;

idle)
  api admin GET /queues | jq -e 'all(.[]; .statistics.active + .statistics.waiting + .statistics.delayed == 0)' >/dev/null
  ;;

organize)
  admin_id=$(api admin GET /users/me | jq -r .id) partner_id=$(api partner GET /users/me | jq -r .id)
  # Descriptions, favourites, ratings.
  jq -c '.[] | select(.description != "")' "$S/assets.json" | while read -r asset; do
    api "$(jq -r .owner <<<"$asset")" PUT "/assets/$(jq -r .assetId <<<"$asset")" "$(jq -c '{description}' <<<"$asset")" >/dev/null
  done
  for owner in admin partner; do
    api $owner PUT /assets "$(jq -nc --argjson a "$(ids $owner 'index("favorite")')" '{ids:$a, isFavorite:true}')" >/dev/null
  done
  jq -c '.[] | {owner, assetId, rating: ([.roles[] | select(startswith("rating=")) | ltrimstr("rating=") | tonumber][0])}
         | select(.rating)' "$S/assets.json" | while read -r asset; do
    api "$(jq -r .owner <<<"$asset")" PUT "/assets/$(jq -r .assetId <<<"$asset")" "$(jq -c '{rating}' <<<"$asset")" >/dev/null
  done
  # Tags, nested with "/": each tag=<a/b>, and Travel/<country> for a trip's photos.
  for owner in admin partner; do
    jq -c --arg o "$owner" --slurpfile manifest "$FIX/manifest.json" '
        [.[] | select(.owner == $o) | .assetId as $a | .roles[] as $r
         | if ($r | startswith("tag=")) then {tag: ($r | ltrimstr("tag=")), asset: $a}
           elif ($r | startswith("trip=")) then {tag: "Travel/\($manifest[0].trips[$r | ltrimstr("trip=")])", asset: $a}
           else empty end]
        | group_by(.tag)[] | {tag: .[0].tag, assets: map(.asset) | unique}' "$S/assets.json" > "$S/tags-$owner.jsonl"
    [ -s "$S/tags-$owner.jsonl" ] || continue
    api $owner PUT /tags "$(jq -sc '{tags: map(.tag)}' "$S/tags-$owner.jsonl")" > "$S/tag-ids-$owner.json"
    while read -r tag; do
      tag_id=$(jq -r --arg v "$(jq -r .tag <<<"$tag")" '.[] | select(.value == $v) | .id' "$S/tag-ids-$owner.json")
      api $owner PUT /tags/assets "$(jq -c --arg t "$tag_id" '{tagIds:[$t], assetIds:.assets}' <<<"$tag")" >/dev/null
    done < "$S/tags-$owner.jsonl"
  done
  # Albums: each trip=<name> and album=<name>, its cover the first favourite. Two are shared with the partner, and
  # the partner's cats with the admin.
  : > "$S/albums.tsv"
  for owner in admin partner; do
    jq -r --arg o "$owner" '[.[] | select(.owner == $o) | .roles[] | select(startswith("trip=") or startswith("album="))
                             | sub("^(trip|album)="; "")] | unique[]' "$S/assets.json" | while read -r album; do
      assets=$(ids $owner "any(.[]; . == \"trip=$album\" or . == \"album=$album\")")
      cover=$(jq -r --arg o "$owner" --arg al "$album" '[.[] | select(.owner == $o)
               | select(.roles | (index("trip=" + $al) or index("album=" + $al)))] | (map(select(.roles | index("favorite"))) + .)[0].assetId' "$S/assets.json")
      case "$owner/$album" in
        "admin/Japan 2019") users=$(jq -nc --arg u "$partner_id" '[{userId:$u, role:"editor"}]') ;;
        "admin/Iceland Road Trip") users=$(jq -nc --arg u "$partner_id" '[{userId:$u, role:"viewer"}]') ;;
        "partner/Our Cats") users=$(jq -nc --arg u "$admin_id" '[{userId:$u, role:"viewer"}]') ;;
        *) users='[]' ;;
      esac
      album_id=$(api $owner POST /albums "$(jq -nc --arg n "$album" --argjson a "$assets" --argjson u "$users" \
        '{albumName:$n, assetIds:$a, albumUsers:$u}')" | jq -r .id)
      api $owner PATCH "/albums/$album_id" "$(jq -nc --arg c "$cover" '{albumThumbnailAssetId:$c}')" >/dev/null
      printf '%s\t%s\t%s\n' "$owner" "$album" "$album_id" >> "$S/albums.tsv"
    done
  done
  album() { awk -F'\t' -v a="$1" '$2 == a {print $3}' "$S/albums.tsv"; }
  asset() { jq -r --arg id "$1" '.[] | select(.id == $id) | .assetId' "$S/assets.json"; }
  by_name() { jq -r --arg n "$1" '.[] | select(.uploadName == $n) | .assetId' "$S/assets.json"; }
  first_with() { jq -r --arg r "$1" '[.[] | select(.roles | index($r))][0].assetId' "$S/assets.json"; }
  # Comments and likes, from both sides.
  comment() { api "$1" POST /activities "$(jq -nc --arg al "$2" --arg as "$3" --arg c "$4" \
    '{albumId:$al, type:"comment", comment:$c} + (if $as == "" then {} else {assetId:$as} end)')" >/dev/null; }
  like() { api "$1" POST /activities "$(jq -nc --arg al "$2" --arg as "$3" \
    '{albumId:$al, type:"like"} + (if $as == "" then {} else {assetId:$as} end)')" >/dev/null; }
  japan=$(album "Japan 2019") iceland=$(album "Iceland Road Trip") cats=$(album "Our Cats")
  torii=$(jq -r '.[] | select(.description == "Ten thousand torii") | .assetId' "$S/assets.json")
  kinkaku=$(jq -r '.[] | select(.description == "Kinkaku-ji") | .assetId' "$S/assets.json")
  aurora=$(jq -r '.[] | select(.description == "Northern lights by Mývatn") | .assetId' "$S/assets.json")
  cat_photo=$(jq -r '[.[] | select(.owner == "partner" and (.roles | index("favorite")))][0].assetId' "$S/assets.json")
  comment partner "$japan" "$torii" "How far up did you walk?"
  comment admin "$japan" "$torii" "All the way to the top. Worth it for the view over Kyoto."
  like partner "$japan" "$kinkaku"
  like admin "$japan" ""
  comment partner "$japan" "" "Next time we go together!"
  comment partner "$iceland" "$aurora" "Unreal colours."
  like partner "$iceland" "$aurora"
  comment admin "$iceland" "" "The best road trip so far."
  comment admin "$cats" "$cat_photo" "Look at that face"
  like admin "$cats" "$cat_photo"
  like admin "$cats" ""
  # Shared links: the Iceland album, and one photo.
  reine=$(jq -r '.[] | select(.description == "Reine before sunrise") | .assetId' "$S/assets.json")
  album_link=$(api admin POST /shared-links "$(jq -nc --arg a "$iceland" \
    '{type:"ALBUM", albumId:$a, description:"Iceland, September 2018", allowDownload:true, showMetadata:true}')" | jq -r .key)
  photo_link=$(api admin POST /shared-links "$(jq -nc --arg a "$reine" \
    '{type:"INDIVIDUAL", assetIds:[$a], description:"Reine, Lofoten", allowDownload:true, showMetadata:false}')" | jq -r .key)
  printf 'IMMICH_SHARED_LINK_ALBUM_KEY=%s\nIMMICH_SHARED_LINK_PHOTO_KEY=%s\n' "$album_link" "$photo_link" >> "$S/keys.env"
  # Stacks: the cover first.
  jq -r '[.[] | .roles[] | select(startswith("stack=")) | ltrimstr("stack=") | sub(":primary$"; "")] | unique[]' \
    "$S/assets.json" | while read -r group; do
    members=$(jq -c --arg g "stack=$group" --arg p "stack=$group:primary" \
      '[.[] | select(.roles | index($p))] + [.[] | select(.roles | index($g))] | map(.assetId)' "$S/assets.json")
    api admin POST /stacks "$(jq -nc --argjson a "$members" '{assetIds:$a}')" >/dev/null
  done
  # Archive.
  api admin PUT /assets "$(jq -nc --argjson a "$(ids admin 'index("archive")')" '{ids:$a, visibility:"archive"}')" >/dev/null
  # The partner shares their library with the admin, who shows it on the timeline.
  api partner POST /partners "$(jq -nc --arg u "$admin_id" '{sharedWithId:$u}')" >/dev/null
  api admin PUT "/partners/$partner_id" '{"inTimeline":true}' >/dev/null
  # The Locked Folder: unlocked with the PIN for the move, then locked again.
  pin=$(sed -n 's/^IMMICH_ADMIN_PIN=//p' "$S/keys.env")
  api admin POST /auth/session/unlock "$(jq -nc --arg p "$pin" '{pinCode:$p}')" >/dev/null
  api admin PUT /assets "$(jq -nc --argjson a "$(ids admin 'index("locked")')" '{ids:$a, visibility:"locked"}')" >/dev/null
  api admin POST /auth/session/lock >/dev/null
  # People: each sitter's faces become one named person (recognition on upload may split one sitter in two; they
  # are merged); faces nobody named are hidden.
  named=0
  for name in $(jq -r '[.[] | .roles[] | select(startswith("person=")) | ltrimstr("person=") | @base64] | unique[]' "$S/assets.json"); do
    name=$(base64 -d <<<"$name")
    : > "$S/person.ids"
    for asset_id in $(jq -r --arg r "person=$name" '.[] | select(.roles | index($r)) | .assetId' "$S/assets.json"); do
      api admin GET "/faces?id=$asset_id" | jq -r '.[] | .person.id // empty' >> "$S/person.ids"
    done
    [ -s "$S/person.ids" ] || { echo "no face found for $name"; continue; }
    primary=$(sort "$S/person.ids" | uniq -c | sort -rn | awk 'NR==1 {print $2}')
    others=$(sort -u "$S/person.ids" | grep -vx "$primary" | jq -R . | jq -sc . || true)
    [ "$others" = "[]" ] || [ -z "$others" ] || api admin POST "/people/$primary/merge" "$(jq -nc --argjson i "$others" '{ids:$i}')" >/dev/null
    api admin PUT "/people/$primary" "$(jq -nc --arg n "$name" '{name:$n}')" >/dev/null
    named=$((named + 1))
  done
  api admin PUT "/people/$(api admin GET '/people?size=500' | jq -r '.people[] | select(.name == "Hans Christian Andersen") | .id')" \
    '{"isFavorite":true}' >/dev/null || true
  api admin GET '/people?withHidden=true&size=500' | jq -r '.people[] | select(.name == "") | .id' | while read -r person; do
    api admin PUT "/people/$person" '{"isHidden":true}' >/dev/null
  done
  # Memories ("on this day"), from what is now on the timeline.
  api admin POST /jobs '{"name":"memory-create"}' >/dev/null
  # The trash, last.
  for owner in admin partner; do
    trash=$(ids $owner 'index("trash")')
    [ "$trash" = "[]" ] || api $owner DELETE /assets "$(jq -nc --argjson a "$trash" '{ids:$a, force:false}')" >/dev/null
  done
  echo "organized: $(wc -l < "$S/albums.tsv") albums, $named people named, partner sharing, locked, stacks, links"
  ;;

summary)
  for owner in admin partner; do
    stats=$(api $owner GET /assets/statistics)
    printf '%s: %s assets (%s images, %s videos), archived %s, trashed %s, favourites %s, albums %s, tags %s; ' "$owner" \
      "$(jq .total <<<"$stats")" "$(jq .images <<<"$stats")" "$(jq .videos <<<"$stats")" \
      "$(api $owner GET '/assets/statistics?visibility=archive' | jq .total)" \
      "$(api $owner GET '/assets/statistics?isTrashed=true' | jq .total)" \
      "$(api $owner GET '/assets/statistics?isFavorite=true' | jq .total)" \
      "$(api $owner GET /albums | jq length)" "$(api $owner GET /tags | jq length)"
  done
  printf 'people named %s (hidden %s), stacks %s, memories %s, shared links %s, countries %s\n' \
    "$(api admin GET '/people?size=500' | jq '[.people[] | select(.name != "")] | length')" \
    "$(api admin GET '/people?withHidden=true&size=500' | jq '[.people[] | select(.isHidden)] | length')" \
    "$(api admin GET /stacks | jq length)" "$(api admin GET /memories | jq length)" \
    "$(api admin GET /shared-links | jq length)" "$(api admin GET '/search/suggestions?type=country' | jq -c .)"
  ;;

*) echo "usage: $0 setup|upload|idle|organize|summary" >&2; exit 2 ;;
esac
