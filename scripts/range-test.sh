#!/bin/zsh
# Sends effect and visualiser numbers past the known range and reads the stored value
# back, to see where the box clamps or wraps. Usage: ./range-test.sh [logfile]
cd "$(dirname "$0")/.."
log=${1:-range-test.log}
: > $log

for n in 6 7 8 9 10 12 15 20 40 255; do
  ./tb effect $n > /dev/null
  print "== effect $n" >> $log; ./tb getview | grep ' 46 55 ' >> $log
done
for n in 3 4 5 7 8 9 10 12 15 20 255; do
  ./tb viz $n > /dev/null
  print "== viz $n" >> $log; ./tb getview | grep ' 46 55 ' >> $log
done
./tb clock 24 ffffff > /dev/null
print "done" >> $log
