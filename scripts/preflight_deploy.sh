#!/usr/bin/env bash
# ==============================================================================
# SeSe Pre-flight Security Rules & Storage Deployment Script
#
# Production Rule: ALWAYS deploy Firestore security rules and Cloud Storage rules
# BEFORE or simultaneously with client application builds/releases.
# This prevents client permission-denied crashes caused by new schema fields or
# updated auth guards not yet active on the backend.
# ==============================================================================

set -euo pipefail

echo "=================================================="
echo " [SeSe Pre-Flight] Validating & Deploying Rules "
echo "=================================================="

# 1. Verify required files exist
if [ ! -f "firestore.rules" ]; then
  echo "❌ Error: firestore.rules not found in $(pwd)"
  exit 1
fi

if [ ! -f "storage.rules" ]; then
  echo "❌ Error: storage.rules not found in $(pwd)"
  exit 1
fi

# 2. Check firebase CLI is installed
if ! command -v firebase &> /dev/null; then
  echo "❌ Error: Firebase CLI (firebase) is not installed or not in PATH."
  exit 1
fi

echo "🔍 Validating active Firebase project..."
firebase projects:list > /dev/null

echo "🚀 Deploying Firestore & Storage Security Rules..."
firebase deploy --only firestore:rules,storage

echo "✅ Pre-flight security rules deployment completed successfully."
