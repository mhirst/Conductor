#!/bin/sh
# Symlinks the Conductor remote script into Ableton's User Library so edits here go live
# after toggling the control surface (or restarting Live).
set -e
SRC="$(cd "$(dirname "$0")" && pwd)/Conductor"
DEST="$HOME/Music/Ableton/User Library/Remote Scripts"
mkdir -p "$DEST"
ln -sfn "$SRC" "$DEST/Conductor"
echo "Linked $SRC -> $DEST/Conductor"
echo "In Live: Settings > Link, Tempo & MIDI > Control Surface: Conductor (Input/Output: None)"
