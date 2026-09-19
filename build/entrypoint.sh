#!/bin/sh
# Named volumes are created root-owned; hand them to the build user.
set -e
for d in /work/output /work/dl; do
    [ -d "$d" ] && chown builder:builder "$d"
done
exec setpriv --reuid=builder --regid=builder --init-groups "$@"
