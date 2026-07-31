#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_dir="${project_dir}/dist/PR Review Assistant.app"
signing_identity="${SIGNING_IDENTITY:--}"

cd "$project_dir"
swift build -c release --product PRReviewAssistant
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/release/PRReviewAssistant" "$app_dir/Contents/MacOS/PRReviewAssistant"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp "Sources/PRReviewAssistant/Resources/PetMascot.png" "$app_dir/Contents/Resources/PetMascot.png"
if [[ "$signing_identity" == "-" ]]; then
  codesign --force --sign - --timestamp=none "$app_dir"
else
  codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_dir"
fi
rm -f "$project_dir/dist/PR Review Assistant.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$project_dir/dist/PR Review Assistant.zip"
echo "$app_dir"
