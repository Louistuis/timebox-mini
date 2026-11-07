#!/bin/zsh
# Films the box with the Mac's camera while `tb scan` runs, so every command's visible effect
# can be found in the video. A white flash before the scan lines the video up with the
# scan's timestamps (same Unix clock).
#
#   scripts/film-scan.sh OUTDIR [scan options...]     e.g. scripts/film-scan.sh runs/empty --from 0 --to ff
#
# Writes OUTDIR/scan.jsonl, OUTDIR/scan.mov (960 px wide) and OUTDIR/sync.txt.
zmodload zsh/datetime
cd "$(dirname "$0")/.."
out=$1; shift
mkdir -p $out

t0=$EPOCHREALTIME
ffmpeg -hide_banner -loglevel error -f avfoundation -framerate 30 -video_size 1280x720 -pixel_format nv12 \
  -i "${CAMERA:-0}:none" -t 900 -vf "scale=960:-2" -c:v h264_videotoolbox -b:v 3M -y $out/scan.mov &
rec=$!
sleep 3

./tb fill 0 0 0 > /dev/null
sleep 1
tf=$EPOCHREALTIME
./tb fill 255 255 255 > /dev/null
print "record_start $t0\nflash_cmd $tf" > $out/sync.txt
sleep 1.5
./tb fill 0 0 0 > /dev/null
sleep 1

./tb scan "$@" | tee $out/scan.jsonl
sleep 2
kill -INT $rec
wait $rec
./tb clock 24 ffffff > /dev/null
./tb brightness 100 > /dev/null
print "film-scan done"
