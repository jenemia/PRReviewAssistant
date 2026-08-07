#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_dir="${project_dir}/dist/PR Review Assistant.app"
signing_identity="${SIGNING_IDENTITY:--}"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${project_dir}/Resources/Info.plist")"
archive_path="${project_dir}/dist/PR Review Assistant-v${app_version}.zip"

cd "$project_dir"
swift build -c release --product PRReviewAssistant
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/release/PRReviewAssistant" "$app_dir/Contents/MacOS/PRReviewAssistant"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp "Sources/PRReviewAssistant/Resources/PetMascotPRWeapons.png" "$app_dir/Contents/Resources/PetMascotPRWeapons.png"
if [[ "$signing_identity" == "-" ]]; then
  codesign --force --sign - --timestamp=none "$app_dir"
else
  codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_dir"
fi
rm -f "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive_path"
echo "$app_dir"
echo "$archive_path"
