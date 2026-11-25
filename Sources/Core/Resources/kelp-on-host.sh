#!/bin/sh
# Kelp's kelp on this host: it knows only `kelp browser`, which drives a page in Kelp on the user's Mac.
s=${KELP_SOCKET:-}
if [ "${1:-}" != browser ]; then
  echo "kelp ${1:-}: on this host Kelp has only kelp browser; the rest of kelp runs on the Mac." >&2
  exit 2
fi
shift
gone() {
  echo "Kelp isn't connected to this host (the Mac sleeps or the link dropped)." >&2
  echo "The page is kept as it was: try again when Kelp is back." >&2
  exit 1
}
[ -S "$s" ] || gone
last=
for w in "$@"; do last=$w; done
send() {
  if command -v curl >/dev/null 2>&1; then
    curl -sS --no-buffer --unix-socket "$s" -H 'Expect:' --data-binary @- http://kelp/browser 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket, sys
c = socket.socket(socket.AF_UNIX); c.connect(sys.argv[1]); b = sys.stdin.buffer.read()
c.sendall(b"POST /browser HTTP/1.0\r\nContent-Length: %d\r\n\r\n" % len(b) + b)
for line in c.makefile("rb"): sys.stdout.buffer.write(line); sys.stdout.flush()' "$s" 2>/dev/null
  else
    echo 'e kelp browser on this host needs curl or python3.'; echo 'x 1'
  fi
}
{
  printf '%s\0%s\0%s\0' "$s" "$PWD" "$#"
  for w in "$@"; do printf '%s\0' "$w"; done
  if { [ $# -eq 0 ] || [ "$last" = - ]; } && [ ! -t 0 ]; then cat; fi
} | send | awk 'BEGIN { c = 255 }
  /^o / { print substr($0, 3); fflush(); next }
  /^e / { print substr($0, 3) > "/dev/stderr"; next }
  /^x [0-9]/ { c = substr($0, 3) + 0 }
  END { exit c }'
r=$?
[ "$r" -eq 255 ] && gone
exit "$r"

