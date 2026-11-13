#!/usr/bin/env bash
# Packs addon/Werkbank into site/addon/Werkbank.zip, the download on the website (deploy.sh calls this).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../site/addon
rm -f ../site/addon/Werkbank.zip
# -X: no extra file attributes, so the zip only changes when the addon does
zip -qrX ../site/addon/Werkbank.zip Werkbank -x '*.DS_Store'
echo "site/addon/Werkbank.zip: $(unzip -Z1 ../site/addon/Werkbank.zip | tr '\n' ' ')"
