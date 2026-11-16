#!/bin/sh
# Regenerates docs/images/*.png with made-up sessions. Needs a Mac with the
# helper built (make build). Screenshots are taken of a plain gradient backdrop,
# not your desktop. Quit notification banners and other overlays first.
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'kill $backdrop $helper 2>/dev/null || true; rm -rf "$tmp"' EXIT

swiftc -O -o "$tmp/backdrop" tools/backdrop.swift

swiftc -O -o "$tmp/screen-size" tools/screen-size.swift
# Backdrop 1000x560 points, centered on the main screen.
read -r sw sh <<EOS
$("$tmp/screen-size")
EOS
w=1000; h=560
x=$(( (sw - w) / 2 )); y=$(( (sh - h) / 2 ))
"$tmp/backdrop" $x $y $w $h &
backdrop=$!
sleep 1

done_at=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)
cat > "$tmp/demo.json" <<JSON
{"current":"s1","sessions":[
 {"session_id":"s1","label":"marketing-site","status":{"state":"working","msg":"Refactoring the pricing page"}},
 {"session_id":"s2","label":"api-migration","status":{"state":"blocked","kind":"permission","msg":"Allow running npm test?"}},
 {"session_id":"s3","label":"docs-rewrite","status":{"state":"done","updated_at":"$done_at"}},
 {"session_id":"s4","label":"infra-terraform","status":{"state":"error","msg":"terraform apply failed"}},
 {"session_id":"s5","label":"scratch"}]}
JSON

# Capture rectangle in screen points, origin top-left.
top=$(( sh - y - h ))
shoot() {
  sleep 1.5
  screencapture -x -R"$x,$top,$w,$h" "$1"
}

# shoot NAME [ENV=VALUE...]: runs the switcher with made-up sessions and photographs it.
capture() {
  name=$1; shift
  env REX_SWITCHER_POSITION=screen "$@" ./rex-session-switcher < "$tmp/demo.json" > /dev/null &
  helper=$!
  shoot "docs/images/$name.png"
  kill $helper 2>/dev/null || true
  wait $helper 2>/dev/null || true
}

capture switcher REX_SWITCHER_APPEARANCE=light
capture actions REX_SWITCHER_APPEARANCE=light REX_SWITCHER_START=actions
capture switcher-dark REX_SWITCHER_APPEARANCE=dark
