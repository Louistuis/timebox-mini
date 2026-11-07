#!/bin/zsh
# Runs each newly found command on the TimeBox-mini with a numbered label.
# Watch the display and note which numbers look wrong. Replies ending in 55 mean the
# box accepted the command; AA means it rejected it.
cd "$(dirname "$0")/.."
pause=${PAUSE:-6}
n=0

step() {
  n=$((n + 1))
  print -P "\n%B== $n: $1%b"
  shift
  ./tb "$@" | grep -v -- '^->' | grep -v '^connected' | grep -v '48 45 4c 4c 4f'
  sleep $pause
}

step "brightness 10% (dim)"              brightness 10
step "brightness 100% (bright)"          brightness 100
step "clock, green digits"               clock 24 00ff00
step "clock, magenta digits (alt form)"  view 00 01 ff 00 ff ff
step "temperature, cyan"                 temp c 00ffff
step "lamp, orange, full"                light ff8000 100
step "lamp, orange, 20%"                 light ff8000 20
step "screen off"                        off
step "effect 0"                          effect 0
step "effect 1"                          effect 1
step "effect 2"                          effect 2
step "effect 3"                          effect 3
step "visualiser 0"                      viz 0
step "visualiser 1"                      viz 1
step "custom image view"                 view 05
step "stopwatch"                         stopwatch
step "scoreboard red 3, blue 7"          score 3 7
step "ask which view is showing"         getview
step "animation, square going round"     anim 2
step "set time, then white clock"        time
./tb clock 24 ffffff > /dev/null
print "\ndone"
