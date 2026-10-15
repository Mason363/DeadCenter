#!/bin/bash
# Builds the Chrome and Firefox/Zen flavors of the Dead Center web extension.
#
#   Scripts/build-extensions.sh                 dist/chrome, dist/firefox, dist/dead-center-chrome.zip,
#                                               dist/dead-center-firefox.xpi
#   Scripts/build-extensions.sh --embed DIR     also copies them to DIR/Chrome, DIR/Firefox, DIR/DeadCenter.xpi
#                                               (the app target runs this with DIR = Contents/Resources/Extensions)
#
# WebExtension/ itself is the Safari flavor; it ships inside the Safari app extension as is.
# vendor/Readability.js is Mozilla Readability 0.6.0 (https://github.com/mozilla/readability/tree/0.6.0).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/WebExtension"
DIST="$ROOT/dist"
PYTHON="${PYTHON:-/usr/bin/python3}"

# Chrome derives an extension's ID from its public key, so unpacked installs get a stable ID that the
# native-messaging host manifest (BrowserIntegration.chromeExtensionID) can allow. The private key isn't
# needed to build or load the extension.
CHROME_KEY="MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlsm8SQa7nnX5HlVdpMf7JpCeTCinLRqhlev/6GFALpMn3RsCtf4RDKcsVHk6PbG+j1cGuAdoNlA9ITg443X5Y7EfIm/Z8kFy1np4k2kJ3BFdQNBjtZYgatbSlxJ1Exbxug+5gbeeGIHsppP8umEDH+hi03vjqJPRncAhIQXDxLacv3WQ8nWqmgQODexjPN+yyJvjeQUIzQ47Q+1gaxXnlbFEXV1aHMnnB5lCINKeE0pbLUEDTvDROgduHoNXnBDFnKEqTic5J03ChVUpEbRlenlizHHCYmOY3NROUnAnAnyNiKG/I8We0TWcYp3kgrSj0qza/vG6G8FCJ72l1UhGbQIDAQAB"
CHROME_ID="ghjobggknlahpjlmhbkmphnbejehmlai"
GECKO_ID="deadcenter@mason363.com"
GECKO_MIN="140.0"

EMBED=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --embed) EMBED="${2:?--embed needs a directory}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
done

computed_id="$(printf %s "$CHROME_KEY" | base64 --decode | shasum -a 256 | cut -c1-32 | tr '0-9a-f' 'a-p')"
if [[ "$computed_id" != "$CHROME_ID" ]]; then
  echo "error: Chrome key gives ID $computed_id, expected $CHROME_ID" >&2
  exit 1
fi

for flavor in chrome firefox; do
  rm -rf "$DIST/$flavor"
  mkdir -p "$DIST/$flavor"
  rsync -a --exclude .DS_Store "$SRC/" "$DIST/$flavor/"
done

# Writes the browser-specific manifests and checks every manifest for what the extension relies on.
"$PYTHON" -I - "$SRC" "$DIST" "$CHROME_KEY" "$GECKO_ID" "$GECKO_MIN" <<'PY'
import json, os, sys

src, dist, chrome_key, gecko_id, gecko_min = sys.argv[1:]

with open(os.path.join(src, "manifest.json")) as f:
    base = json.load(f)

chrome = dict(base, key=chrome_key, background={"service_worker": "background.js"},
              minimum_chrome_version="116")
firefox = dict(base, background={"scripts": ["background.js"]}, browser_specific_settings={
    "gecko": {
        "id": gecko_id,
        "strict_min_version": gecko_min,
        "data_collection_permissions": {"required": ["none"]},
    }
})

for name, manifest in (("chrome", chrome), ("firefox", firefox)):
    with open(os.path.join(dist, name, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")

problems, warnings = [], []
for name, manifest, root in (("safari", base, src), ("chrome", chrome, os.path.join(dist, "chrome")),
                             ("firefox", firefox, os.path.join(dist, "firefox"))):
    def need(ok, what):
        if not ok:
            problems.append(f"{name}: {what}")
    need(manifest.get("manifest_version") == 3, "manifest_version must be 3")
    for key in ("name", "version", "action", "icons", "background", "permissions", "commands"):
        need(key in manifest, f"missing {key}")
    need("default_popup" not in manifest.get("action", {}), "the toolbar button must not have a popup")
    for permission in ("activeTab", "scripting", "contextMenus", "nativeMessaging"):
        need(permission in manifest.get("permissions", []), f"missing permission {permission}")
    command = manifest.get("commands", {}).get("read-page", {})
    need(command.get("suggested_key", {}).get("mac") == "MacCtrl+Shift+Period",
         "read-page must be MacCtrl+Shift+Period (the app synthesizes it)")
    background = manifest.get("background", {})
    for script in background.get("scripts", []) + [background.get("service_worker")]:
        need(script is None or os.path.isfile(os.path.join(root, script)), f"missing {script}")
    for path in ("content/extract.js", "vendor/Readability.js", "pages/setup.html"):
        need(os.path.isfile(os.path.join(root, path)), f"missing {path}")
    icons = set(manifest.get("icons", {}).values()) | set(manifest.get("action", {}).get("default_icon", {}).values())
    missing = sorted(icon for icon in icons if not os.path.isfile(os.path.join(root, icon)))
    if missing and name == "safari":
        warnings.append("icons not generated yet: " + ", ".join(missing))

need("service_worker" in chrome["background"] and "scripts" not in chrome["background"], "chrome background")
need(firefox["browser_specific_settings"]["gecko"]["id"] == gecko_id, "firefox gecko id")

for warning in warnings:
    print(f"warning: web extension {warning}")
if problems:
    for problem in problems:
        print(f"error: web extension {problem}", file=sys.stderr)
    sys.exit(1)
PY

rm -f "$DIST/dead-center-chrome.zip" "$DIST/dead-center-firefox.xpi"
(cd "$DIST/chrome" && zip -q -X -r -D "$DIST/dead-center-chrome.zip" .)
(cd "$DIST/firefox" && zip -q -X -r -D "$DIST/dead-center-firefox.xpi" .)

if [[ -n "$EMBED" ]]; then
  mkdir -p "$EMBED"
  rsync -a --delete "$DIST/chrome/" "$EMBED/Chrome/"
  rsync -a --delete "$DIST/firefox/" "$EMBED/Firefox/"
  cp -X "$DIST/dead-center-firefox.xpi" "$EMBED/DeadCenter.xpi"
fi

echo "Built Chrome (ID $CHROME_ID) and Firefox ($GECKO_ID) extensions in $DIST${EMBED:+, embedded in $EMBED}"
