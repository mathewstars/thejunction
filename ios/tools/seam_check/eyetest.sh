#!/bin/zsh
# Runs the eye unit tests (LanviEyesTests: eyes on their patches, the tap burst) on
# DEVICE under the heavy lock.   ios/tools/seam_check/eyetest.sh DEVICE
dev=$1
root=$(cd "$(dirname $0)/../../.." && pwd)
# (while /tmp/lanvi-phone-priority exists the captain's phone build goes first: no lock)
until [[ ! -e /tmp/lanvi-phone-priority ]] && mkdir /tmp/lanvi-heavy.lock 2>/dev/null; do
  if [[ -n $(find /tmp/lanvi-heavy.lock -maxdepth 0 -mmin +15) ]]; then rmdir /tmp/lanvi-heavy.lock; fi
  sleep 15
done
trap 'xcrun simctl shutdown $dev 2>/dev/null; rm -rf $root/ios/build/dd; rmdir /tmp/lanvi-heavy.lock' EXIT
cd $root/ios
nice xcodebuild test -project Lanvi.xcodeproj -scheme Lanvi -destination "id=$dev" \
  -derivedDataPath build/dd -only-testing:LanviTests/LanviEyesTests 2>&1 | awk '/Test Case|Executed|error:|FAILED|SUCCEEDED/'
