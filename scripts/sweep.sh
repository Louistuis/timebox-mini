#!/bin/zsh
# Shows effects 0-15, then visualisers 0-15, 4 seconds each, with the number in the
# terminal. The box stores any number, so only watching tells how many really exist.
cd "$(dirname "$0")/.."
for n in {0..15}; do print -P "%Beffect $n%b"; ./tb effect $n > /dev/null; sleep 4; done
for n in {0..15}; do print -P "%Bvisualiser $n%b"; ./tb viz $n > /dev/null; sleep 4; done
./tb effect 0 > /dev/null; ./tb viz 0 > /dev/null; ./tb clock 24 ffffff > /dev/null
print done
