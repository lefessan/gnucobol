      *> Copyright (C) 2026 Free Software Foundation, Inc.
      *>
      *> This file is part of GnuCOBOL.
      *>
      *> The GnuCOBOL runtime library is free software: you can
      *> redistribute it and/or modify it under the terms of the GNU
      *> Lesser General Public License as published by the Free Software
      *> Foundation, either version 3 of the License, or (at your
      *> option) any later version.
      *>
      *> GnuCOBOL is distributed in the hope that it will be useful,
      *> but WITHOUT ANY WARRANTY; without even the implied warranty of
      *> MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
      *> GNU Lesser General Public License for more details.
      *>
      *> You should have received a copy of the GNU Lesser General
      *> Public License along with GnuCOBOL.  If not, see
      *> <https://www.gnu.org/licenses/>.

      *> Connection of the programs of a TXSeries region to PostgreSQL,
      *> for the switch load file of TXSeries for PostgreSQL
      *> (postgresql1pc, built with -D_PSQL_COBOLIT), with GixSQL as
      *> SQL precompiler and runtime: the switch calls these entry
      *> points at xa_open, xa_start, xa_commit, xa_rollback and
      *> xa_close; the connection is the default connection of GixSQL,
      *> used by the EXEC SQL of the programs of the application server.
      *>
      *>   gixpp -e -S -I <gixsql>/share/gixsql/copy -i dbconnect.cob \
      *>         -o dbconnect.cbl
      *>   cobc -m -fimplicit-init -I <gixsql>/share/gixsql/copy \
      *>         -o libdbconnect.so dbconnect.cbl -L<gixsql>/lib -lgixsql
      *>
      *> -fimplicit-init: the switch may call dbconnect before the
      *> language method initializes the runtime (hosted, see cobcld.c).
      *>
      *> The entry points return the SQLCODE (0: success).

       IDENTIFICATION   DIVISION.
       PROGRAM-ID.      dbconnect.

       DATA             DIVISION.
       WORKING-STORAGE  SECTION.
           EXEC SQL BEGIN DECLARE SECTION END-EXEC.
      *> data source: GixSQL (pgsql://host:port/db?options) or
      *> db@host:port, as in the XAOpen string of the region
       01  DB-SOURCE    PIC X(256).
       01  DB-USER      PIC X(64).
       01  DB-PASSWD    PIC X(64).
           EXEC SQL END DECLARE SECTION END-EXEC.
           EXEC SQL INCLUDE SQLCA END-EXEC.

       LINKAGE          SECTION.
      *> C strings (ended by a null character)
       01  LK-SOURCE    PIC X(256).
       01  LK-USER      PIC X(64).
       01  LK-PASSWD    PIC X(64).

      *> xa_open: connection (the program itself), without autocommit:
      *> the updates of a task are committed or rolled back by TXSeries
      *> (GixSQL 1.0.20b commits each statement by default, despite its
      *> documentation); an autocommit option in the data source, or
      *> GIXSQL_AUTOCOMMIT set in the environment of the region, takes
      *> precedence
       PROCEDURE        DIVISION USING LK-SOURCE LK-USER LK-PASSWD.
           CALL STATIC "setenv" USING
               BY REFERENCE "GIXSQL_AUTOCOMMIT" & X"00"
               BY REFERENCE "off" & X"00"
               BY VALUE 0
           END-CALL
           MOVE SPACES TO DB-SOURCE DB-USER DB-PASSWD
           UNSTRING LK-SOURCE DELIMITED BY X"00" INTO DB-SOURCE
           UNSTRING LK-USER   DELIMITED BY X"00" INTO DB-USER
           UNSTRING LK-PASSWD DELIMITED BY X"00" INTO DB-PASSWD
           EXEC SQL
               CONNECT TO :DB-SOURCE USER :DB-USER USING :DB-PASSWD
           END-EXEC
           MOVE SQLCODE TO RETURN-CODE
           GOBACK.

      *> after the connection (autocommit already off, see above)
       ENTRY "dbautocommit".
           MOVE 0 TO RETURN-CODE
           GOBACK.

      *> xa_start: GixSQL starts the transactions of PostgreSQL itself
       ENTRY "dbbegin".
           MOVE 0 TO RETURN-CODE
           GOBACK.

      *> xa_commit
       ENTRY "dbcommit".
           EXEC SQL COMMIT END-EXEC
           MOVE SQLCODE TO RETURN-CODE
           GOBACK.

      *> xa_rollback
       ENTRY "dbrollback".
           EXEC SQL ROLLBACK END-EXEC
           MOVE SQLCODE TO RETURN-CODE
           GOBACK.

      *> xa_close
       ENTRY "dbconnreset".
           EXEC SQL CONNECT RESET END-EXEC
           MOVE SQLCODE TO RETURN-CODE
           GOBACK.
