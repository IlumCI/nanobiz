with PK.Diagnostics; use PK.Diagnostics;

package body PK.Lexer is

   use Interfaces;

   function U3 (A, B, C : Natural) return String is
     (Character'Val (A) & Character'Val (B) & Character'Val (C));
   function U2 (A, B : Natural) return String is
     (Character'Val (A) & Character'Val (B));

   Arrow_U  : constant String := U3 (16#E2#, 16#86#, 16#92#);  --  ->
   DArrow_U : constant String := U3 (16#E2#, 16#87#, 16#92#);  --  =>
   Le_U     : constant String := U3 (16#E2#, 16#89#, 16#A4#);  --  <=
   Ge_U     : constant String := U3 (16#E2#, 16#89#, 16#A5#);  --  >=
   Ne_U     : constant String := U3 (16#E2#, 16#89#, 16#A0#);  --  /=
   And_U    : constant String := U3 (16#E2#, 16#88#, 16#A7#);  --  logical and
   Or_U     : constant String := U3 (16#E2#, 16#88#, 16#A8#);  --  logical or
   Xor_U    : constant String := U3 (16#E2#, 16#8A#, 16#95#);  --  circled plus
   Times_U  : constant String := U2 (16#C3#, 16#97#);          --  multiplication sign
   Div_U    : constant String := U2 (16#C3#, 16#B7#);          --  division sign
   Not_U    : constant String := U2 (16#C2#, 16#AC#);          --  not sign

   function Tokenize (Source : String) return Token_Vectors.Vector is
      Result : Token_Vectors.Vector;
      P      : Integer := Source'First;
      Line   : Positive := 1;
      Col    : Positive := 1;
      Depth  : Natural := 0;

      function At_End return Boolean is (P > Source'Last);

      function Ch (Offset : Natural := 0) return Character is
        (if P + Offset <= Source'Last then Source (P + Offset) else ASCII.NUL);

      function Looking_At (S : String) return Boolean is
        (P + S'Length - 1 <= Source'Last
         and then Source (P .. P + S'Length - 1) = S);

      procedure Adv (N : Positive := 1) is
      begin
         for K in 1 .. N loop
            if Source (P) = ASCII.LF then
               Line := @ + 1;
               Col := 1;
            elsif Character'Pos (Source (P)) not in 16#80# .. 16#BF# then
               Col := @ + 1;
            end if;
            P := @ + 1;
         end loop;
      end Adv;

      function Is_Letter (C : Character) return Boolean is
        (C in 'A' .. 'Z' | 'a' .. 'z' | '_');
      function Is_Digit (C : Character) return Boolean is (C in '0' .. '9');

      procedure Push (K : Token_Kind; L, C : Positive; Len : Natural := 1) is
      begin
         Result.Append (Token'(Kind => K, Line => L, Col => C, others => <>));
         if Len > 0 then
            Adv (Len);
         end if;
      end Push;

      procedure Lex_Number is
         L    : constant Positive := Line;
         C    : constant Positive := Col;
         Base : Unsigned_64 := 10;
         V    : Unsigned_64 := 0;
         Seen : Boolean := False;
      begin
         if Ch = '0' and then Ch (1) in 'b' | 'B' and then Ch (2) in '0' .. '1' then
            Base := 2;
            Adv (2);
         elsif Ch = '0' and then Ch (1) in 'x' | 'X'
           and then Ch (2) in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F'
         then
            Base := 16;
            Adv (2);
         end if;
         loop
            declare
               D : Unsigned_64;
               X : constant Character := Ch;
            begin
               if X = '_' and then Seen then
                  Adv;
               else
                  case X is
                     when '0' .. '9' => D := Character'Pos (X) - Character'Pos ('0');
                     when 'a' .. 'f' => D := Character'Pos (X) - Character'Pos ('a') + 10;
                     when 'A' .. 'F' => D := Character'Pos (X) - Character'Pos ('A') + 10;
                     when others => exit;
                  end case;
                  exit when D >= Base;
                  if V > (Unsigned_64'Last - D) / Base then
                     Error (L, C, "integer literal exceeds 64 bits");
                  end if;
                  V := V * Base + D;
                  Seen := True;
                  Adv;
               end if;
            end;
         end loop;
         if Is_Letter (Ch) or else Is_Digit (Ch) then
            Error (Line, Col, "malformed integer literal");
         end if;
         Result.Append (Token'(Kind => Tk_Int, Line => L, Col => C, Value => V,
                               others => <>));
      end Lex_Number;

      procedure Lex_Word is
         L     : constant Positive := Line;
         C     : constant Positive := Col;
         Start : constant Positive := P;
      begin
         while Is_Letter (Ch) or else Is_Digit (Ch) loop
            Adv;
         end loop;
         declare
            S : constant String := Source (Start .. P - 1);
         begin
            if S'Length >= 2 and then S (S'First) in 'V' | 'Z' | 'R'
              and then (for all X of S (S'First + 1 .. S'Last) => Is_Digit (X))
            then
               if S'Length > 7 then
                  Error (L, C, "variable index too large in " & S);
               end if;
               Result.Append
                 (Token'(Kind => Tk_Var, Line => L, Col => C,
                         Var_Class => S (S'First),
                         Var_Index => Natural'Value (S (S'First + 1 .. S'Last)),
                         others => <>));
            else
               Result.Append
                 (Token'(Kind => Tk_Ident, Line => L, Col => C,
                         Text => To_Unbounded_String (S), others => <>));
            end if;
         end;
      end Lex_Word;

   begin
      while not At_End loop
         declare
            C  : constant Character := Ch;
            L  : constant Positive := Line;
            Cl : constant Positive := Col;
         begin
            if C in ' ' | ASCII.HT | ASCII.CR then
               Adv;
            elsif C = ASCII.LF then
               if Depth = 0 then
                  Push (Tk_NL, L, Cl);
               else
                  Adv;
               end if;
            elsif C = '#' or else (C = '/' and then Ch (1) = '/') then
               while not At_End and then Ch /= ASCII.LF loop
                  Adv;
               end loop;
            elsif Is_Digit (C) then
               Lex_Number;
            elsif Is_Letter (C) then
               Lex_Word;
            elsif Looking_At ("->") or else Looking_At ("=>") then
               Push (Tk_Arrow, L, Cl, 2);
            elsif Looking_At (Arrow_U) or else Looking_At (DArrow_U) then
               Push (Tk_Arrow, L, Cl, 3);
            elsif Looking_At ("<=") then
               Push (Tk_Le, L, Cl, 2);
            elsif Looking_At (">=") then
               Push (Tk_Ge, L, Cl, 2);
            elsif Looking_At ("!=") then
               Push (Tk_Ne, L, Cl, 2);
            elsif Looking_At (Le_U) then
               Push (Tk_Le, L, Cl, 3);
            elsif Looking_At (Ge_U) then
               Push (Tk_Ge, L, Cl, 3);
            elsif Looking_At (Ne_U) then
               Push (Tk_Ne, L, Cl, 3);
            elsif Looking_At (And_U) then
               Push (Tk_And, L, Cl, 3);
            elsif Looking_At (Or_U) then
               Push (Tk_Or, L, Cl, 3);
            elsif Looking_At (Xor_U) then
               Push (Tk_Xor, L, Cl, 3);
            elsif Looking_At (Times_U) then
               Push (Tk_Star, L, Cl, 2);
            elsif Looking_At (Div_U) then
               Push (Tk_Slash, L, Cl, 2);
            elsif Looking_At (Not_U) then
               Push (Tk_Not, L, Cl, 2);
            else
               case C is
                  when '(' =>
                     Depth := @ + 1;
                     Push (Tk_LParen, L, Cl);
                  when ')' =>
                     if Depth > 0 then
                        Depth := @ - 1;
                     end if;
                     Push (Tk_RParen, L, Cl);
                  when '[' => Push (Tk_LBrack, L, Cl);
                  when ']' => Push (Tk_RBrack, L, Cl);
                  when ':' => Push (Tk_Colon, L, Cl);
                  when ',' => Push (Tk_Comma, L, Cl);
                  when ';' => Push (Tk_Semi, L, Cl);
                  when '.' => Push (Tk_Dot, L, Cl);
                  when '+' => Push (Tk_Plus, L, Cl);
                  when '-' => Push (Tk_Minus, L, Cl);
                  when '*' => Push (Tk_Star, L, Cl);
                  when '/' => Push (Tk_Slash, L, Cl);
                  when '%' => Push (Tk_Percent, L, Cl);
                  when '=' => Push (Tk_Eq, L, Cl);
                  when '<' => Push (Tk_Lt, L, Cl);
                  when '>' => Push (Tk_Gt, L, Cl);
                  when '&' => Push (Tk_And, L, Cl);
                  when '|' => Push (Tk_Or, L, Cl);
                  when '^' => Push (Tk_Xor, L, Cl);
                  when '!' | '~' => Push (Tk_Not, L, Cl);
                  when others =>
                     Error (L, Cl, "unexpected character");
               end case;
            end if;
         end;
      end loop;
      Result.Append (Token'(Kind => Tk_NL, Line => Line, Col => Col, others => <>));
      Result.Append (Token'(Kind => Tk_EOF, Line => Line, Col => Col, others => <>));
      return Result;
   end Tokenize;

   function Describe (T : Token) return String is
     (case T.Kind is
         when Tk_Int     => "integer " & Img_U (T.Value),
         when Tk_Ident   => "'" & To_String (T.Text) & "'",
         when Tk_Var     => "variable " & T.Var_Class & Img (T.Var_Index),
         when Tk_Arrow   => "'->'",
         when Tk_LParen  => "'('",
         when Tk_RParen  => "')'",
         when Tk_LBrack  => "'['",
         when Tk_RBrack  => "']'",
         when Tk_Colon   => "':'",
         when Tk_Comma   => "','",
         when Tk_Semi    => "';'",
         when Tk_Dot     => "'.'",
         when Tk_Plus    => "'+'",
         when Tk_Minus   => "'-'",
         when Tk_Star    => "'*'",
         when Tk_Slash   => "'/'",
         when Tk_Percent => "'%'",
         when Tk_Eq      => "'='",
         when Tk_Ne      => "'!='",
         when Tk_Lt      => "'<'",
         when Tk_Le      => "'<='",
         when Tk_Gt      => "'>'",
         when Tk_Ge      => "'>='",
         when Tk_And     => "'&'",
         when Tk_Or      => "'|'",
         when Tk_Xor     => "'^'",
         when Tk_Not     => "'!'",
         when Tk_NL      => "end of line",
         when Tk_EOF     => "end of file");

end PK.Lexer;
