#!/usr/bin/env bash
# Diagnose and repair a menu bar item that macOS refuses to show.
#
# Usage:
#   scripts/fix-menubar-item.sh [BUNDLE_ID] [--fix]
#
#   BUNDLE_ID  defaults to com.itzbubschki.ClaudeUsageMenuBar
#   --fix      apply the repair (without it, the script only reports)
#
# Symptom this fixes:
#   The menu bar icon appears for a fraction of a second and vanishes, and the app
#   quits immediately afterwards. Console shows ControlCenter emitting:
#
#       [controlcenter:appStatusItems] Moving host to blocked list; (bid:<id>-Item-0-<pid>)
#       [controlcenter:appStatusItems] Requesting blocked host to not be visible
#
#   AppKit terminates a MenuBarExtra app when its only status item is removed, and on
#   the way out it writes "NSStatusItem VisibleCC Item-0 = 0" into the app's own
#   defaults — so the app is dead long before the Control Center switch can act on it.
#
# Cause:
#   macOS stores per-app menu bar permissions in
#     ~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/
#         group.com.apple.controlcenter.plist   ->  key "trackedApplications"
#
#   That is a nested binary plist holding a flat list of alternating key/value pairs:
#
#     { bundle: { _0: "com.example.app" } }                                   <- key
#     { location: {...}, menuItemLocations: [ {bundle:{_0:...}}, ... ],        <- value
#       isAllowed: true|false }
#
#   Rapid churn of a menu bar item (repeatedly replacing the .app bundle, SIGKILLing
#   the process while its status item is registering, or running two instances at once)
#   can leave the app's bundle id listed inside *another* app's menuItemLocations. If
#   that other app's entry has isAllowed = false, the item is blocked forever — even
#   though the app's own entry still says isAllowed = true.
#
#   Nothing else clears it: reinstalling, re-signing, resetting Control Center,
#   tccutil, deleting the app's prefs, logging out, and rebooting all leave it in place,
#   because the poisoned reference lives under a different app's key. Changing the app's
#   bundle id "works" only by escaping the poisoned group.
#
# Note: this is machine-local state. It is not fixed by shipping new code.

set -euo pipefail

BUNDLE_ID="com.itzbubschki.ClaudeUsageMenuBar"
APPLY=0

for arg in "$@"; do
    case "$arg" in
        --fix) APPLY=1 ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
        *) BUNDLE_ID="$arg" ;;
    esac
done

PLIST="$HOME/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"
[[ -f "$PLIST" ]] || { printf 'not found: %s\n' "$PLIST" >&2; exit 1; }

if [[ "$APPLY" -eq 1 ]]; then
    BACKUP="${PLIST%.plist}.plist.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$PLIST" "$BACKUP"
    printf 'backup: %s\n' "$BACKUP"
fi

BUNDLE_ID="$BUNDLE_ID" APPLY="$APPLY" PLIST="$PLIST" python3 <<'PY'
import os, plistlib, sys

path = os.environ["PLIST"]
target = os.environ["BUNDLE_ID"]
apply_fix = os.environ["APPLY"] == "1"

outer = plistlib.load(open(path, "rb"))
if "trackedApplications" not in outer:
    print("no trackedApplications key; nothing to inspect")
    sys.exit(0)

entries = plistlib.loads(outer["trackedApplications"])

def bid(x):
    if isinstance(x, dict) and isinstance(x.get("bundle"), dict):
        return x["bundle"].get("_0")
    return None

problems = []
own = None
i = 0
while i < len(entries) - 1:
    key, val = entries[i], entries[i + 1]
    if isinstance(val, dict) and "menuItemLocations" in val:
        owner = bid(key)
        locs = [bid(m) for m in val.get("menuItemLocations", [])]
        allowed = val.get("isAllowed")
        if owner == target:
            own = allowed
        elif target in locs:
            problems.append((i + 1, owner, locs, allowed))
        i += 2
    else:
        i += 1

print(f"own entry for {target}: isAllowed={own}")
if not problems:
    print("no foreign entries reference this bundle id — nothing to repair")
    sys.exit(0)

for _, owner, locs, allowed in problems:
    state = "BLOCKING" if allowed is False else "harmless (owner is allowed)"
    print(f"  listed under {owner!r} (isAllowed={allowed}) -> {state}")
    print(f"    menuItemLocations: {locs}")

if not apply_fix:
    print("\nre-run with --fix to remove this bundle id from the entries above")
    sys.exit(0)

for idx, owner, _, _ in problems:
    val = entries[idx]
    val["menuItemLocations"] = [
        m for m in val["menuItemLocations"] if bid(m) != target
    ]
    print(f"repaired {owner}")

outer["trackedApplications"] = plistlib.dumps(entries, fmt=plistlib.FMT_BINARY)
plistlib.dump(outer, open(path, "wb"), fmt=plistlib.FMT_BINARY)
print("written")
PY

if [[ "$APPLY" -eq 1 ]]; then
    # cfprefsd caches the group container plist; ControlCenter caches trackedApplications
    # in memory and would write its stale copy back over the repair.
    killall cfprefsd 2>/dev/null || true
    sleep 1
    killall ControlCenter 2>/dev/null || true
    printf 'restarted cfprefsd and ControlCenter — relaunch the app now\n'
fi
