#!/bin/zsh
# Renders the fox at the 12 extreme head turns and through head wobbles (frozen
# frames on the puppet screen) and saves one screenshot per frame.
#   ios/tools/seam_check/capture.sh DEVICE OUTDIR
# Needs a built app installed on DEVICE (booted). Hold the heavy lock around it.
dev=$1; out=$2
mkdir -p $out
shot() {   # name freeze (retaken while the launch cover still washes the screen white)
  for try in 1 2 3; do
    xcrun simctl launch --terminate-running-process $dev app.lanvi.Lanvi \
      -screen puppet -puppetFreeze "$2" -offline -senseScreen off >/dev/null
    sleep 3.5
    xcrun simctl io $dev screenshot --type=png $out/$1.png >/dev/null 2>&1
    python3 -c "from PIL import Image,ImageStat;import sys;sys.exit(ImageStat.Stat(Image.open('$out/$1.png').convert('L')).mean[0]>172)" && return
  done
}
shot rest rest:0
for i in {0..11}; do
  a=$(( i * 30 ))
  xy=$(python3 -c "import math;a=math.radians($a);print(f'{0.5+20*math.cos(a):.3f}:{0.35-20*math.sin(a):.3f}')")
  shot turn-$(printf %03d $a) look:$xy
done
for f in happy:0.2 happy:0.35 happy:0.5 happy:0.75 greeting:0.6 greeting:0.97 surprised:0.67 proud:0.93; do
  shot wobble-${f/:/-} $f
done
xcrun simctl terminate $dev app.lanvi.Lanvi 2>/dev/null
