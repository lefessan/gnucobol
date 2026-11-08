       IDENTIFICATION DIVISION.
       PROGRAM-ID. strs.
       DATA DIVISION.
       WORKING-STORAGE SECTION.
       01 I     PIC 9(9) COMP VALUE 0.
       01 A     PIC X(40) VALUE "hello world, this is a test string".
       01 B     PIC X(40).
       01 C     PIC X(80).
       01 N     PIC 9(4) COMP.
       01 IDS    PIC 9(9).
       PROCEDURE DIVISION.
           PERFORM VARYING I FROM 1 BY 1 UNTIL I > 3000000
              MOVE A TO B
              MOVE I TO IDS
              MOVE SPACES TO C
              STRING B DELIMITED "," "-" IDS DELIMITED SIZE INTO C
              MOVE 0 TO N
              INSPECT C TALLYING N FOR ALL "s"
              INSPECT B REPLACING ALL "o" BY "0"
           END-PERFORM
           DISPLAY C N
           STOP RUN.
