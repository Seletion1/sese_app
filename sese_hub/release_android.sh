#!/bin/bash
set -e

cd /Users/micheal/sese_app/sese_hub

PUBSPEC="pubspec.yaml"

# Read current version line (e.g., version: 1.0.3+4)
CURRENT=$(grep "^version:" "$PUBSPEC" | awk '{print $2}')
NAME=$(echo "$CURRENT" | cut -d'+' -f1)
CODE=$(echo "$CURRENT" | cut -d'+' -f2)

# Split major.minor.patch and increment patch + build code
MAJOR=$(echo "$NAME" | cut -d'.' -f1)
MINOR=$(echo "$NAME" | cut -d'.' -f2)
PATCH=$(echo "$NAME" | cut -d'.' -f3)

NEW_PATCH=$((PATCH + 1))
NEW_CODE=$((CODE + 1))
NEW_VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}+${NEW_CODE}"

sed -i '' "s/^version: .*/version: ${NEW_VERSION}/" "$PUBSPEC"
echo "🚀 sese_hub version bumped: $CURRENT -> $NEW_VERSION"

shorebird release android
