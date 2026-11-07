#!/bin/zsh
# Runs a list of tb commands while filming the box, logging when each one was sent, so
# camera/sheet.py can cut the video into a labelled contact sheet.
#
#   scripts/film-steps.sh OUTDIR STEPS_FILE [seconds per step]
#
# STEPS_FILE has one step per line: "label | tb arguments", for example
#   game 0 | raw a0 01 00
# Lines starting with # are skipped. Set CAMERA=1 to use another camera.
zmodload zsh/datetime
cd "$(dirname "$0")/.."
out=$1; steps=$2; hold=${3:-4}
mkdir -p $out
: > $out/steps.txt

t0=$EPOCHREALTIME
ffmpeg -hide_banner -loglevel error -f avfoundation -framerate 30 -video_size 1280x720 -pixel_format nv12 \
  -i "${CAMERA:-0}:none" -t 1800 -vf "scale=960:-2" -c:v h264_videotoolbox -b:v 3M -y $out/video.mov &
rec=$!
sleep 3

# Sync mark: black, then white. camera/sheet.py finds the first white frame.
./tb fill 0 0 0 > /dev/null
sleep 1
tf=$EPOCHREALTIME
./tb fill 255 255 255 > /dev/null
print "record_start $t0\nflash_cmd $tf" > $out/sync.txt
sleep 1.5

while IFS='|' read -r label args; do
  [[ -z $label || $label == \#* ]] && continue
  label=${label## }; label=${label%% }
  t=$EPOCHREALTIME
  print "$t|$label|$args" >> $out/steps.txt
  print "== $label"
  ./tb ${=args} | grep -v -- '^->' | grep -v '48 45 4c 4c 4f' | grep -v '^connected'
  sleep $hold
done < $steps

kill -INT $rec
wait $rec
print "film-steps done"
