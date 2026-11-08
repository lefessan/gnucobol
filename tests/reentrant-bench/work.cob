       IDENTIFICATION DIVISION.
       PROGRAM-ID. work.
       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 CNT   PIC 9(8) VALUE 0.
       01 X     PIC S9(10)V9(6) COMP-3.
       01 S     PIC X(30).
       LINKAGE SECTION.
       01 RES   PIC 9(8).
       01 TID   PIC 99.
       PROCEDURE DIVISION USING RES TID.
           ADD 1 TO CNT
           COMPUTE X = CNT * 1.5 + FUNCTION SQRT (CNT) + FUNCTION PI
           MOVE SPACES TO S
           STRING "v" CNT DELIMITED SIZE INTO S
           INSPECT S REPLACING ALL "0" BY "o"
           CALL "wsub" USING CNT
           MOVE CNT TO RES
           GOBACK.
