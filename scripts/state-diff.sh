#!/bin/zsh
# Changes one setting at a time and reads the box's state (0x46) after each, so the
# bytes that change can be matched to settings. Usage: ./state-diff.sh [logfile]
cd "$(dirname "$0")/.."
log=${1:-state-diff.log}
: > $log

read_state() {
  print "== $1" >> $log
  ./tb getview | grep ' 46 55 ' >> $log
}

read_state "baseline"
./tb brightness 37 > /dev/null;                   read_state "brightness 37"
./tb view 00 00 11 22 33 > /dev/null;             read_state "clock 12h colour 112233"
./tb view 00 01 44 55 66 77 > /dev/null;          read_state "clock 24h colour 445566 extra 77"
./tb view 01 01 88 99 aa 00 > /dev/null;          read_state "temp F colour 8899aa"
./tb light bbccdd 42 > /dev/null;                 read_state "lamp bbccdd 42"
./tb effect 5 > /dev/null;                        read_state "effect 5"
./tb viz 6 102030 405060 > /dev/null;             read_state "viz 6 fg 102030 bg 405060"
./tb view 05 > /dev/null;                         read_state "view 5"
./tb stopwatch > /dev/null;                       read_state "stopwatch"
./tb score 9 11 > /dev/null;                      read_state "score 9 11"
./tb clock 24 ffffff > /dev/null
./tb brightness 100 > /dev/null;                  read_state "restored: white 24h clock, brightness 100"
print "done" >> $log
