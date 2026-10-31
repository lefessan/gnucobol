#!/bin/sh
#
# list-mutable-globals.sh
#
# List the mutable global data (static or exported variables, including
# function-local statics and thread-local variables) defined in object
# files, as tab-separated lines:
#
#   object  section  scope  size  symbol
#
# where scope is "l" (static) or "g" (exported) and section is one of
# .bss, .data*, .tbss, .tdata.  Read-only data (.rodata*, and .data.rel.ro*
# which is read-only after relocation) is ignored.
#
# Usage: list-mutable-globals.sh file.o...
#        (typically: libcob/.libs/*.o from the build directory)
#
# Part of the reentrant runtime work: the target is an empty output,
# except for a short whitelist (see TXSERIES-PLAN.md).

if test $# -eq 0; then
	echo "usage: $0 file.o..." >&2
	exit 2
fi

OBJDUMP=${OBJDUMP:-objdump}

for obj in "$@"; do
	"$OBJDUMP" -t "$obj" | awk -v obj="$(basename "$obj")" '
		# portable (no gawk strtonum)
		function hex(s,   i, n) {
			n = 0
			for (i = 1; i <= length(s); i++)
				n = n * 16 + index("0123456789abcdef", tolower(substr(s, i, 1))) - 1
			return n
		}
		# objdump -t: addr flags... section size name
		NF >= 5 && $(NF-2) ~ /^\.(t?bss|t?data)/ && $(NF-2) !~ /^\.data\.rel\.ro/ \
		 && $NF !~ /^\./ {
			sect = $(NF-2); size = $(NF-1); name = $NF
			scope = (substr($0, 18, 1) == "g") ? "g" : "l"
			sub(/^\.data\..*/, ".data", sect)
			printf "%s\t%s\t%s\t%d\t%s\n", obj, sect, scope, hex(size), name
		}'
done
