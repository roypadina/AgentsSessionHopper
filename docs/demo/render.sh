#!/bin/bash
# Regenerates the AgentsSessionHopper demo from scratch: compile the real engine (SessionHopperCore) as a module, the app's real
# PopoverView + AppModel, the kit and the scene; render frames offscreen (no window is ever shown, nothing is clicked or captured,
# the installed app and its state directory are never touched), encode. One command: ./render.sh
# AppModel.swift is compiled from a copy with ONE token changed: its `snapshot` setter is made settable, so the scene can hand the
# real view a fake snapshot at a fake clock (the real model would load the state directory and read the real clock).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${KIT:-$HERE}"; [ -f "$KIT/DemoKit.swift" ] || KIT="$HERE/../kit"          # repo: kit is vendored next to this file
APP="${APP_SRC:-$HERE/../..}"                                                   # repo: docs/demo -> repo root
GIF="${GIF:-$HERE/../demo.gif}"                                                 # repo: docs/demo.gif
BUILD="${BUILD:-${TMPDIR:-/tmp}/agents-session-hopper-demo}"                    # never inside the repo (hundreds of MB of frames)
mkdir -p "$BUILD"
swiftc -swift-version 5 -O -parse-as-library -emit-library -static -emit-module -module-name SessionHopperCore \
  -emit-module-path "$BUILD/SessionHopperCore.swiftmodule" -o "$BUILD/libSessionHopperCore.a" "$APP"/Sources/SessionHopperCore/*.swift
sed 's/@Published private(set) var snapshot:/@Published var snapshot:/' "$APP/Sources/AgentsSessionHopper/AppModel.swift" > "$BUILD/AppModel.swift"
grep -q '@Published var snapshot:' "$BUILD/AppModel.swift"
swiftc -swift-version 5 -parse-as-library -O -I "$BUILD" -L "$BUILD" -lSessionHopperCore -o "$BUILD/demo" \
  "$KIT/DemoKit.swift" "$HERE/stubs.swift" "$HERE/scene.swift" "$BUILD/AppModel.swift" "$APP/Sources/AgentsSessionHopper/PopoverView.swift"
rm -rf "$BUILD/frames"
ASH_ICONS="$APP/Assets/icons" "$BUILD/demo" "$BUILD/frames" 30 -AppleLocale en_US -AppleLanguages "(en)"
POSTER=${POSTER:-198}  # panel with the "Needs you" card (t 6.6 s; confirmed on frames-sample/f0198.png)
"$KIT/encode.sh" "$BUILD/frames" "$GIF" "${MP4:-}" "${WEBP:-}" "${POSTER:-}"
rm -rf "$BUILD/frames"                                                            # only after a successful encode (set -e)
