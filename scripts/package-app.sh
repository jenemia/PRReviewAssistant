#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_dir="${project_dir}/dist/PR Review Assistant.app"

cd "$project_dir"
swift build -c release --product PRReviewAssistant
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/release/PRReviewAssistant" "$app_dir/Contents/MacOS/PRReviewAssistant"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp -R ".build/release/PRReviewAssistant_PRReviewAssistant.bundle" "$app_dir/Contents/Resources/"
codesign --force --sign - --timestamp=none "$app_dir"
echo "$app_dir"
