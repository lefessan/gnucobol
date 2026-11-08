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
  translator, option `missing-conf-section: ok`) and the effect of
  `-fnotrunc` (passed by `cicstcl`);
- `-Wno-goto-section -Wno-goto-different-section`: the translator
  writes `GO TO CICS-API-ERROR` (a section) after each command, and
  `GO TO ... DEPENDING ON EIBLABEL` to the labels of `HANDLE CONDITION`;
- the program definition (PD) has `PathName` = the file without its
  extension, for example `/work/prog/prog`;
- `COB_LIBRARY_PATH` (in the environment file of the region) gives the
  directories of the `.cld` files; `CICS_PROGRAM_PATH` and the current
  directory are searched too.

## SQL (PostgreSQL, GixSQL)

The programs with `EXEC SQL` go through the CICS translator, then an SQL
precompiler for GnuCOBOL, then `cobc`. With GixSQL (the fork
`gixsql-superbol`, or 1.0.20b) and PostgreSQL:

```sh
cicstran -lCOBCLD prog.ccp                         # gives prog.cbl
gixpp -e -S -I <gixsql>/share/gixsql/copy -i prog.cbl -o prog.gix.cbl
cobc -m -std=txseries -I <gixsql>/share/gixsql/copy -o prog.cld \
     prog.gix.cbl -L<gixsql>/lib -lgixsql
```

The programs do not connect: TXSeries opens the connection of each
application server (XA, one-phase commit for PostgreSQL) with its switch
load file `postgresql1pc` (from `$CICSPATH/examples/RM_support/PostgreSQL`,
`postgresql1pc.mk`), built for COBOL with `-D_PSQL_COBOLIT` and linked
with `cicsprCOBCLD` and a COBOL module `dbconnect`: use `dbconnect.cob`
of this directory, which provides its entry points (`dbconnect`,
`dbbegin`, `dbcommit`, `dbrollback`, `dbconnreset`, `dbautocommit`) with
GixSQL, compiled with `-fimplicit-init` (see the file). The connection
is the default connection of GixSQL, used by the `EXEC SQL` of the
programs; the updates of a task are committed or rolled back by
TXSeries.

- XA open string: `DB=cicstest@localhost:5432,UID=...,PWD=...` (GixSQL
  accepts this form, with `GIXSQL_DEFAULT_DRIVER=pgsql` in the
  environment of the region if GixSQL has no default driver) or
  `DB=pgsql://localhost:5432/cicstest,...`.
- `dbconnect` turns autocommit off (GixSQL commits each statement by
  default for PostgreSQL), unless the data source or
  `GIXSQL_AUTOCOMMIT` says otherwise.
- `libcobcld` makes the runtime hosted as soon as it is loaded, so that
  `dbconnect`, called at `xa_open` maybe before the initialization of
  the language method, does not install signal handlers in the
  application server.
- GixSQL 1.0.20b comments out the line before `LINKAGE SECTION` or
  `PROCEDURE DIVISION` when it is not blank (the output of `cicstran` has
  a blank line there), and copies unchanged an `EXEC SQL` statement on
  the last line of a section: fixed in `gixsql-superbol`.

Validated without TXSeries (simulation of the switch and of the
language method, PostgreSQL 16): the updates of a task are rolled back
by `xa_rollback`, kept by `xa_commit`.

## Behaviour

- Each `EXEC CICS LINK` level (region 1 to 15 of the language method)
  runs in its own GnuCOBOL context; TXSeries cancels the region before
  each load, so a program starts in its initial state at each LINK.
- `STOP RUN` ends the run unit of the context and returns to TXSeries
  (to the `jmp_buf` that it arms before the call), as `EXEC CICS
  RETURN`, instead of ending the application server.
- A runtime error ends the run unit of the context and calls the error
  procedure that TXSeries installs (`CBL_ERROR_PROC`), with the message:
  it abends the task, whose updates are rolled back, as with COBOL-IT.
- NEWCOPY (and `CICS_DISABLE_COBCLD_CACHE`, which reloads at each load)
  unloads the `.cld` files loaded so far, as soon as no GnuCOBOL context
  uses them: at once in an application server that runs one task at a
  time, else at a next load; a new version of a file must be a new file
  (as written by the linker, or `mv`), not rewritten in place.
- Not yet done: the COBOL-IT debugger.
