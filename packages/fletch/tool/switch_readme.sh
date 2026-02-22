#!/bin/bash
# README Switch Script
# Switches between GitHub (clean) and pub.dev (with Rob's credit) versions
# using persistent comment markers to avoid overwriting other changes.

set -e

NOTICE_FILE=".pubdev/PACKAGE_HISTORY_NOTICE.md"
README="README.md"
START_MARKER="<!-- ROB_NOTICE_START -->"
END_MARKER="<!-- ROB_NOTICE_END -->"

# Detect OS for sed inline syntax
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS requires an empty string argument for -i
    SED_INPLACE=(-i '')
else
    # GNU sed (Linux/CI) expects no argument for -i
    SED_INPLACE=(-i)
fi

# Check dependencies
if [ ! -f "$README" ]; then
    echo "❌ Error: $README not found. Run from package root."
    exit 1
fi

if ! grep -q "$START_MARKER" "$README"; then
    echo "❌ Error: Start marker '$START_MARKER' not found in $README"
    exit 1
fi

# Detect Mode
if [ "$1" == "--pubdev" ]; then
    echo "📝 Switching to pub.dev version (Injecting Notice)..."

    # 1. Clear existing content between markers
    sed "${SED_INPLACE[@]}" "/$START_MARKER/,/$END_MARKER/{ /${START_MARKER}/!{ /${END_MARKER}/!d; }; }" "$README"

    # 2. Inject Notice File after Start Marker
    if [ -f "$NOTICE_FILE" ]; then
        sed "${SED_INPLACE[@]}" "/$START_MARKER/r $NOTICE_FILE" "$README"
        echo "   ✅ Injected Rob's notice."
    else
        echo "   ❌ Error: Notice file '$NOTICE_FILE' not found!"
        exit 1
    fi

elif [ "$1" == "--github" ]; then
    echo "📝 Switching to GitHub version (Cleaning Notice)..."

    # 1. Clear content between markers (leaving just the markers)
    sed "${SED_INPLACE[@]}" "/$START_MARKER/,/$END_MARKER/{ /${START_MARKER}/!{ /${END_MARKER}/!d; }; }" "$README"
    echo "   ✅ Removed notice content."

else
    echo "Usage: $0 [--pubdev|--github]"
    exit 1
fi

echo "✅ Done."
