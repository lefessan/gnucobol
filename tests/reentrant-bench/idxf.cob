       IDENTIFICATION DIVISION.
       PROGRAM-ID. idxf.
       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT F ASSIGN TO "idx.dat" ORGANIZATION INDEXED
                  ACCESS DYNAMIC RECORD KEY K.
       DATA DIVISION.
       FILE SECTION.
       FD F.
       01 R.
          05 K  PIC 9(8).
          05 V  PIC X(40).
       WORKING-STORAGE SECTION.
       01 I     PIC 9(9) COMP VALUE 0.
       01 N     PIC 9(9) COMP VALUE 0.
       PROCEDURE DIVISION.
           OPEN OUTPUT F
           PERFORM VARYING I FROM 1 BY 1 UNTIL I > 200000
              MOVE I TO K
              MOVE "value" TO V
              WRITE R
           END-PERFORM
           CLOSE F
           OPEN INPUT F
           PERFORM VARYING I FROM 1 BY 1 UNTIL I > 200000
              MOVE I TO K
              READ F KEY IS K
              IF K = I ADD 1 TO N END-IF
           END-PERFORM
           CLOSE F
           DISPLAY N
           STOP RUN.
