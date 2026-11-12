#!/usr/bin/env bash
set -euo pipefail

app=build/macos/Build/Products/Release/jhentai.app
plist="$app/Contents/Info.plist"
binary=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")
version=$(awk '/^version:/ {print $2; exit}' pubspec.yaml)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]]

work=$(mktemp -d)
mkdir -p "$work/staging" "$work/mount" build/macos
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$work/mount" || return
  fi
  rm -rf "$work"
}
trap cleanup EXIT

ditto "$app" "$work/staging/JHenTai.app"
ln -s /Applications "$work/staging/Applications"
dmg="build/macos/JHenTai-$version-Hardened-macOS-arm64.dmg"
hdiutil create -volname 'JHenTai Hardened' -srcfolder "$work/staging" \
  -format UDZO -fs HFS+ -ov "$dmg"
hdiutil verify "$dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$work/mount" "$dmg"
mounted=true

packaged_app="$work/mount/JHenTai.app"
test "$(lipo -archs "$packaged_app/Contents/MacOS/$binary")" = arm64
codesign --verify --deep --strict --verbose=2 "$packaged_app"
codesign -d --entitlements - --xml "$packaged_app" | \
  plutil -convert xml1 -o "$work/entitlements.plist" -
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$work/entitlements.plist")" = true

while IFS= read -r -d '' file_path; do
  if [[ "$(file -b "$file_path")" == *Mach-O* ]]; then
    archs=$(lipo -archs "$file_path")
    if ! grep -Eq '(^|[[:space:]])arm64([[:space:]]|$)' <<< "$archs"; then
      printf '::error::Missing arm64 slice in %s (%s)\n' "$file_path" "$archs"
      exit 1
    fi
  fi
done < <(find "$packaged_app" -type f -print0)
echo "Verified arm64 slices and the signature of the packaged app"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "package=$dmg" >> "$GITHUB_OUTPUT"
fi
