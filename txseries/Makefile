# libcobcld: CobolCloud runtime API for IBM TXSeries, on libcob
#
#   make COB_CONFIG=/opt/gnucobol/bin/cob-config
#   make install PREFIX=/opt/gnucobol
#
# then: COBOLCLDIR=/opt/gnucobol cicsmkcobcld -o $CICSPATH/bin

COB_CONFIG ?= cob-config
PREFIX     ?= $(shell $(COB_CONFIG) --prefix)
CC         ?= gcc
CFLAGS     ?= -O2 -g
COB_CFLAGS := $(shell $(COB_CONFIG) --cflags)

all: libcobcld.a libcobcld.so

cobcld.o: cobcld.c
	$(CC) $(CFLAGS) -fPIC -fvisibility=hidden -Wall -Wextra \
	  $(COB_CFLAGS) -c -o $@ $<

libcobcld.a: cobcld.o
	rm -f $@
	ar rcs $@ $^

# linker script: -lcobcld brings the archive and libcob
libcobcld.so: Makefile
	echo "GROUP ( $(PREFIX)/lib/libcobcld.a $(PREFIX)/lib/libcob.so ) INPUT ( -ldl -lpthread )" > $@

install: all
	install -d $(DESTDIR)$(PREFIX)/lib
	install -m 644 libcobcld.a libcobcld.so $(DESTDIR)$(PREFIX)/lib/

clean:
	rm -f cobcld.o libcobcld.a libcobcld.so

.PHONY: all install clean
