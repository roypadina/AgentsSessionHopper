#!/usr/bin/env bash
# Renders docs/brand/icon-beta.png: the app icon with a BETA ribbon, for README / wiki / site images.
# The app bundle keeps the plain icon. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p docs/brand
RIBBON='<g clip-path="url(#sq)"><g transform="translate(748 276) rotate(45)"><rect x="-420" y="-62" width="840" height="124" fill="#FFD60A"/><rect x="-420" y="-62" width="840" height="124" fill="none" stroke="#000" stroke-opacity=".25" stroke-width="4"/><text x="0" y="30" text-anchor="middle" font-family="Helvetica Neue, Helvetica, Arial, sans-serif" font-weight="bold" font-size="88" letter-spacing="14" fill="#1A1A1A">BETA</text></g></g>'
sed "s|</svg>|${RIBBON}</svg>|" Assets/icons/AppIcon.svg > docs/brand/icon-beta.svg
rsvg-convert -w 512 -h 512 docs/brand/icon-beta.svg -o docs/brand/icon-beta.png
echo docs/brand/icon-beta.png
