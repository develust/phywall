#!/bin/bash
# =====================================================================
#  lib/update.sh - updates phywall from GitHub releases (no git needed)
#  Part of: phywall by Develust Technology
#
#  Usage: phywall update            -> checks: current vs latest version, changes nothing
#         phywall update --apply    -> downloads, installs, reloads maps into Rspamd
#         phywall update --apply --force   -> reinstall even if already up to date
#
#  Private repo (before public release): export GITHUB_TOKEN=<token> first.
# =====================================================================
LIB=$(dirname "$(readlink -f "$0")")
ROOT=$(dirname "$LIB")
source "$LIB/common.sh"
banner

REPO=${PHYWALL_REPO:-develust/phywall}
API=${PHYWALL_API:-https://api.github.com}/repos/$REPO/releases/latest

ok()   { echo "  [✓] $*"; }
warn() { echo "  [!] $*"; }
die()  { echo "  [✗] $*"; exit 1; }

MODE=check; FORCE=0
for a in "$@"; do
  case "$a" in
    --apply) MODE=apply ;;
    --force) FORCE=1 ;;
    -h|--help) grep -A3 '^#  Usage:' "$0" | sed 's/^#  //'; exit 0 ;;
    *) echo "Unknown option: $a"; exit 1 ;;
  esac
done

# ---------- preflight ----------
echo "Preflight checks"
[ "$(id -u)" -eq 0 ] || die "Run as root"
for c in curl tar; do command -v $c >/dev/null || die "Command not found: $c"; done
AUTH=(); [ -n "$GITHUB_TOKEN" ] && AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")

# ---------- latest release ----------
github_get() {   # $1 = URL ; prints the HTTP status code, body goes to $TMPJ
  curl -s --max-time 20 "${AUTH[@]}" -H "Accept: application/vnd.github+json" -o "$TMPJ" -w '%{http_code}' "$1" 2>/dev/null
}
TMPJ=$(mktemp)
CODE=$(github_get "$API")
if [ "$CODE" != 200 ]; then
  REPOCODE=$(github_get "${API%/releases/latest}")
  case "$CODE/$REPOCODE" in
    000/*)   rm -f "$TMPJ"; die "No connection to GitHub (api.github.com). Check internet / DNS / firewall." ;;
    401/*)   rm -f "$TMPJ"; die "GitHub rejected the token (401): invalid, expired or deleted. Create a new one." ;;
    404/200) rm -f "$TMPJ"; die "No published release yet on github.com/$REPO. Publish one (Releases -> Draft a new release)." ;;
    404/404) rm -f "$TMPJ"
             if [ -n "$GITHUB_TOKEN" ]; then die "Repo $REPO not found, or the token has no access to it."
             else die "Repo $REPO not found. If it is private: export GITHUB_TOKEN=<token> first."; fi ;;
    403/*)   rm -f "$TMPJ"; die "GitHub refused access (403): token without permission, or API rate limit reached. Try again later." ;;
    *)       rm -f "$TMPJ"; die "GitHub answered HTTP $CODE - try again later." ;;
  esac
fi
JSON=$(cat "$TMPJ"); rm -f "$TMPJ"
TAG=$(echo "$JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
TARBALL=$(echo "$JSON" | grep -m1 '"tarball_url"' | sed -E 's/.*"tarball_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
[ -n "$TAG" ] && [ -n "$TARBALL" ] || die "No release found on GitHub for $REPO"
LATEST=${TAG#v}; CUR=$PHYWALL_VERSION

echo
echo "  Installed : v$CUR"
echo "  Latest    : v$LATEST   (github.com/$REPO)"
NEWEST=$(printf '%s\n%s\n' "$CUR" "$LATEST" | sort -V | tail -1)

if [ "$CUR" = "$LATEST" ] || [ "$NEWEST" = "$CUR" ]; then
  if [ "$FORCE" -eq 0 ]; then
    echo; ok "phywall is up to date."
    exit 0
  fi
  warn "Already up to date - reinstalling (--force)"
else
  ok "Update available: v$CUR -> v$LATEST"
fi

if [ "$MODE" = check ]; then
  echo
  echo "Nothing changed. Run 'phywall update --apply' to install v$LATEST."
  exit 0
fi

# =====================================================================
#  APPLY
# =====================================================================
echo
echo "Updating"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL --max-time 120 "${AUTH[@]}" "$TARBALL" -o "$TMP/phywall.tar.gz" || die "Download failed"
tar xzf "$TMP/phywall.tar.gz" -C "$TMP" || die "Archive is damaged"
NEW=$(find "$TMP" -mindepth 1 -maxdepth 2 -type f -name install.sh -printf '%h\n' | head -1)
[ -n "$NEW" ] && [ -f "$NEW/lib/common.sh" ] || die "Downloaded archive is not a phywall release"
ok "Downloaded v$LATEST"

# install over the current installation (keeps logs/, backups/, .sectors)
PREFIX="$ROOT" bash "$NEW/install.sh" 2>/dev/null | grep -E '\[(✓|!|✗)\]' | grep -vE 'Next step|List sectors'
[ "${PIPESTATUS[0]}" -eq 0 ] || die "Install step failed - see: bash $NEW/install.sh"

# reload maps into Rspamd with the sectors this server uses
if [ -f "$ROOT/.sectors" ]; then
  S=$(cat "$ROOT/.sectors")
  echo
  echo "Reloading maps into Rspamd (sectors: $S)"
  bash "$ROOT/lib/configure.sh" --sector "$S" --apply 2>/dev/null | grep -E '\[(✓|!|✗|-|\+)\]'
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "configure failed - previous Rspamd config was restored automatically"
else
  warn "Rspamd not configured yet on this server - run: phywall configure --sector <sectors>"
fi

echo
echo "Done. phywall is now v$LATEST."
