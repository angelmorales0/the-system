#!/bin/bash
# Lints every app extension's Info.plist against one table of required values.
# To add an extension: add its folder to EXTENSIONS below. A target missing here fails the lint.
set -u
cd "$(dirname "$0")/.."
PBX=system.xcodeproj/project.pbxproj
PB=/usr/libexec/PlistBuddy

# folder|NSExtensionPointIdentifier|NSExtensionPrincipalClass (empty when the extension has none)
EXTENSIONS='
PenaltyActivity|com.apple.widgetkit-extension|
PenaltyMonitor|com.apple.deviceactivity.monitor-extension|$(PRODUCT_MODULE_NAME).PenaltyDeviceActivityMonitor
PenaltyShieldAction|com.apple.ManagedSettings.shield-action-service|$(PRODUCT_MODULE_NAME).PenaltyShieldAction
PenaltyShieldConfig|com.apple.ManagedSettingsUI.shield-configuration-service|$(PRODUCT_MODULE_NAME).PenaltyShieldConfiguration
'

errors=0
err() { echo "ERROR: $*"; errors=$((errors + 1)); }

targets=$(awk '/^\t\t\tname = /{n=$3; sub(/;$/,"",n)} /productType = "com.apple.product-type.app-extension"/{print n}' "$PBX")
tabled=$(echo "$EXTENSIONS" | awk -F'|' 'NF{print $1}')

for t in $targets; do
  echo "$tabled" | grep -qx "$t" || err "$PBX: extension target $t has no entry in EXTENSIONS in scripts/lint-extensions.sh; add \"$t|<NSExtensionPointIdentifier>|<principal class>\" to the table"
done

for f in $(git ls-files '*Info.plist'); do
  d=${f%%/*}
  $PB -c 'Print NSExtension' "$f" >/dev/null 2>&1 || continue
  echo "$tabled" | grep -qx "$d" || err "$f: has an NSExtension but folder $d has no entry in EXTENSIONS in scripts/lint-extensions.sh; add it"
done

while IFS='|' read -r dir point class; do
  [ -n "$dir" ] || continue
  plist="$dir/Info.plist"
  echo "$targets" | grep -qx "$dir" || err "$dir: in EXTENSIONS but $PBX has no app-extension target named $dir; remove the table row or restore the target"
  if [ ! -f "$plist" ]; then
    err "$plist: file is missing; create it with NSExtension > NSExtensionPointIdentifier \"$point\""
    continue
  fi
  got=$($PB -c 'Print :NSExtension:NSExtensionPointIdentifier' "$plist" 2>/dev/null || echo "")
  [ "$got" = "$point" ] || err "$plist: NSExtensionPointIdentifier is \"$got\"; use \"$point\""
  gotclass=$($PB -c 'Print :NSExtension:NSExtensionPrincipalClass' "$plist" 2>/dev/null || echo "")
  [ "$gotclass" = "$class" ] || err "$plist: NSExtensionPrincipalClass is \"$gotclass\"; use \"$class\""
done <<< "$EXTENSIONS"

gen=$(awk -v pbx="$PBX" '
  /buildSettings = \{/ {inb=1; gen=0; file=""; next}
  inb && /GENERATE_INFOPLIST_FILE = YES;/ {gen=1}
  inb && /INFOPLIST_FILE = / && !/MyApp-Info/ {file=$3; sub(/;$/,"",file)}
  inb && /^\t\t\t\};/ {inb=0; if (file != "" && !gen) print "ERROR: " pbx ": the build settings for " file " lack GENERATE_INFOPLIST_FILE = YES; set it, or the extension has no CFBundleIdentifier and embedding fails"}
' "$PBX" | sort -u)
if [ -n "$gen" ]; then
  echo "$gen"
  errors=$((errors + $(echo "$gen" | wc -l)))
fi

if [ "$errors" -gt 0 ]; then
  echo "LINT FAILED: $errors problem(s)"
  exit 1
fi
echo "LINT PASSED: extension Info.plist files match the table"
