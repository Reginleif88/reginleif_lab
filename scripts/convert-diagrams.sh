#!/bin/bash
# Convert .drawio files to SVG using draw.io CLI
#
# Prerequisites:
#   - Install draw.io desktop on Linux:
#     sudo snap install drawio
#     OR download from https://github.com/jgraph/drawio-desktop/releases
#
# Usage:
#   ./scripts/convert-diagrams.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAGRAMS_DIR="$SCRIPT_DIR/../diagrams"

# Check if drawio CLI is available
if ! command -v drawio &> /dev/null; then
    echo "Error: draw.io CLI not found."
    echo "Install it via: sudo snap install drawio"
    echo "Or download from: https://github.com/jgraph/drawio-desktop/releases"
    exit 1
fi

echo "Converting diagrams..."

# Convert network diagram
if [ -f "$DIAGRAMS_DIR/network-diagram.drawio" ]; then
    echo "  → network-diagram.drawio"
    drawio -x -f svg --transparent -o "$DIAGRAMS_DIR/network-diagram.svg" "$DIAGRAMS_DIR/network-diagram.drawio"
else
    echo "  ⚠ network-diagram.drawio not found, skipping"
fi

# Convert PKI diagram
if [ -f "$DIAGRAMS_DIR/pki-diagram.drawio" ]; then
    echo "  → pki-diagram.drawio"
    drawio -x -f svg --transparent -o "$DIAGRAMS_DIR/pki-diagram.svg" "$DIAGRAMS_DIR/pki-diagram.drawio"
else
    echo "  ⚠ pki-diagram.drawio not found, skipping"
fi

# Convert firewall diagram
if [ -f "$DIAGRAMS_DIR/firewall-diagram.drawio" ]; then
    echo "  → firewall-diagram.drawio"
    drawio -x -f svg --transparent -o "$DIAGRAMS_DIR/firewall-diagram.svg" "$DIAGRAMS_DIR/firewall-diagram.drawio"
else
    echo "  ⚠ firewall-diagram.drawio not found, skipping"
fi

echo "Done! SVG files generated in $DIAGRAMS_DIR"
