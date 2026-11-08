# GnuCOBOL programs in IBM TXSeries

`libcobcld` lets IBM TXSeries (11.1, Linux x86-64) run programs compiled
by GnuCOBOL through its COBOL language method for CobolCloud (`COBCLD`):
it provides the runtime API that this method expects (the API of
COBOL-IT / CobolCloud, see `TXSERIES-COBOLIT-API.md` at the top of the
sources) on top of libcob, which runs each LINK level of each task in its
own context.

**Status: experimental.** Validated with a simulation of the language
method (test "TXSeries CobolCloud runtime API (simulation)" of
`run_reentrant.at`); `cicsmkcobcld` builds `cicsprCOBCLD` with it in the
TXSeries 11.1 container. Not yet run in a region: the evaluation build
of TXSeries 11.1 (s111-L241206) has expired.

## Build and install

### Container image

`Dockerfile` builds an image of TXSeries with GnuCOBOL from the image of
TXSeries loaded from IBM and a distribution of GnuCOBOL (`make dist`,
which contains the generated parsers and the documentation):

```sh
make dist                                  # in the build tree of GnuCOBOL
mkdir ctx && cp txseries/Dockerfile gnucobol-*.tar.gz ctx/
docker build --build-arg GNUCOBOL_DIST=gnucobol-4.0-early-dev.tar.gz \
    -t txseries-gnucobol ctx
```

The image has GnuCOBOL in `/opt/gnucobol` (in `PATH`), `libcobcld`,
the method `cicsprCOBCLD` built with it, and `CICS_COBCLD_CCFLAGS` set
for `cicstcl` (see below).

### By hand

GnuCOBOL must be built for the system of TXSeries (UBI 8 / RHEL 8 for
the container image, glibc 2.28), from a distribution (a git tree needs
bison, flex, help2man and makeinfo, which UBI 8 does not have): as root,
`microdnf install gcc make gmp-devel diffutils findutils tar gzip`
(repositories `ubi-8-baseos-rpms`, `ubi-8-appstream-rpms`), then
`configure --prefix=/opt/gnucobol --without-db --without-lmdb
--without-xml2 --without-json --without-curses --disable-nls`,
`make install`, then in `txseries/`:

```sh
make COB_CONFIG=/opt/gnucobol/bin/cob-config
make install COB_CONFIG=/opt/gnucobol/bin/cob-config
```

This installs `libcobcld.a` (the API, with hidden symbols: `cob_init`,
`cob_resolve` and `cob_resolve_error` have other signatures in libcob)
and `libcobcld.so`, a linker script that brings `libcobcld.a` and
libcob, so that `cicsmkcobcld` works unchanged:

```sh
COBOLCLDIR=/opt/gnucobol cicsmkcobcld -o $CICSPATH/bin
```

## Programs

`cicstcl -lCOBCLD` translates the program (`cicstran`) then calls the
`cobc` of the `PATH` with `-fthread-safe -fnotrunc -I $CICSPATH/include`
and `CICS_COBCLD_CCFLAGS`; the IVP of TXSeries builds unchanged
(`make COBCLD` in a copy of `$CICSPATH/samples/ivp`, which also builds
its BMS maps with `cicsmap`). By hand:

```sh
CICS_COBCLD_CCFLAGS="-std=txseries -Wno-goto-section -Wno-goto-different-section" \
    cicstcl -lCOBCLD prog.ccp                              # gives prog.cld
```

- `-std=txseries` (`config/txseries.conf`): the default dialect, plus
  `SPECIAL-NAMES` without `CONFIGURATION SECTION` (written by the
  translator) and the effect of `-fnotrunc` (passed by `cicstcl`);
- `-Wno-goto-section -Wno-goto-different-section`: the translator
  writes `GO TO CICS-API-ERROR` (a section) after each command, and
  `GO TO ... DEPENDING ON EIBLABEL` to the labels of `HANDLE CONDITION`;
- the program definition (PD) has `PathName` = the file without its
  extension, for example `/work/prog/prog`;
- `COB_LIBRARY_PATH` (in the environment file of the region) gives the
  directories of the `.cld` files; `CICS_PROGRAM_PATH` and the current
  directory are searched too.

## Behaviour

- Each `EXEC CICS LINK` level (region 1 to 15 of the language method)
  runs in its own GnuCOBOL context; TXSeries cancels the region before
  each load, so a program starts in its initial state at each LINK.
- `STOP RUN` and the fatal runtime errors end the run unit of the
  context and return to TXSeries (to the `jmp_buf` that it arms before
  the call), instead of ending the application server.
- Not yet done: reload of a module on NEWCOPY (the module files stay
  loaded), the COBOL-IT debugger, abend of the task on a runtime error
  (the error and exit procedures of TXSeries are recorded but not
  called).
