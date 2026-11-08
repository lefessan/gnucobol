#!/bin/sh
# Multi-thread scaling of the reentrant runtime: the same work per thread
# (300000 calls of 'work' in its own context), with 1, 2, 4, 8 threads;
# ideally the elapsed time stays constant.
#
# Usage: scale.sh BUILD_DIR [taskset CPU list, e.g. 8-15]
#   (pin the threads to cores of the same kind on hybrid processors)

if [ $# -lt 1 ]; then
	echo "usage: $0 BUILD_DIR [CPUS]" >&2
	exit 2
fi
SRC=$(cd "$(dirname "$0")" && pwd)
B=$1
PIN=
if [ -n "$2" ]; then PIN="taskset -c $2"; fi

"$B/pre-inst-env" cobc -x -O2 "$SRC/scale.c" -o scale -lpthread &&
"$B/pre-inst-env" cobc -m -O2 "$SRC/work.cob" &&
"$B/pre-inst-env" cobc -m -O2 "$SRC/wsub.cob" || exit 1
for n in 1 2 4 8; do
	/usr/bin/time -f "threads=$n elapsed=%e user=%U" \
		env COB_LIBRARY_PATH=. $PIN "$B/pre-inst-env" ./scale $n
done
