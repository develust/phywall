#!/bin/bash
# =====================================================================
#  lib/configure.sh - prepares Rspamd for phywall
#  Part of: phywall by Develust Technology
#
#  Usage: phywall configure --sector hotel,finance           -> dry run (shows changes)
#         phywall configure --sector hotel,finance --apply   -> installs
#         phywall configure --rollback                       -> removes everything it added
#         phywall configure --sectors                        -> lists available sectors
#
#  What it adds (nothing else is changed):
#    /etc/rspamd/maps/phishing/urls.map
#    /etc/rspamd/maps/phishing/text/common.map + chosen sectors
#    a marked block at the END of local.d/multimap.conf
#    a marked block at the END of local.d/composites.conf
#    a marked block at the END of local.d/phishing.conf (only for feeds that are off:
#      OpenPhish / PhishTank)
#  It also saves the installed sectors in <phywall>/.sectors
# =====================================================================
LIB=$(dirname "$(readlink -f "$0")")     # .../phywall/lib
ROOT=$(dirname "$LIB")                   # .../phywall
source "$LIB/common.sh"
banner

# ---------- paths ----------
MAPSRC=$ROOT/maps
RSPAMD=${RSPAMD_DIR:-/etc/rspamd}
LD=$RSPAMD/local.d
MM=$LD/multimap.conf
CP=$LD/composites.conf
PH=$LD/phishing.conf
DEST=$RSPAMD/maps/phishing
BKROOT=$ROOT/backups
STATE=$ROOT/.sectors          # installed sectors on this server (used by update.sh)
BEGIN='# BEGIN phywall (managed by phywall configure - do not edit)'
END='# END phywall'
OLD_BEGIN='# BEGIN phishing-detector (managed by configuration.sh - do not edit)'   # legacy name
OLD_END='# END phishing-detector'
OUR_RULES='PHISH_URL|PHISH_TEXT|PHISH_SUBJECT'
OUR_COMPS='PHISH_LINK_AND_TEXT|PHISH_DEFAULT_PLUS_CUSTOM'

# ---------- output helpers ----------
ok()   { echo "  [✓] $*"; }
add()  { echo "  [+] $*"; }
rem()  { echo "  [-] $*"; }
same() { echo "  [=] $*"; }
warn() { echo "  [!] $*"; }
die()  { echo "  [✗] $*"; exit 1; }

usage() { grep -A3 '^#  Usage:' "$0" | sed 's/^#  //'; exit 1; }

