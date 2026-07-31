#!/bin/zsh
set -euo pipefail

# Required setup:
#   1. Install a "Developer ID Application" certificate in the login keychain.
#   2. Create a notarytool keychain profile, e.g.
#      xcrun notarytool store-credentials "PRReviewAssistantNotary"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application certificate name.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile name.}"

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_dir="${project_dir}/dist/PR Review Assistant.app"
dmg_path="${project_dir}/dist/PR Review Assistant.dmg"

export SIGNING_IDENTITY
"${script_dir}/package-app.sh"

codesign --verify --deep --strict --verbose=2 "$app_dir"
rm -f "$dmg_path"
hdiutil create -volname "PR Review Assistant" -srcfolder "$app_dir" -ov -format UDZO "$dmg_path"
xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature -vv "$dmg_path"

echo "$dmg_path"
