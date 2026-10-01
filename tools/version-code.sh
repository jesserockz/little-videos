#!/usr/bin/env bash
# Print the Android versionCode for a MAJOR.MINOR.PATCH version.
#
#   tools/version-code.sh 1.2.3    # prints 10203
#
# code = major*10000 + minor*100 + patch. Minor or patch of 100+ is rejected
# since it would collide with another version. Also used by fdroid-add-build.sh and check-metadata.sh.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <MAJOR.MINOR.PATCH>" >&2
  exit 2
fi
VERSION="$1"

if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "::error::version '$VERSION' is not MAJOR.MINOR.PATCH" >&2
  exit 1
fi

# 10# avoids octal parsing of leading zeros.
IFS=. read -r MAJOR MINOR PATCH <<< "$VERSION"
if [ "$((10#$MINOR))" -ge 100 ] || [ "$((10#$PATCH))" -ge 100 ]; then
  echo "::error::version '$VERSION' has a minor or patch of 100 or more, which would collide with another versionCode" >&2
  exit 1
fi
echo $(( 10#$MAJOR * 10000 + 10#$MINOR * 100 + 10#$PATCH ))
