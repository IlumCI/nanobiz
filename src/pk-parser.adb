with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces; use Interfaces;
with PK.Diagnostics; use PK.Diagnostics;
with PK.Lexer; use PK.Lexer;
with PK.Types; use PK.Types;

package body PK.Parser is

   use PK.AST;

   Toks : Token_Vectors.Vector;
   Pos  : Positive := 1;
   Src  : Unbounded_String;

   function Cur return Token is (Toks (Pos));

   function Peek return Token is
     (if Pos < Toks.Last_Index then Toks (Pos + 1) else Toks.Last_Element);

   procedure Advance is
   begin
      if Pos < Toks.Last_Index then
         Pos := @ + 1;
      end if;
   end Advance;

   procedure Fail (Msg : String) with No_Return;
   procedure Fail (Msg : String) is
   begin
      Error (Cur.Line, Cur.Col, Msg);
   end Fail;

   procedure Expect (K : Token_Kind; What : String) is
   begin
      if Cur.Kind /= K then
         Fail ("expected " & What & ", found " & Describe (Cur));
      end if;
      Advance;
   end Expect;

   function Is_Kw (T : Token; S : String) return Boolean is
     (T.Kind = Tk_Ident and then To_String (T.Text) = S);

   function Digits_After (S : String; Prefix : Character) return Boolean is
     (S'Length >= 2 and then S'Length <= 7 and then S (S'First) = Prefix
      and then (for all C of S (S'First + 1 .. S'Last) => C in '0' .. '9'));

   function Is_Plan_Header (T : Token) return Boolean is
     (T.Kind = Tk_Ident and then Digits_After (To_String (T.Text), 'P'));

   function Is_Loop_Index (T : Token) return Boolean is
     (T.Kind = Tk_Ident
      and then (To_String (T.Text) = "i" or else Digits_After (To_String (T.Text), 'i')));

   function Is_Loop_Kw (T : Token) return Boolean is
     (Is_Kw (T, "W") or else Is_Kw (T, "W1") or else Is_Kw (T, "W2"));

   function Is_Reserved (T : Token) return Boolean is
     (Is_Kw (T, "END") or else Is_Kw (T, "FIN") or else Is_Kw (T, "ASSERT")
      or else Is_Loop_Kw (T));

   ----------
   -- Types --
   ----------

   function Parse_Type return Ty is
      L : constant Positive := Cur.Line;
      C : constant Positive := Cur.Col;
   begin
      case Cur.Kind is
         when Tk_LParen =>
            Advance;
            declare
               Fields : Ty_List (1 .. 1024);
               N      : Natural := 0;
            begin
               loop
                  if N = Fields'Last then
                     Error (L, C, "too many record components");
                  end if;
                  N := @ + 1;
                  Fields (N) := Parse_Type;
                  exit when Cur.Kind /= Tk_Comma;
                  Advance;
               end loop;
               Expect (Tk_RParen, "')' closing the record type");
               return Rec (Fields (1 .. N));
            end;

         when Tk_PlusMinus | Tk_Plus =>
            if Cur.Kind = Tk_Plus then
               Advance;
               if Cur.Kind /= Tk_Minus then
                  Fail ("expected '+-' (signed word) in type");
               end if;
            end if;
            Advance;
            declare
               T : constant Ty := Parse_Type;
            begin
               if T.Kind /= K_Word then
                  Error (L, C, "'+-' applies to words n.0 with n <= 64, not " & Image (T));
               end if;
               return Word (T.Width, Signed => True);
            end;

         when Tk_Ident =>
            declare
               S : constant String := To_String (Cur.Text);
            begin
               Advance;
               if S = "f32" then
                  return Float_Ty (32);
               elsif S = "f64" then
                  return Float_Ty (64);
               elsif S = "A8" or else S = "A9" then
                  return Word (64);
               elsif S = "A10" then
                  return Word (64, Signed => True);
               elsif S = "A11" or else S = "A12" or else S = "A13" then
                  Error (L, C, "Zuse's type " & S & " (fractions/complex numbers) is not "
                         & "supported; use f64 or a record such as (f64, f64)");
               else
                  Error (L, C, "unknown type name '" & S & "'");
               end if;
            end;

         when Tk_Int =>
            declare
               N : constant Unsigned_64 := Cur.Value;
            begin
               Advance;
               if Cur.Kind not in Tk_Dot | Tk_Star then
                  if N = 0 then
                     return Word (1);
                  end if;
                  Fail ("expected '.' or 'x' in type (an n-bit word is written n.0)");
               end if;
               if N = 0 then
                  Error (L, C, "component count in a type must be positive");
               end if;
               if N > 2 ** 24 then
                  Error (L, C, "type too large");
               end if;
               Advance;
               if Cur.Kind = Tk_Int and then Cur.Value = 0
                 and then Peek.Kind not in Tk_Dot | Tk_Star
               then
                  Advance;
                  if N <= Max_Width then
                     return Word (Positive (N));
                  end if;
                  --  An m-bit structure wider than a machine word is kept as
                  --  an array of m bits: components are accessible, arithmetic
                  --  is not.
                  return Arr (Positive (N), Word (1));
               end if;
               return Arr (Positive (N), Parse_Type);
            end;

         when others =>
            Fail ("expected a type such as 0, 8.0, +-16.0, f64, 4.8.0 or (0, 8.0), found "
                  & Describe (Cur));
      end case;
   end Parse_Type;

   -----------------
   -- Expressions --
   -----------------

   function Parse_Expr return Expr;

   function Parse_Ref return Expr is
      T : constant Token := Cur;
      E : constant Expr := new Expr_Node (E_Ref);
   begin
      E.Line := T.Line;
      E.Col := T.Col;
      if T.Kind = Tk_Var then
         E.Class := (case T.Var_Class is
                        when 'V' => C_V,
                        when 'Z' => C_Z,
                        when others => C_R);
         E.Index := T.Var_Index;
      else
         declare
            S : constant String := To_String (T.Text);
         begin
            E.Class := C_Loop;
            E.Index := (if S = "i" then -1 else Integer'Value (S (S'First + 1 .. S'Last)));
         end;
      end if;
      Advance;
      while Cur.Kind = Tk_LBrack loop
         Advance;
         if Cur.Kind = Tk_Colon then
            if not E.Indices.Is_Empty or else E.Decl_Annot /= null then
               Fail ("a bare type annotation [:T] must be the first bracket");
            end if;
            Advance;
            E.Decl_Annot := Parse_Type;
         else
            --  A component path "a.b.c" selects component c of b of a.
            loop
               E.Indices.Append (Parse_Expr);
               exit when Cur.Kind /= Tk_Dot;
               E.Index_Annots.Append (null);
               Advance;
            end loop;
            if Cur.Kind = Tk_Colon then
               Advance;
               E.Index_Annots.Append (Parse_Type);
            else
               E.Index_Annots.Append (null);
            end if;
         end if;
         Expect (Tk_RBrack, "']'");
      end loop;
      return E;
   end Parse_Ref;

   function Parse_Primary return Expr is
      T : constant Token := Cur;
   begin
      case T.Kind is
         when Tk_Int =>
            Advance;
            declare
               E : constant Expr := new Expr_Node (E_Int);
            begin
               E.Line := T.Line;
               E.Col := T.Col;
               E.Value := T.Value;
               return E;
            end;
         when Tk_Float =>
            Advance;
            declare
               E : constant Expr := new Expr_Node (E_Float);
            begin
               E.Line := T.Line;
               E.Col := T.Col;
               E.Float_Val := T.Float_Val;
               return E;
            end;
         when Tk_LParen =>
            Advance;
            return E : constant Expr := Parse_Expr do
               Expect (Tk_RParen, "')'");
            end return;
         when Tk_Var =>
            return Parse_Ref;
         when Tk_Ident =>
            if Is_Loop_Index (T) then
               return Parse_Ref;
            elsif Is_Reserved (T) then
               Fail ("unexpected " & Describe (T) & " in expression");
            elsif Peek.Kind /= Tk_LParen then
               Fail ("unknown identifier " & Describe (T)
                     & " (variables are V<n>, Z<n>, R<n>; plan calls need arguments)");
            end if;
            declare
               E : constant Expr := new Expr_Node (E_Call);
            begin
               E.Line := T.Line;
               E.Col := T.Col;
               E.Callee := T.Text;
               Advance;
               Advance;
               if Cur.Kind /= Tk_RParen then
                  loop
                     E.Args.Append (Parse_Expr);
                     exit when Cur.Kind /= Tk_Comma;
                     Advance;
                  end loop;
               end if;
               Expect (Tk_RParen, "')' closing the argument list");
               return E;
            end;
         when others =>
            Fail ("expected an expression, found " & Describe (T));
      end case;
   end Parse_Primary;

   function Parse_Unary return Expr is
      T : constant Token := Cur;
   begin
      --  A minus sign directly before a literal makes a negative literal.
      if T.Kind = Tk_Minus and then Peek.Kind = Tk_Int then
         Advance;
         declare
            E : constant Expr := new Expr_Node (E_Int);
         begin
            E.Line := T.Line;
            E.Col := T.Col;
            E.Value := Cur.Value;
            E.Negative := Cur.Value /= 0;
            Advance;
            return E;
         end;
      elsif T.Kind = Tk_Minus and then Peek.Kind = Tk_Float then
         Advance;
         declare
            E : constant Expr := new Expr_Node (E_Float);
         begin
            E.Line := T.Line;
            E.Col := T.Col;
            E.Float_Val := -Cur.Float_Val;
            Advance;
            return E;
         end;
      end if;
      if T.Kind in Tk_Minus | Tk_Not then
         Advance;
         declare
            E : constant Expr := new Expr_Node (E_Unary);
         begin
            E.Line := T.Line;
            E.Col := T.Col;
            E.Un_Op := (if T.Kind = Tk_Minus then Op_Neg else Op_Not);
            E.Operand := Parse_Unary;
            return E;
         end;
      end if;
      return Parse_Primary;
   end Parse_Unary;

   function Make_Bin (Op : Op_Kind; L, R : Expr; T : Token) return Expr is
      E : constant Expr := new Expr_Node (E_Binary);
   begin
      E.Line := T.Line;
      E.Col := T.Col;
      E.Bin_Op := Op;
      E.Left := L;
      E.Right := R;
      return E;
   end Make_Bin;

   function Parse_Mul return Expr is
      L : Expr := Parse_Unary;
   begin
      loop
         declare
            T  : constant Token := Cur;
            Op : Op_Kind;
         begin
            case T.Kind is
               when Tk_Star    => Op := Op_Mul;
               when Tk_Slash   => Op := Op_Div;
               when Tk_Percent => Op := Op_Mod;
               when others     => return L;
            end case;
            Advance;
            L := Make_Bin (Op, L, Parse_Unary, T);
         end;
      end loop;
   end Parse_Mul;

   function Parse_Add return Expr is
      L : Expr := Parse_Mul;
   begin
      loop
         declare
            T  : constant Token := Cur;
            Op : Op_Kind;
         begin
            case T.Kind is
               when Tk_Plus  => Op := Op_Add;
               when Tk_Minus => Op := Op_Sub;
               when others   => return L;
            end case;
            Advance;
            L := Make_Bin (Op, L, Parse_Mul, T);
         end;
      end loop;
   end Parse_Add;

   function Compare_Of (K : Token_Kind; Op : out Op_Kind) return Boolean is
   begin
      case K is
         when Tk_Eq => Op := Op_Eq;
         when Tk_Ne => Op := Op_Ne;
         when Tk_Lt => Op := Op_Lt;
         when Tk_Le => Op := Op_Le;
         when Tk_Gt => Op := Op_Gt;
         when Tk_Ge => Op := Op_Ge;
         when others =>
            Op := Op_Eq;
            return False;
      end case;
      return True;
   end Compare_Of;

   function Parse_Cmp return Expr is
      L  : constant Expr := Parse_Add;
      T  : constant Token := Cur;
      Op : Op_Kind;
   begin
      if not Compare_Of (T.Kind, Op) then
         return L;
      end if;
      Advance;
      declare
         E     : constant Expr := Make_Bin (Op, L, Parse_Add, T);
         Dummy : Op_Kind;
      begin
         if Compare_Of (Cur.Kind, Dummy) then
            Fail ("comparisons cannot be chained; use parentheses and '&'");
         end if;
         return E;
      end;
   end Parse_Cmp;

   function Parse_And return Expr is
      L : Expr := Parse_Cmp;
   begin
      while Cur.Kind = Tk_And loop
         declare
            T : constant Token := Cur;
         begin
            Advance;
            L := Make_Bin (Op_And, L, Parse_Cmp, T);
         end;
      end loop;
      return L;
   end Parse_And;

   function Parse_Xor return Expr is
      L : Expr := Parse_And;
   begin
      while Cur.Kind = Tk_Xor loop
         declare
            T : constant Token := Cur;
         begin
            Advance;
            L := Make_Bin (Op_Xor, L, Parse_And, T);
         end;
      end loop;
      return L;
   end Parse_Xor;

   function Parse_Expr return Expr is
      L : Expr := Parse_Xor;
   begin
      while Cur.Kind = Tk_Or loop
         declare
            T : constant Token := Cur;
         begin
            Advance;
            L := Make_Bin (Op_Or, L, Parse_Xor, T);
         end;
      end loop;
      return L;
   end Parse_Expr;

   ----------------
   -- Statements --
   ----------------

   function New_Stmt (K : Stmt_Kind; Line, Col : Positive) return Stmt is
      S : constant Stmt := new Stmt_Node (K);
   begin
      S.Line := Line;
      S.Col := Col;
      return S;
   end New_Stmt;

   function Parse_Stmt return Stmt;

   function At_Stmt_End return Boolean is
     (Cur.Kind in Tk_NL | Tk_Semi | Tk_RBrack | Tk_EOF or else Is_Kw (Cur, "END"));

   function Parse_Stmts return Stmt_Vectors.Vector is
      Result : Stmt_Vectors.Vector;
   begin
      loop
         while Cur.Kind in Tk_NL | Tk_Semi loop
            Advance;
         end loop;
         exit when Cur.Kind in Tk_RBrack | Tk_EOF or else Is_Kw (Cur, "END");
         Result.Append (Parse_Stmt);
         if not At_Stmt_End then
            Fail ("expected end of statement, found " & Describe (Cur));
         end if;
      end loop;
      return Result;
   end Parse_Stmts;

   function Parse_Block return Stmt_Vectors.Vector is
   begin
      Expect (Tk_LBrack, "'[' opening a block");
      return Result : constant Stmt_Vectors.Vector := Parse_Stmts do
         Expect (Tk_RBrack, "']' closing the block");
      end return;
   end Parse_Block;

   function Parse_Loop return Stmt is
      T    : constant Token := Cur;
      Name : constant String := To_String (T.Text);
   begin
      Advance;
      if Name = "W" then
         if Cur.Kind = Tk_LParen then
            Advance;
            declare
               S : constant Stmt := New_Stmt (S_While, T.Line, T.Col);
            begin
               S.While_Cond := Parse_Expr;
               Expect (Tk_RParen, "')' closing the loop condition");
               S.While_Body := Parse_Block;
               return S;
            end;
         end if;
         declare
            S : constant Stmt := New_Stmt (S_Loop, T.Line, T.Col);
         begin
            S.Stmts := Parse_Block;
            return S;
         end;
      end if;
      Expect (Tk_LParen, "'(' after " & Name);
      declare
         S : constant Stmt := New_Stmt (S_Count, T.Line, T.Col);
      begin
         S.Count := Parse_Expr;
         S.Down := Name = "W2";
         Expect (Tk_RParen, "')' closing the repetition count");
         S.Count_Body := Parse_Block;
         return S;
      end;
   end Parse_Loop;

   --  Called after "Lhs ->". Either "Lhs -> target {, target}" (assignment)
   --  or "Lhs -> statement" (Lhs is a condition).
   function Parse_After_Arrow (Lhs : Expr; Line, Col : Positive) return Stmt is
   begin
      if Cur.Kind = Tk_LBrack or else Is_Kw (Cur, "FIN") or else Is_Kw (Cur, "ASSERT")
        or else Is_Loop_Kw (Cur)
      then
         declare
            S : constant Stmt := New_Stmt (S_Cond, Line, Col);
         begin
            S.Cond := Lhs;
            S.Then_Part := Parse_Stmt;
            return S;
         end;
      end if;
      declare
         Rhs : constant Expr := Parse_Expr;
      begin
         if Cur.Kind = Tk_Arrow then
            Advance;
            declare
               S : constant Stmt := New_Stmt (S_Cond, Line, Col);
            begin
               S.Cond := Lhs;
               S.Then_Part := Parse_After_Arrow (Rhs, Rhs.Line, Rhs.Col);
               return S;
            end;
         end if;
         if Rhs.Kind /= E_Ref then
            Error (Rhs.Line, Rhs.Col, "the target of '->' must be a variable");
         end if;
         declare
            S : constant Stmt := New_Stmt (S_Assign, Line, Col);
         begin
            S.Source := Lhs;
            S.Targets.Append (Rhs);
            while Cur.Kind = Tk_Comma loop
               Advance;
               declare
                  X : constant Expr := Parse_Expr;
               begin
                  if X.Kind /= E_Ref then
                     Error (X.Line, X.Col, "the target of '->' must be a variable");
                  end if;
                  S.Targets.Append (X);
               end;
            end loop;
            return S;
         end;
      end;
   end Parse_After_Arrow;

   function Parse_Stmt return Stmt is
      T : constant Token := Cur;
   begin
      if Is_Kw (T, "FIN") then
         Advance;
         return New_Stmt (S_Fin, T.Line, T.Col);
      elsif Is_Kw (T, "ASSERT") then
         Advance;
         declare
            S     : constant Stmt := New_Stmt (S_Assert, T.Line, T.Col);
            First : constant Natural := Cur.Start;
         begin
            S.Assert_Cond := Parse_Expr;
            S.Assert_Text := To_Unbounded_String (Slice (Src, First, Toks (Pos - 1).Stop));
            return S;
         end;
      elsif Is_Loop_Kw (T) then
         return Parse_Loop;
      elsif T.Kind = Tk_LBrack then
         declare
            S : constant Stmt := New_Stmt (S_Block, T.Line, T.Col);
         begin
            S.Stmts := Parse_Block;
            return S;
         end;
      end if;
      declare
         E : constant Expr := Parse_Expr;
      begin
         Expect (Tk_Arrow, "'->' (assignment or condition)");
         return Parse_After_Arrow (E, T.Line, T.Col);
      end;
   end Parse_Stmt;

   -----------
   -- Plans --
   -----------

   function Parse_Decl (Class : Character) return Param is
      T : constant Token := Cur;
   begin
      if T.Kind /= Tk_Var or else T.Var_Class /= Class then
         Fail ("expected " & (if Class = 'V' then "a parameter V<n>[:type]"
                              else "a result R<n>[:type]")
               & ", found " & Describe (T));
      end if;
      Advance;
      Expect (Tk_LBrack, "'[' (declarations are written " & Class & "0[:type])");
      Expect (Tk_Colon, "':' (declarations are written " & Class & "0[:type])");
      return R : Param do
         R.Index := T.Var_Index;
         R.Line := T.Line;
         R.Col := T.Col;
         R.Ty := Parse_Type;
         Expect (Tk_RBrack, "']'");
      end return;
   end Parse_Decl;

   function Parse_Plan return Plan is
      T : constant Token := Cur;
      P : constant Plan := new Plan_Decl;
   begin
      if not Is_Plan_Header (T) then
         Fail ("expected a plan header such as 'P1 name (V0[:8.0]) -> R0[:8.0]', found "
               & Describe (T));
      end if;
      declare
         S : constant String := To_String (T.Text);
      begin
         P.Number := Natural'Value (S (S'First + 1 .. S'Last));
      end;
      P.Line := T.Line;
      P.Col := T.Col;
      Advance;
      if Cur.Kind = Tk_Ident then
         if Is_Reserved (Cur) or else Is_Plan_Header (Cur) or else Is_Loop_Index (Cur) then
            Fail ("invalid plan name " & Describe (Cur));
         end if;
         P.Name := Cur.Text;
         Advance;
      end if;
      Expect (Tk_LParen, "'(' opening the parameter list");
      if Cur.Kind /= Tk_RParen then
         loop
            P.Params.Append (Parse_Decl ('V'));
            exit when Cur.Kind /= Tk_Comma;
            Advance;
         end loop;
      end if;
      Expect (Tk_RParen, "')' closing the parameter list");
      Expect (Tk_Arrow, "'->' before the result list");
      declare
         Paren : constant Boolean := Cur.Kind = Tk_LParen;
      begin
         if Paren then
            Advance;
         end if;
         loop
            P.Results.Append (Parse_Decl ('R'));
            exit when Cur.Kind /= Tk_Comma;
            Advance;
         end loop;
         if Paren then
            Expect (Tk_RParen, "')' closing the result list");
         end if;
      end;
      if Cur.Kind not in Tk_NL | Tk_Semi then
         Fail ("expected end of line after the plan header, found " & Describe (Cur));
      end if;
      P.Stmts := Parse_Stmts;
      if not Is_Kw (Cur, "END") then
         Fail ("expected END closing plan " & Label (P) & ", found " & Describe (Cur));
      end if;
      Advance;
      return P;
   end Parse_Plan;

   function Parse (Source : String) return Plan_Vectors.Vector is
      Result : Plan_Vectors.Vector;
   begin
      Toks := Tokenize (Source);
      Pos := 1;
      Src := To_Unbounded_String (Source);
      loop
         while Cur.Kind in Tk_NL | Tk_Semi loop
            Advance;
         end loop;
         exit when Cur.Kind = Tk_EOF;
         Result.Append (Parse_Plan);
      end loop;
      if Result.Is_Empty then
         Error (1, 1, "the program contains no plans");
      end if;
      return Result;
   end Parse;

end PK.Parser;
