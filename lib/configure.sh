#!/bin/bash
# =====================================================================
#  configuration.sh - prepares Rspamd for the phishing-detector
#  Part of: phishing-detector by Develust Technology
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
#  It also saves the installed sectors in <project>/.sectors
# =====================================================================
LIB=$(dirname "$(readlink -f "$0")")     
ROOT=$(dirname "$LIB")                   
source "$LIB/common.sh"
banner

# ---------- paths ----------
DIR=$(dirname "$(readlink -f "$0")")
MAPSRC=$ROOT/maps
RSPAMD=${RSPAMD_DIR:-/etc/rspamd}
LD=$RSPAMD/local.d
MM=$LD/multimap.conf
CP=$LD/composites.conf
DEST=$RSPAMD/maps/phishing
BKROOT=$ROOT/backups
STATE=$ROOT/.sectors          # installed sectors on this server (used by update.sh)
BEGIN='# BEGIN phishing-detector (managed by configuration.sh - do not edit)'
END='# END phishing-detector'
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
  awk -v b="$BEGIN" -v e="$END" '$0==b{s=1;next} $0==e{s=0;next} !s' "$1"
}

# remove our block in place (keeps owner/permissions), trims trailing empty lines
remove_block() {
  [ -f "$1" ] || return 0
  local tmp; tmp=$(strip_block "$1")
  printf '%s\n' "$tmp" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$1.pd.tmp" && cat "$1.pd.tmp" > "$1" && rm -f "$1.pd.tmp"
  [ -s "$1" ] && ! grep -q '[^[:space:]]' "$1" && : > "$1"
  return 0
}

has_block() { [ -f "$1" ] && grep -qxF "$BEGIN" "$1"; }

# symbols registered in running Rspamd
symbols() { rspamc counters 2>/dev/null | awk -F'|' 'NF>3{gsub(/ /,"",$3); if($3!="" && $3!="Symbol") print $3}' | sort -u; }

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
  if ! has_block "$MM" && ! has_block "$CP" && [ ! -d "$DEST" ]; then
    same "Nothing installed - nothing to remove"; exit 0
  fi
  TS=$(date +%F_%H%M%S); BK=$BKROOT/$TS; mkdir -p "$BK"
  for f in "$MM" "$CP"; do [ -f "$f" ] && cp -p "$f" "$BK/"; done
  [ -d "$DEST" ] && cp -rp "$DEST" "$BK/maps"
  ok "Safety backup: $BK"

  has_block "$MM" && remove_block "$MM" && rem "Removed block from $MM"
  has_block "$CP" && remove_block "$CP" && rem "Removed block from $CP"
  [ -d "$DEST" ] && rm -rf "$DEST" && rem "Removed $DEST"
  [ -f "$STATE" ] && rm -f "$STATE" && rem "Removed $STATE"

  if ! rspamadm configtest >/dev/null 2>&1; then
    warn "configtest failed after rollback - restoring safety backup"
    for f in multimap.conf composites.conf; do [ -f "$BK/$f" ] && cp -p "$BK/$f" "$LD/$f"; done
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
grep -qsE '^[[:space:]]*openphish_enabled[[:space:]]*=[[:space:]]*true' "$LD/phishing.conf" \
  && same "OpenPhish feed is enabled (local.d/phishing.conf)" \
  || warn "OpenPhish feed is not enabled in local.d/phishing.conf (optional, not changed)"

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
for f in "$MM" "$CP"; do [ -f "$f" ] && cp -p "$f" "$BK/"; done
[ -d "$DEST" ] && cp -rp "$DEST" "$BK/maps"
BEFORE=$(symbols)
ok "Backup: $BK"

restore() {
  for f in multimap.conf composites.conf; do
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

# verify: our symbols present, none of the old symbols lost
AFTER=$(symbols)
MISSING=""
for s in PHISH_URL PHISH_TEXT PHISH_SUBJECT PHISH_LINK_AND_TEXT PHISH_DEFAULT_PLUS_CUSTOM; do
  echo "$AFTER" | grep -qx "$s" || MISSING+=" $s"
done
LOST=$(comm -23 <(echo "$BEFORE") <(echo "$AFTER") | tr '\n' ' ')
if [ -n "$LOST" ]; then
  restore; systemctl reload rspamd; wait_rspamd
  die "Existing symbols disappeared ($LOST) - restored backup"
fi
[ -n "$MISSING" ] && warn "Not registered yet:$MISSING" || ok "All 5 rules registered, existing rules intact"

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
echo "  Undo    : $0 --rollback"