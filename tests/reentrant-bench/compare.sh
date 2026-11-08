#!/bin/sh
# Compare the run time of the benchmarks between two builds of GnuCOBOL
# (best user+sys time of N runs, the two builds alternate).
#
# Usage: compare.sh BUILD_DIR_A BUILD_DIR_B [N]
#   BUILD_DIR_x: build directories (with pre-inst-env), configured with
#   CFLAGS=-O2 and without --enable-debug for meaningful numbers
#
# Work files are written in the current directory.

if [ $# -lt 2 ]; then
	echo "usage: $0 BUILD_DIR_A BUILD_DIR_B [N]" >&2
	exit 2
fi
SRC=$(cd "$(dirname "$0")" && pwd)
N=${3:-5}

for v in A B; do
	if [ $v = A ]; then B=$1; else B=$2; fi
	mkdir -p $v
	( cd $v
	  for p in arith strs calls seqf idxf; do
		"$B/pre-inst-env" cobc -x -O2 "$SRC/$p.cob" -o $p || exit 1
	  done
	  "$B/pre-inst-env" cobc -m -O2 "$SRC/csub.cob" -o csub.so ) || exit 1
done

for p in arith strs calls seqf idxf; do
	bestA= ; bestB=
	i=0
	while [ $i -lt $N ]; do
		for v in A B; do
			if [ $v = A ]; then B=$1; else B=$2; fi
			t=$( cd $v && rm -rf seq.txt idx.dat* __db.* &&
			     /usr/bin/time -f "%U %S" env COB_LIBRARY_PATH=. \
				"$B/pre-inst-env" ./$p 2>&1 >/dev/null | tail -1 |
			     awk '{print $1+$2}' )
			eval "best=\$best$v"
			if [ -z "$best" ] || [ $(echo "$t < $best" | bc) = 1 ]; then
				eval "best$v=$t"
			fi
		done
		i=$((i+1))
	done
	printf "%-6s A=%-6s B=%-6s B/A=%s\n" $p $bestA $bestB \
		$(echo "scale=3; $bestB/$bestA" | bc)
done
