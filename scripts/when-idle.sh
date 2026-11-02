#!/bin/zsh
# Waits until nobody has touched the keyboard or mouse for MIN_IDLE seconds (default 90),
# then runs the command given. Gives up after MAX_WAIT seconds (default 3000).
MIN_IDLE=${MIN_IDLE:-90}
MAX_WAIT=${MAX_WAIT:-3000}
waited=0
while true; do
  idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
  (( idle >= MIN_IDLE )) && exec "$@"
  (( waited >= MAX_WAIT )) && { echo "gave up waiting for idle"; exit 2; }
  sleep 15; waited=$((waited + 15))
done
