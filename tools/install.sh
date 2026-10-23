#!/bin/zsh
# Build SnapLite (macOS), sign it, install it to /Applications and launch it.
#
#   tools/install.sh [--no-build] [--local-only]
#
# Signing: macOS ties the Screen Recording permission to the app's signature. With a stable identity
# (SNAPLITE_SIGN_IDENTITY, or a SHA-1 in ~/.config/snaplite/signing-identity, optionally kept in the
# keychain ~/Library/Keychains/snaplite-signing.keychain-db) rebuilds keep the permission; without one
# the app is signed ad hoc and macOS asks for the permission again after each rebuild.
#
# Second Mac: set SNAPLITE_PUSH_HOST=user@host (or put it in ~/.config/snaplite/push-host) to also
# copy the signed app there over SSH.
set -euo pipefail
cd "${0:A:h}/.."
export PATH=/opt/homebrew/bin:$HOME/.gem/bin:$PATH
[[ -d $HOME/.gem ]] && export GEM_HOME=$HOME/.gem   # CocoaPods installed as a user gem
app=build/macos/Build/Products/Release/SnapLite.app
config=~/.config/snaplite

[[ " $* " == *" --no-build "* ]] || flutter build macos --release

identity=${SNAPLITE_SIGN_IDENTITY:-$(cat $config/signing-identity 2>/dev/null || true)}
keychain=~/Library/Keychains/snaplite-signing.keychain-db
if [[ -n $identity ]]; then
  keychain_args=()
  if [[ -e $keychain ]]; then
    # The keychain's password lives in the login keychain; it is read here and never stored
    security unlock-keychain -p "$(security find-generic-password -a "$USER" -s snaplite-signing-keychain -w)" "$keychain"
    keychain_args=(--keychain "$keychain")
  fi
  codesign --force --deep "${keychain_args[@]}" --sign "$identity" "$app"
  codesign --force "${keychain_args[@]}" --sign "$identity" --identifier com.mm.SnapLite \
    --entitlements macos/Runner/Release.entitlements "$app"
else
  echo "note: no signing identity; signing ad hoc (Screen Recording permission resets on each rebuild)" >&2
  codesign --force --deep --sign - --entitlements macos/Runner/Release.entitlements "$app"
fi
codesign --verify --deep --strict "$app"

pkill -x SnapLite || true
sleep 1
rm -rf /Applications/SnapLite.app
cp -R "$app" /Applications/
open /Applications/SnapLite.app
echo "installed: $(defaults read /Applications/SnapLite.app/Contents/Info CFBundleShortVersionString)"

host=${SNAPLITE_PUSH_HOST:-$(cat $config/push-host 2>/dev/null || true)}
[[ " $* " == *" --local-only "* || -z $host ]] && exit 0
cd /Applications && tar -cf - SnapLite.app | ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" \
  'pkill -x SnapLite; sleep 1; rm -rf /Applications/SnapLite.app && cd /Applications && tar -xf - &&
   codesign --verify --deep --strict SnapLite.app && open SnapLite.app &&
   echo "installed on '"$host"': $(defaults read /Applications/SnapLite.app/Contents/Info CFBundleShortVersionString)"'
