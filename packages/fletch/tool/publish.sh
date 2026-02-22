#!/bin/bash
# Step 2: Publish to pub.dev
# This script verifies Rob's notice is present and publishes
# Run tool/switch_readme.sh first!

set -e  # Exit on error

echo "🚀 Fletch Publish Script"
echo "======================="
echo ""

# Check if we're in the right directory
if [ ! -f "pubspec.yaml" ]; then
    echo "❌ Error: pubspec.yaml not found. Run this script from packages/fletch/"
    exit 1
fi

# Check if package name is fletch
if ! grep -q "name: fletch" pubspec.yaml; then
    echo "❌ Error: This doesn't appear to be the fletch package"
    exit 1
fi

# CRITICAL: Check if Rob's notice is present
echo "🔍 Step 1: Verifying Rob's credit notice..."
if ! grep -q "Package History Notice" README.md; then
    echo "   ❌ ERROR: Rob's credit notice NOT found in README.md!"
    echo ""
    echo "You must run ./tool/switch_readme.sh first to inject the notice."
    echo ""
    exit 1
fi

if ! grep -q "Rob Kellett" README.md; then
    echo "   ❌ ERROR: Rob Kellett's name NOT found in README.md!"
    echo ""
    echo "You must run ./tool/switch_readme.sh first to inject the notice."
    echo ""
    exit 1
fi

echo "   ✅ Rob's credit notice is present"

echo ""
if [[ "$1" == "--yes" || "$1" == "-y" ]]; then
    echo "⚠️  Skipping dry-run in force mode (CI/Automation)"
    echo "   (This avoids failing on warnings like 'dirty git tree' caused by switch_readme.sh)"
else
    echo " Step 2: Running dry-run..."
    if dart pub publish --dry-run; then
        echo "   ✅ Dry-run passed!"
    else
        echo "   ❌ Dry-run failed!"
        exit 1
    fi
fi

echo ""
echo "🎯 Step 3: Ready to publish!"
echo ""
echo "Current README preview:"
echo "---"
head -n 15 README.md
echo "..."
echo "---"
echo ""
if [[ "$1" == "--yes" || "$1" == "-y" ]]; then
    REPLY="y"
else
    read -p "Publish to pub.dev? (y/N): " -n 1 -r
fi
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "🚀 Publishing to pub.dev..."
    dart pub publish -f
    
    PUBLISH_STATUS=$?
    
    if [ $PUBLISH_STATUS -eq 0 ]; then
        echo ""
        echo "✅ Successfully published to pub.dev!"
        echo ""
        echo "📝 Step 4: Restore clean README..."
        echo ""
        echo "To restore the clean GitHub README, run:"
        echo "  cp README_BACKUP.md README.md"
        echo ""
        echo "Or keep the pub.dev version if you want to commit it."
        echo ""
        echo "Next steps:"
        echo "1. Verify on pub.dev: https://pub.dev/packages/fletch"
        echo "2. Decide: Keep pub.dev README or restore clean version"
        echo ""
    else
        echo ""
        echo "❌ Publication failed!"
        exit 1
    fi
else
    echo ""
    echo "❌ Publication cancelled"
    exit 0
fi
