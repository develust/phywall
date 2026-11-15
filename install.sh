#!/bin/bash
# =====================================================================
#  install.sh - installs or updates phywall
#  Part of: phywall by Develust Technology
#
#  Usage:  sudo ./install.sh        (run from the unpacked phywall folder)
#
#  Fresh install : copies the tool to /opt/phywall and creates the
#                  command /usr/local/bin/phywall
#  Update        : replaces the program files (lib/, maps/, phywall) and
#                  KEEPS logs/, backups/ and .sectors
# =====================================================================
SRC=$(dirname "$(readlink -f "$0")")
PREFIX=${PREFIX:-/opt/phywall}
BINDIR=${BINDIR:-/usr/local/bin}

[ -f "$SRC/lib/common.sh" ] || { echo "lib/common.sh not found - run install.sh from the phywall folder"; exit 1; }
source "$SRC/lib/common.sh"
banner

ok()   { echo "  [✓] $*"; }
warn() { echo "  [!] $*"; }
die()  { echo "  [✗] $*"; exit 1; }

# ---------- preflight ----------
echo "Preflight checks"
[ "$(id -u)" -eq 0 ] || die "Run as root (sudo ./install.sh)"
[ "$(readlink -f "$SRC")" != "$(readlink -f "$PREFIX")" ] || die "Already running from $PREFIX - run install.sh from the downloaded folder"
for d in lib maps maps/text; do [ -d "$SRC/$d" ] || die "Missing folder: $SRC/$d"; done
[ -f "$SRC/maps/urls.map" ] && [ -f "$SRC/maps/text/common.map" ] || die "Missing maps (urls.map / text/common.map)"

# required: Rspamd tools + basic utilities the scripts use
MISS=""
for c in rspamc rspamadm systemctl awk sed grep find iconv base64; do command -v $c >/dev/null || MISS+=" $c"; done
[ -n "$MISS" ] && die "Missing commands:$MISS   (install Rspamd and the missing tools first)"
command -v doveadm >/dev/null || warn "doveadm not found - 'scan' needs Dovecot (configure/learn still work)"
ok "Requirements found"

# ---------- fresh install or update ----------
if [ -f "$PREFIX/lib/common.sh" ]; then
  OLD=$(grep -m1 '^PHYWALL_VERSION=' "$PREFIX/lib/common.sh" | cut -d'"' -f2)
  MODE=update
  ok "Existing installation found: v${OLD:-unknown} -> v$PHYWALL_VERSION (update)"
else
  MODE=fresh
  ok "Fresh install: v$PHYWALL_VERSION -> $PREFIX"
fi

# ---------- copy program files ----------
echo
echo "Installing"
mkdir -p "$PREFIX"
rm -rf "$PREFIX/lib" "$PREFIX/maps"                 # program files are replaced
cp -a "$SRC/lib" "$SRC/maps" "$PREFIX/"
for f in phywall README.md LICENSE; do [ -f "$SRC/$f" ] && cp -a "$SRC/$f" "$PREFIX/"; done
sed -i 's/[[:space:]]*$//' "$PREFIX/maps/urls.map" "$PREFIX"/maps/text/*.map   # Rspamd 4.x ignores lines with trailing spaces
mkdir -p "$PREFIX/logs" "$PREFIX/backups"           # kept on update
chown -R root:root "$PREFIX"
chmod 700 "$PREFIX" "$PREFIX/logs" "$PREFIX/backups"
chmod 700 "$PREFIX"/lib/*.sh
[ -f "$PREFIX/phywall" ] && chmod 700 "$PREFIX/phywall"
ok "Files installed in $PREFIX  ($(ls "$PREFIX"/maps/text/*.map | wc -l) sector maps)"

# ---------- command ----------
if [ -f "$PREFIX/phywall" ]; then
  ln -sfn "$PREFIX/phywall" "$BINDIR/phywall"
  ok "Command ready: $BINDIR/phywall"
else
  warn "Router file 'phywall' not found - command not created yet (scripts work via $PREFIX/lib/*.sh)"
fi

# ---------- next steps ----------
echo
echo "Done."
if [ "$MODE" = update ] && [ -f "$PREFIX/.sectors" ]; then
  echo "  Installed sectors on this server: $(cat "$PREFIX/.sectors")"
  echo "  To load the new maps into Rspamd, run configure again with the same sectors:"
  echo "    phywall configure --sector $(cat "$PREFIX/.sectors") --apply"
else
  echo "  Next step - set up Rspamd (dry run first):"
  echo "    phywall configure --sector <your sectors>"
  echo "  List sectors:  phywall configure --sectors"
fi