sectors_available() {
  ls "$MAPSRC"/text/*.map 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.map$//' | grep -vx common | tr '\n' ' '
}

# print file without our block
strip_block() {
  [ -f "$1" ] || return 0
  awk -v b="$BEGIN" -v e="$END" -v ob="$OLD_BEGIN" -v oe="$OLD_END" '$0==b||$0==ob{s=1;next} $0==e||$0==oe{s=0;next} !s' "$1"
}

# remove our block in place (keeps owner/permissions), trims trailing empty lines
remove_block() {
  [ -f "$1" ] || return 0
  local tmp; tmp=$(strip_block "$1")
  printf '%s\n' "$tmp" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$1.pd.tmp" && cat "$1.pd.tmp" > "$1" && rm -f "$1.pd.tmp"
  [ -s "$1" ] && ! grep -q '[^[:space:]]' "$1" && : > "$1"
  return 0
}

has_block() { [ -f "$1" ] && grep -qxF -e "$BEGIN" -e "$OLD_BEGIN" "$1"; }

# symbols registered in running Rspamd
symbols() { rspamc counters 2>/dev/null | awk -F'|' 'NF>3{gsub(/ /,"",$3); if($3!="" && $3!="Symbol") print $3}' | sort -u; }

# phishing feeds: effective value from the running config, and explicit user settings
feed_state() {   # prints true / false / unknown
  local v
  v=$(rspamadm configdump phishing 2>/dev/null | awk -v k="$1" '$1==k {gsub(/[";]/,"",$3); print $3; exit}')
  case "$v" in true|false) echo "$v" ;; *) echo unknown ;; esac
}
feed_user_set() {   # is the key set by the admin (outside our block) in local.d / override.d?
  { strip_block "$PH"; [ -f "$RSPAMD/override.d/phishing.conf" ] && cat "$RSPAMD/override.d/phishing.conf"; } \
    | grep -qE "^[[:space:]]*$1[[:space:]]*="
}

wait_rspamd() {
  local t=0
  until rspamc stat >/dev/null 2>&1; do sleep 1; t=$((t+1)); [ $t -ge 20 ] && return 1; done
}

# ---------- arguments ----------
MODE=dry; SECTORS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sector)   SECTORS="$2"; shift 2 ;;
    --sector=*) SECTORS="${1#*=}"; shift ;;
    --apply)    MODE=apply; shift ;;
    --rollback) MODE=rollback; shift ;;
    --sectors|--list) MODE=list; shift ;;
    -h|--help)  usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [ "$MODE" = list ]; then
  echo "Available sectors (common is always installed):"
  for s in $(sectors_available); do echo "  - $s"; done
  exit 0
fi

# ---------- preflight ----------
echo "Preflight checks"
[ "$(id -u)" -eq 0 ] || die "Run as root"
for c in rspamc rspamadm systemctl; do command -v $c >/dev/null || die "Command not found: $c"; done
systemctl is-active --quiet rspamd || die "Rspamd is not running"
ok "Rspamd is running"
[ -d "$LD" ] || die "Folder missing: $LD"

# =====================================================================
#  ROLLBACK
# =====================================================================
if [ "$MODE" = rollback ]; then
  echo
  echo "Rollback"
  if ! has_block "$MM" && ! has_block "$CP" && ! has_block "$PH" && [ ! -d "$DEST" ]; then
    same "Nothing installed - nothing to remove"; exit 0
  fi
  TS=$(date +%F_%H%M%S); BK=$BKROOT/$TS; mkdir -p "$BK"
  for f in "$MM" "$CP" "$PH"; do [ -f "$f" ] && cp -p "$f" "$BK/"; done
  [ -d "$DEST" ] && cp -rp "$DEST" "$BK/maps"
  ok "Safety backup: $BK"

  has_block "$MM" && remove_block "$MM" && rem "Removed block from $MM"
  has_block "$CP" && remove_block "$CP" && rem "Removed block from $CP"
  has_block "$PH" && remove_block "$PH" && rem "Removed block from $PH (feeds back to your own settings)"
  [ -f "$PH" ] && [ ! -s "$PH" ] && rm -f "$PH"
  [ -d "$DEST" ] && rm -rf "$DEST" && rem "Removed $DEST"
  [ -f "$STATE" ] && rm -f "$STATE" && rem "Removed $STATE"

  if ! rspamadm configtest >/dev/null 2>&1; then
    warn "configtest failed after rollback - restoring safety backup"
    for f in multimap.conf composites.conf phishing.conf; do [ -f "$BK/$f" ] && cp -p "$BK/$f" "$LD/$f"; done
    [ -d "$BK/maps" ] && cp -rp "$BK/maps" "$DEST"
    die "Rollback aborted, nothing changed. Check: rspamadm configtest"
  fi
  systemctl reload rspamd && wait_rspamd && ok "Rspamd reloaded"
  echo
  echo "Done. Your own rules are untouched."
  exit 0
fi

# =====================================================================
#  DRY RUN / APPLY
# =====================================================================
[ -f "$MAPSRC/urls.map" ]        || die "Missing: $MAPSRC/urls.map"
[ -f "$MAPSRC/text/common.map" ] || die "Missing: $MAPSRC/text/common.map"

# sector list: lowercase, unique, without common
LIST=$(echo "$SECTORS" | tr 'A-Z' 'a-z' | tr ', ' '\n\n' | grep -v '^$' | grep -vx common | awk '!x[$0]++' | tr '\n' ' ')
for s in $LIST; do
  [ -f "$MAPSRC/text/$s.map" ] || die "Unknown sector: $s   (available: $(sectors_available))"
done
ALL="common $LIST"
ok "Sectors: $(echo $ALL | tr ' ' ',')"

# conflict check: our rule names outside our block = duplicates
CONF=""
strip_block "$MM" | grep -qE "^[[:space:]]*($OUR_RULES)[[:space:]]*\{" && \
  CONF+=$(strip_block "$MM" | grep -nE "^[[:space:]]*($OUR_RULES)[[:space:]]*\{" | sed "s#^#    $MM: #")$'\n'
strip_block "$CP" | grep -qE "^[[:space:]]*($OUR_COMPS)[[:space:]]*\{" && \
  CONF+=$(strip_block "$CP" | grep -nE "^[[:space:]]*($OUR_COMPS)[[:space:]]*\{" | sed "s#^#    $CP: #")$'\n'
if [ -n "$CONF" ]; then
  warn "These rules already exist OUTSIDE the managed block (would be duplicates):"
  printf '%s' "$CONF"
  die "Delete those old rule blocks from the files above, then run again."
fi
ok "No duplicate rules"

# map list for multimap
MAPLIST=""
for s in $ALL; do MAPLIST+="    \"file://$DEST/text/$s.map\","$'\n'; done
MAPLIST=$(printf '%s' "$MAPLIST" | sed '$ s/,$//')

MM_BLOCK="$BEGIN
PHISH_URL {
  type = \"url\";
  regexp = true;
  map = \"file://$DEST/urls.map\";
  score = 0.0;
  description = \"Signal only: hosting/redirect link used in phishing\";
}
PHISH_TEXT {
  type = \"content\";
  filter = \"text\";
  regexp = true;
  map = [
$MAPLIST
  ];
  score = 0.0;
  description = \"Signal only: phishing phrase in mail body\";
}
PHISH_SUBJECT {
  type = \"header\";
  header = \"Subject\";
  regexp = true;
  map = [
$MAPLIST
  ];
  score = 0.0;
  description = \"Signal only: phishing phrase in Subject\";
}
$END"

CP_BLOCK="$BEGIN
PHISH_LINK_AND_TEXT {
  expression = \"PHISH_URL & (PHISH_TEXT | PHISH_SUBJECT)\";
  score = 6.0;
  policy = \"leave\";
  description = \"Suspicious link and phishing phrase together\";
}
PHISH_DEFAULT_PLUS_CUSTOM {
  expression = \"PHISHING & (PHISH_URL | PHISH_TEXT | PHISH_SUBJECT)\";
  score = 3.0;
  policy = \"leave\";
  description = \"Default link mismatch plus custom rule\";
}
$END"

# ---------- plan ----------
echo
echo "Plan"
add "Install $DEST/urls.map"
for s in $ALL; do add "Install $DEST/text/$s.map  ($(grep -c '^/' "$MAPSRC/text/$s.map") phrases)"; done
[ -f "$STATE" ] && same "Currently installed sectors: $(cat "$STATE")"
if [ -d "$DEST/text" ]; then
  for f in "$DEST"/text/*.map; do
    [ -f "$f" ] || continue; s=$(basename "$f" .map)
    echo " $ALL " | grep -q " $s " || rem "Remove sector no longer chosen: $s"
  done
fi
has_block "$MM" && same "Replace managed block in $MM" || add "Append managed block to $MM  (3 rules)"
has_block "$CP" && same "Replace managed block in $CP" || add "Append managed block to $CP  (2 rules)"
# phishing feeds
FEEDS_ON=""
for fk in "openphish_enabled|OpenPhish" "phishtank_enabled|PhishTank"; do
  k=${fk%%|*}; name=${fk#*|}
  st=$(feed_state "$k")
  inblock=0
  awk -v b="$BEGIN" -v e="$END" '$0==b{s=1;next} $0==e{s=0;next} s' "$PH" 2>/dev/null | grep -q "^$k" && inblock=1
  if [ "$inblock" -eq 1 ]; then
    same "$name feed: enabled by phywall (kept)"
    FEEDS_ON+="$k = true;"$'\n'
  elif [ "$st" = true ]; then
    same "$name feed: enabled"
  elif feed_user_set "$k"; then
    warn "$name feed: turned off in your own config - not changed (set $k = true; there to use it)"
  else
    add "$name feed: will be enabled (block in $PH)"
    FEEDS_ON+="$k = true;"$'\n'
  fi
done

if [ "$MODE" = dry ]; then
  echo
  echo "Dry run - nothing changed. Run again with --apply."
  exit 0
fi

# =====================================================================
#  APPLY
# =====================================================================
echo
echo "Applying"
TS=$(date +%F_%H%M%S); BK=$BKROOT/$TS; mkdir -p "$BK"
for f in "$MM" "$CP" "$PH"; do [ -f "$f" ] && cp -p "$f" "$BK/"; done
[ -d "$DEST" ] && cp -rp "$DEST" "$BK/maps"
BEFORE=$(symbols)
ok "Backup: $BK"

restore() {
  for f in multimap.conf composites.conf phishing.conf; do
    if [ -f "$BK/$f" ]; then cp -p "$BK/$f" "$LD/$f"; else rm -f "$LD/$f"; fi
  done
  rm -rf "$DEST"; [ -d "$BK/maps" ] && cp -rp "$BK/maps" "$DEST"
}

# maps
mkdir -p "$DEST/text"
cp "$MAPSRC/urls.map" "$DEST/urls.map"
rm -f "$DEST"/text/*.map
for s in $ALL; do cp "$MAPSRC/text/$s.map" "$DEST/text/$s.map"; done
sed -i 's/[[:space:]]*$//' "$DEST/urls.map" "$DEST"/text/*.map
chown -R _rspamd:_rspamd "$DEST" 2>/dev/null || warn "chown _rspamd failed - check the Rspamd user name"
ok "Maps installed (trailing spaces removed, owner _rspamd)"

# blocks
for pair in "$MM|MM_BLOCK" "$CP|CP_BLOCK"; do
  f=${pair%%|*}; v=${pair#*|}
  [ -f "$f" ] && remove_block "$f" || : > "$f"
  { [ -s "$f" ] && echo; printf '%s\n' "${!v}"; } >> "$f"
done
# feeds block in phishing.conf (only feeds that were off)
[ -f "$PH" ] && remove_block "$PH"
if [ -n "$FEEDS_ON" ]; then
  { [ -s "$PH" ] && echo; printf '%s\n%s%s\n' "$BEGIN" "$FEEDS_ON" "$END"; } >> "$PH"
fi
[ -f "$PH" ] && [ ! -s "$PH" ] && rm -f "$PH"
ok "Managed blocks written"

# validate
if ! rspamadm configtest >/dev/null 2>&1; then
  ERR=$(rspamadm configtest 2>&1 | tail -3)
  restore
  warn "configtest FAILED - everything restored from backup:"
  echo "$ERR" | sed 's/^/      /'
  exit 1
fi
ok "configtest passed"

systemctl reload rspamd
wait_rspamd || { restore; systemctl reload rspamd; die "Rspamd did not come back - restored backup"; }
ok "Rspamd reloaded"

# verify: our symbols present, none of the old symbols lost.
# After a reload Rspamd starts new workers in the background; for a few seconds
# 'rspamc counters' can still answer from the old process -> ask again until ready.
for i in $(seq 1 20); do
  AFTER=$(symbols)
  MISSING=""
  for s in PHISH_URL PHISH_TEXT PHISH_SUBJECT PHISH_LINK_AND_TEXT PHISH_DEFAULT_PLUS_CUSTOM; do
    echo "$AFTER" | grep -qx "$s" || MISSING+=" $s"
  done
  [ -z "$MISSING" ] && break
  sleep 1
done
if [ -z "$BEFORE" ] || [ -z "$AFTER" ]; then
  warn "Could not read the Rspamd rule list (rspamc counters) - rule check skipped"
  LOST=""
else
  LOST=$(comm -23 <(echo "$BEFORE") <(echo "$AFTER") | tr '\n' ' ')
fi
if [ -n "$LOST" ]; then
  restore; systemctl reload rspamd; wait_rspamd
  die "Existing symbols disappeared ($LOST) - restored backup"
fi
[ -n "$MISSING" ] && warn "Not registered yet:$MISSING" || ok "All 5 rules registered, existing rules intact"

for fk in "openphish_enabled|OpenPhish" "phishtank_enabled|PhishTank"; do
  k=${fk%%|*}; name=${fk#*|}
  [ "$(feed_state "$k")" = true ] && ok "$name feed is active" || warn "$name feed is not active (check local.d/phishing.conf)"
done

# remember installed sectors (for update.sh)
echo $ALL | tr ' ' ',' > "$STATE"
ok "Sectors saved: $STATE"

# self-test
T=$(mktemp)
printf 'From: Test <test@example.com>\nTo: test@example.com\nSubject: Your mailbox is almost full\nContent-Type: text/plain; charset=utf-8\n\nVerify here: https://share.google/test123\n' > "$T"
R=$(rspamc --ip 192.0.2.10 --helo test.example --from test@example.com "$T" 2>/dev/null | grep -oE 'Symbol: PHISH_[A-Z_]+' | sed 's/Symbol: //' | tr '\n' ' ')
rm -f "$T"
if echo "$R" | grep -q PHISH_LINK_AND_TEXT; then ok "Self-test: $R"
else warn "Self-test: composite did not fire (got: ${R:-none}). Check that urls.map contains share.google."; fi

echo
echo "Done."
echo "  Sectors : $(echo $ALL | tr ' ' ',')"
echo "  Backup  : $BK"
echo "  Undo    : phywall configure --rollback"
