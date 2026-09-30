with Interfaces.C;
with Interfaces.C.Strings;
with System;
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
   PM_U     : constant String := U2 (16#C2#, 16#B1#);          --  plus-minus sign

   function C_Strtod
     (S : Interfaces.C.Strings.chars_ptr; Endp : System.Address) return Interfaces.C.double
     with Import, Convention => C, External_Name => "strtod";

   --  Correctly rounded decimal to binary64 conversion (C library).
   function To_Double (Text : String) return Interfaces.C.double is
      use Interfaces.C.Strings;
      P : chars_ptr := New_String (Text);
      D : constant Interfaces.C.double := C_Strtod (P, System.Null_Address);
   begin
      Free (P);
      return D;
   end To_Double;

   function Tokenize (Source : String) return Token_Vectors.Vector is
      Result : Token_Vectors.Vector;
      P      : Integer := Source'First;
      Line   : Positive := 1;
      Col    : Positive := 1;
      Depth  : Natural := 0;
      --  Open brackets: component selectors (after a variable, a loop
      --  index or another selector) versus statement blocks. Only inside
      --  a selector is "5.3" a component path rather than a number.
      Kinds       : array (1 .. 256) of Boolean;   --  True = selector
      Open        : Natural := 0;
      Selectors   : Natural := 0;
      Last_Closed : Boolean := False;              --  kind of the last ']'
      Types  : Boolean := False;

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
         Result.Append (Token'(Kind => K, Line => L, Col => C, Start => P,
                               Stop => P + Len - 1, others => <>));
         if Len > 0 then
            Adv (Len);
         end if;
      end Push;

      procedure Lex_Number is
         L     : constant Positive := Line;
         C     : constant Positive := Col;
         First : constant Positive := P;
         Base  : Unsigned_64 := 10;
         V     : Unsigned_64 := 0;
         Seen  : Boolean := False;
      begin
         if not Types and then Ch = '0' and then Ch (1) in 'b' | 'B'
           and then Ch (2) in '0' .. '1'
         then
            Base := 2;
            Adv (2);
         elsif not Types and then Ch = '0' and then Ch (1) in 'x' | 'X'
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

         --  Floating-point literal: digits '.' digits [exponent] or
         --  digits exponent; only outside brackets and types.
         if Base = 10 and then not Types and then Selectors = 0
           and then ((Ch = '.' and then Is_Digit (Ch (1)))
                     or else (Ch in 'e' | 'E'
                              and then (Is_Digit (Ch (1))
                                        or else (Ch (1) in '+' | '-'
                                                 and then Is_Digit (Ch (2))))))
         then
            if Ch = '.' then
               Adv;
               while Is_Digit (Ch) or else Ch = '_' loop
                  Adv;
               end loop;
            end if;
            if Ch in 'e' | 'E'
              and then (Is_Digit (Ch (1))
                        or else (Ch (1) in '+' | '-' and then Is_Digit (Ch (2))))
            then
               Adv (if Is_Digit (Ch (1)) then 1 else 2);
               while Is_Digit (Ch) loop
                  Adv;
               end loop;
            end if;
            if Is_Letter (Ch) or else Is_Digit (Ch) then
               Error (Line, Col, "malformed floating-point literal");
            end if;
            declare
               Text : Unbounded_String;
            begin
               for X of Source (First .. P - 1) loop
                  if X /= '_' then
                     Append (Text, X);
                  end if;
               end loop;
               declare
                  D : constant Interfaces.C.double := To_Double (To_String (Text));
               begin
                  if not D'Valid then
                     Error (L, C, "floating-point literal out of range");
                  end if;
                  Result.Append (Token'(Kind => Tk_Float, Line => L, Col => C,
                                        Float_Val => Long_Float (D),
                                        Start => First, Stop => P - 1, others => <>));
               end;
            end;
            return;
         end if;

         if not Types and then (Is_Letter (Ch) or else Is_Digit (Ch)) then
            Error (Line, Col, "malformed integer literal");
         end if;
         Result.Append (Token'(Kind => Tk_Int, Line => L, Col => C, Value => V,
                               Start => First, Stop => P - 1, others => <>));
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
                         Start => Start, Stop => P - 1, others => <>));
            else
               Result.Append
                 (Token'(Kind => Tk_Ident, Line => L, Col => C,
                         Text => To_Unbounded_String (S),
                         Start => Start, Stop => P - 1, others => <>));
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
            elsif Types and then C = 'x' and then not Result.Is_Empty
              and then Result.Last_Element.Kind = Tk_Int
            then
               Push (Tk_Star, L, Cl);
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
            elsif Looking_At (PM_U) then
               Push (Tk_PlusMinus, L, Cl, 2);
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
                  when '[' =>
                     declare
                        Prev     : constant Token :=
                          (if Result.Is_Empty then (others => <>) else Result.Last_Element);
                        Selector : constant Boolean :=
                          Prev.Kind = Tk_Var
                          or else (Prev.Kind = Tk_Ident and then To_String (Prev.Text) /= "W")
                          or else (Prev.Kind = Tk_RBrack and then Last_Closed);
                     begin
                        if Open = Kinds'Last then
                           Error (L, Cl, "brackets nested too deeply");
                        end if;
                        Open := @ + 1;
                        Kinds (Open) := Selector;
                        if Selector then
                           Selectors := @ + 1;
                        end if;
                     end;
                     Push (Tk_LBrack, L, Cl);
                  when ']' =>
                     if Open > 0 then
                        Last_Closed := Kinds (Open);
                        if Kinds (Open) then
                           Selectors := @ - 1;
                        end if;
                        Open := @ - 1;
                     end if;
                     Types := False;
                     Push (Tk_RBrack, L, Cl);
                  when ':' =>
                     Types := True;
                     Push (Tk_Colon, L, Cl);
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
         when Tk_Float   => "floating-point literal",
         when Tk_PlusMinus => "'+-'",
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
