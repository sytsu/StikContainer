#!/bin/sh
# Packages LiveContainer+SideStore.ipa from a local xcodebuild archive.
#
# Same result as .github/build_github.sh, except that the built-in SideStore pieces
# (SideStoreApp.framework, the widget extension, the intent files) are copied from an
# official LiveContainer+SideStore nightly IPA instead of being rebuilt with dylibify/ldid.
#
# usage: package_ipa.sh <archive.xcarchive> <official LiveContainer+SideStore.ipa> <output.ipa>
set -eu

ARCHIVE=$1
NIGHTLY_IPA=$2
OUTPUT=$3

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cp -R "$ARCHIVE/Products/Applications" "$WORK/Payload"
APP="$WORK/Payload/LiveContainer.app"

mkdir "$WORK/nightly"
unzip -q "$NIGHTLY_IPA" -d "$WORK/nightly"
NIGHTLY_APP="$WORK/nightly/Payload/LiveContainer.app"

# SideStore keys, as in .github/build_github.sh
PB=/usr/libexec/PlistBuddy
$PB -c 'Add :ALTAppGroups array' "$APP/Info.plist"
$PB -c 'Add :ALTAppGroups: string group.com.SideStore.SideStore' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:1 dict' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:1:CFBundleURLName string com.kdt.livecontainer.sidestoreurlscheme' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:1:CFBundleURLSchemes array' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string sidestore' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:2 dict' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:2:CFBundleURLName string com.kdt.livecontainer.sidestorebackupurlscheme' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:2:CFBundleURLSchemes array' "$APP/Info.plist"
$PB -c 'Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string sidestore-com.kdt.livecontainer' "$APP/Info.plist"
$PB -c 'Add :INIntentsSupported array' "$APP/Info.plist"
$PB -c 'Add :INIntentsSupported:0 string RefreshAllIntent' "$APP/Info.plist"
$PB -c 'Add :INIntentsSupported:1 string ViewAppIntent' "$APP/Info.plist"
$PB -c 'Add :NSUserActivityTypes array' "$APP/Info.plist"
$PB -c 'Add :NSUserActivityTypes:0 string RefreshAllIntent' "$APP/Info.plist"
$PB -c 'Add :NSUserActivityTypes:1 string ViewAppIntent' "$APP/Info.plist"
$PB -c 'Add :PreferenceSpecifiers:3:Type string PSToggleSwitchSpecifier' "$APP/Settings.bundle/Root.plist"
$PB -c 'Add :PreferenceSpecifiers:3:Title string Open SideStore' "$APP/Settings.bundle/Root.plist"
$PB -c 'Add :PreferenceSpecifiers:3:Key string LCOpenSideStore' "$APP/Settings.bundle/Root.plist"
$PB -c 'Add :PreferenceSpecifiers:3:DefaultValue bool false' "$APP/Settings.bundle/Root.plist"

# Built-in SideStore, already processed in the official nightly
cp -R "$NIGHTLY_APP/Frameworks/SideStoreApp.framework" "$APP/Frameworks/"
cp -R "$NIGHTLY_APP/PlugIns/LiveWidgetExtension.appex" "$APP/PlugIns/"
cp "$NIGHTLY_APP/Intents.intentdefinition" "$NIGHTLY_APP/ViewApp.intentdefinition" "$APP/"
rm -rf "$APP/Metadata.appintents"
cp -R "$NIGHTLY_APP/Metadata.appintents" "$APP/Metadata.appintents"

rm -f "$OUTPUT"
(cd "$WORK" && zip -qr out.ipa Payload -x "._*" -x ".DS_Store" -x "__MACOSX")
mv "$WORK/out.ipa" "$OUTPUT"
echo "wrote $OUTPUT"
