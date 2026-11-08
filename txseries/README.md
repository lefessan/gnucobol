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

GnuCOBOL must be built for the system of TXSeries (UBI 8 / RHEL 8 for the
container image, glibc 2.28). In the container (as root):
`microdnf install gcc make gmp-devel libtool-ltdl diffutils findutils`
(repositories `ubi-8-baseos-rpms`, `ubi-8-appstream-rpms`), then
`configure --prefix=/opt/gnucobol --without-db --without-lmdb
--without-xml2 --without-json --without-curses --disable-nls` and
`make install` in `lib libcob bin cobc config copy`. From a git tree,
the generated parsers of `cobc` (`parser.[ch]`, `ppparse.[ch]`,
`scanner.c`, `pplex.c`) and the man pages need bison, flex and help2man,
which UBI 8 does not have: copy them from a build on another system.

Then:

```sh
make COB_CONFIG=/opt/gnucobol/bin/cob-config
make install PREFIX=/opt/gnucobol
```

This installs `libcobcld.a` (the API, with hidden symbols: `cob_init`,
`cob_resolve` and `cob_resolve_error` have other signatures in libcob)
and `libcobcld.so`, a linker script that brings `libcobcld.a` and
`-lcob`, so that `cicsmkcobcld` works unchanged:

```sh
COBOLCLDIR=/opt/gnucobol cicsmkcobcld -o $CICSPATH/bin
```

## Programs

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
