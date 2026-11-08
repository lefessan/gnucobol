       IDENTIFICATION DIVISION.
       PROGRAM-ID. csub.
       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 K     PIC 9(9) COMP VALUE 0.
       LINKAGE SECTION.
       01 I     PIC 9(9) COMP.
       01 T     PIC 9(9) COMP.
       PROCEDURE DIVISION USING I T.
           ADD 1 TO K
           MOVE K TO T
           GOBACK.
