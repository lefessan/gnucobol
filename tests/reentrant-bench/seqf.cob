       IDENTIFICATION DIVISION.
       PROGRAM-ID. seqf.
       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT F ASSIGN TO "seq.txt" ORGANIZATION LINE SEQUENTIAL.
       DATA DIVISION.
       FILE SECTION.
       FD F.
       01 R     PIC X(60).
       WORKING-STORAGE SECTION.
       01 I     PIC 9(9) COMP VALUE 0.
       01 N     PIC 9(9) COMP VALUE 0.
       01 EOF-F PIC X VALUE "N".
       PROCEDURE DIVISION.
           OPEN OUTPUT F
           PERFORM VARYING I FROM 1 BY 1 UNTIL I > 1000000
              MOVE I TO R
              WRITE R
           END-PERFORM
           CLOSE F
           OPEN INPUT F
           PERFORM UNTIL EOF-F = "Y"
              READ F AT END MOVE "Y" TO EOF-F
                     NOT AT END ADD 1 TO N END-READ
           END-PERFORM
           CLOSE F
           DISPLAY N
           STOP RUN.
