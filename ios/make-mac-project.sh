#!/bin/sh
# Dev: a Mac (Catalyst) project from the same sources: only the app target, no Watch app, signed locally.
# Usage: ./make-mac-project.sh && xcodebuild -project BeistandMac.xcodeproj -target Beistand -sdk macosx \
#   CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" build
set -e
cd "$(dirname "$0")"
python3 - <<'PY'
lines = open("project.yml").read().split("\n")
end = lines.index("  BeistandWatch:")          # the app target is everything before the watch target
keep = [l for l in lines[:end] if l.strip() not in ("dependencies:", "- target: BeistandWatch")]
keep[0] = "name: BeistandMac"
# Mac Catalyst 26+: the Mac has the newer APIs (translation) that the iPhone app checks for at runtime.
i = keep.index("    settings:", keep.index("  Beistand:"))
keep.insert(i + 2, "        IPHONEOS_DEPLOYMENT_TARGET: \"26.0\"")
open("project-mac.yml", "w").write("\n".join(keep) + "\n")
PY
xcodegen generate --spec project-mac.yml -q
