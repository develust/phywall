#!/bin/bash
# =====================================================================
#  lib/common.sh - shared parts of phywall (loaded by every command)
#  Part of: phywall by Develust Technology
# =====================================================================

PHYWALL_VERSION="1.0.0"

# ---------- banner (screen only, never in logs) ----------
banner() {
  local G="" R="" Y="" D="" N=""
  if [ -t 2 ]; then G=$'\e[38;5;36m'; R=$'\e[1;31m'; Y=$'\e[1;33m'; D=$'\e[2m'; N=$'\e[0m'; fi
  cat >&2 <<EOF_BANNER
${G}                ## #${N}
${G}           ###########${N}
${G}          ################${N}
${G}        ####################${N}
${G}       #####################${N}
${G}      #######################     ${N}${R}########  ##     ## ##    ## ##      ##    ###    ##       ##${N}
${G}      ########################    ${N}${R}##     ## ##     ##  ##  ##  ##  ##  ##   ## ##   ##       ##${N}
${G}      ########################    ${N}${R}##     ## ##     ##   ####   ##  ##  ##  ##   ##  ##       ##${N}
${G}      #######################     ${N}${R}########  #########    ##    ##  ##  ## ##     ## ##       ##${N}
${G}      ######### #### ########     ${N}${R}##        ##     ##    ##    ##  ##  ## ######### ##       ##${N}
${G}       # #####  #### ###### #     ${N}${R}##        ##     ##    ##    ##  ##  ## ##     ## ##       ##${N}
${G}       # #     ####  ### ###      ${N}${R}##        ##     ##    ##     ###  ###  ##     ## ######## ########${N}
${G}              ######${N}
${G}           ##############         ${N}${Y}Phishing defense for Rspamd mail servers${N}
${G}        ####################${N}
${G}        ##################        ${N}${D}by Develust Technology  |  develust.com${N}
${G}          ##############${N}
${G}                ##     #${N}

   ${R}[ PHYWALL v${PHYWALL_VERSION} ]${N}  Finds phishing in your mailboxes, moves it to Junk,
   reports lures your staff forwarded, and teaches Rspamd to catch the next wave.
   Contact: support@develust.com

EOF_BANNER
}