#!/bin/zsh
# Takes the heavy lock, builds the app, boots DEVICE, captures every frame into OUTDIR,
# shuts down, releases the lock.   ios/tools/seam_check/run.sh DEVICE OUTDIR
dev=$1; out=$2
root=$(cd "$(dirname $0)/../../.." && pwd)
until mkdir /tmp/lanvi-heavy.lock 2>/dev/null; do
  if [[ -n $(find /tmp/lanvi-heavy.lock -maxdepth 0 -mmin +15) ]]; then rmdir /tmp/lanvi-heavy.lock; fi
  sleep 15
done
trap 'xcrun simctl shutdown $dev 2>/dev/null; rmdir /tmp/lanvi-heavy.lock' EXIT
cd $root/ios
nice xcodebuild -project Lanvi.xcodeproj -scheme Lanvi -destination "id=$dev" \
  -derivedDataPath build/dd build -quiet 2>&1 | tail -5
app=$(ls -d build/dd/Build/Products/Debug-iphonesimulator/Lanvi.app)
xcrun simctl boot $dev 2>/dev/null; xcrun simctl bootstatus $dev >/dev/null
xcrun simctl install $dev $app
$root/ios/tools/seam_check/capture.sh $dev $out
echo "captured $(ls $out | wc -l) frames"
