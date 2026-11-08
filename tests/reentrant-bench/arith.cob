       IDENTIFICATION DIVISION.
       PROGRAM-ID. arith.
       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 I     PIC 9(9) COMP VALUE 0.
       01 D     PIC S9(9)V99 VALUE 0.
       01 P     PIC S9(11)V99 COMP-3 VALUE 0.
       01 B     PIC S9(9) COMP-5 VALUE 0.
       PROCEDURE DIVISION.
           PERFORM VARYING I FROM 1 BY 1 UNTIL I > 20000000
              ADD 1 TO B
              ADD 1.25 TO D
              COMPUTE P = P + D * 2 - B
              IF D > 100000 MOVE 0 TO D END-IF
           END-PERFORM
           DISPLAY P
           STOP RUN.
