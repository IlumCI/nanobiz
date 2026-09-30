with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces; use Interfaces;
with PK.Types; use PK.Types;

package body PK.Codegen is

   use PK.AST;

   LF : constant Character := ASCII.LF;

   package String_Vectors is new Ada.Containers.Vectors (Positive, Unbounded_String);

   function "+" (S : String) return Unbounded_String renames To_Unbounded_String;

   Globals     : Unbounded_String;
   Allocas     : Unbounded_String;
   Inits       : Unbounded_String;
   Code        : Unbounded_String;
   Tmp_Count   : Natural := 0;
   Label_Count : Natural := 0;
   Msg_Count   : Natural := 0;
   Block_Open  : Boolean := False;
   Exit_Stack  : String_Vectors.Vector;   --  exit label of each enclosing loop
   Index_Vars  : String_Vectors.Vector;   --  index slot of each enclosing W1/W2
   Source_File : Unbounded_String;

   I64 : constant Ty := Word (64);

   -------------
   -- Helpers --
   -------------

   function New_Tmp return String is
   begin
      Tmp_Count := @ + 1;
      return "%t" & Img (Tmp_Count);
   end New_Tmp;

   function New_Label return String is
   begin
      Label_Count := @ + 1;
      return "L" & Img (Label_Count);
   end New_Label;

   procedure Start_Block (Name : String) is
   begin
      if Block_Open then
         Append (Code, "  br label %" & Name & LF);
      end if;
      Append (Code, Name & ":" & LF);
      Block_Open := True;
   end Start_Block;

   procedure Emit (S : String) is
   begin
      if not Block_Open then
         Start_Block (New_Label);   --  unreachable code after FIN
      end if;
      Append (Code, "  " & S & LF);
   end Emit;

   procedure Emit_Term (S : String) is
   begin
      Emit (S);
      Block_Open := False;
   end Emit_Term;

   procedure Emit_Alloca (Name, T : String) is
   begin
      Append (Allocas, "  " & Name & " = alloca " & T & LF);
   end Emit_Alloca;

   function Hex2 (N : Natural) return String is
      H : constant String := "0123456789ABCDEF";
   begin
      return H (N / 16 + 1) & H (N mod 16 + 1);
   end Hex2;

   function LLVM_String (Name, Text : String) return String is
      Esc : Unbounded_String;
   begin
      for C of Text loop
         if C in ' ' .. '~' and then C not in '"' | '\' then
            Append (Esc, C);
         else
            Append (Esc, "\" & Hex2 (Character'Pos (C)));
         end if;
      end loop;
      return "@" & Name & " = private unnamed_addr constant ["
        & Img (Text'Length + 1) & " x i8] c""" & To_String (Esc) & "\00""" & LF;
   end LLVM_String;

   function Message (Line, Col : Positive; Text : String) return String is
   begin
      Msg_Count := @ + 1;
      declare
         Name : constant String := "pk.msg." & Img (Msg_Count);
      begin
         Append (Globals, LLVM_String
                   (Name, To_String (Source_File) & ":" & Img (Line) & ":" & Img (Col)
                    & ": " & Text));
         return "@" & Name;
      end;
   end Message;

   procedure Trap_If (Cond : String; Line, Col : Positive; Text : String) is
      Bad : constant String := New_Label;
      Ok  : constant String := New_Label;
   begin
      Emit_Term ("br i1 " & Cond & ", label %" & Bad & ", label %" & Ok);
      Start_Block (Bad);
      Emit ("call void @pk.trap(ptr " & Message (Line, Col, Text) & ")");
      Emit_Term ("unreachable");
      Start_Block (Ok);
   end Trap_If;

   --  An integer constant of the given width, written in the signed form
   --  the LLVM parser accepts for every width.
   function Const (V : Unsigned_64; Width : Positive) return String is
   begin
      if Width >= 64 then
         return (if V >= 2 ** 63 then "-" & Img_U ((not V) + 1) else Img_U (V));
      end if;
      declare
         Full : constant Unsigned_64 := Shift_Left (1, Width);
         M    : constant Unsigned_64 := V and (Full - 1);
      begin
         return (if M >= Full / 2 then "-" & Img_U (Full - M) else Img_U (M));
      end;
   end Const;

   function Max_Of (Width : Positive) return Unsigned_64 is
     (if Width >= 64 then Unsigned_64'Last else Shift_Left (1, Width) - 1);

   function Convert (V : String; From, To : Ty) return String is
   begin
      if From.Width = To.Width then
         return V;
      end if;
      declare
         T : constant String := New_Tmp;
      begin
         Emit (T & " = " & (if From.Width < To.Width then "zext " else "trunc ")
               & LLVM (From) & " " & V & " to " & LLVM (To));
         return T;
      end;
   end Convert;

   function Function_Name (P : Plan) return String is ("@pk." & Label (P));

   ------------
   -- Places --
   ------------

   type Place is record
      Addr    : Unbounded_String;
      Is_Bit  : Boolean := False;
      Bit     : Unbounded_String;   --  i64 bit number when Is_Bit
      Word_Ty : Ty;                 --  word that holds the bit
   end record;

   function Var_Addr (E : Expr) return String is
     (case E.Class is
         when C_V =>
           (if Is_Scalar (E.Base_Ty) then "%V" & Img (E.Index) & ".addr"
            else "%V" & Img (E.Index)),
         when C_Z    => "%Z" & Img (E.Index),
         when C_R    => "%R" & Img (E.Index),
         when C_Loop => To_String (Index_Vars (E.Loop_Depth + 1)));

   function Gen_Value (E : Expr) return String;

   function Gen_Index (Ix : Expr; Bound : Positive) return String is
      W : constant String := Convert (Gen_Value (Ix), Ix.Ty, I64);
   begin
      --  Literal indices were checked statically; narrow index words
      --  cannot exceed the bound.
      if Ix.Kind /= E_Int
        and then not (Ix.Ty.Width < 24 and then 2 ** Ix.Ty.Width <= Bound)
      then
         declare
            C : constant String := New_Tmp;
         begin
            Emit (C & " = icmp uge i64 " & W & ", " & Img (Bound));
            Trap_If (C, Ix.Line, Ix.Col,
                     "component index out of range 0 .. " & Img (Bound - 1));
         end;
      end if;
      return W;
   end Gen_Index;

   function Gen_Place (E : Expr) return Place is
      P      : Place;
      Cur_Ty : Ty := E.Base_Ty;
   begin
      P.Addr := +Var_Addr (E);
      for Ix of E.Indices loop
         if Cur_Ty.Kind = K_Array then
            declare
               I : constant String := Gen_Index (Ix, Cur_Ty.Length);
               T : constant String := New_Tmp;
            begin
               Emit (T & " = getelementptr inbounds " & LLVM (Cur_Ty) & ", ptr "
                     & To_String (P.Addr) & ", i64 0, i64 " & I);
               P.Addr := +T;
               Cur_Ty := Cur_Ty.Elem;
            end;
         else
            P.Is_Bit := True;
            P.Word_Ty := Cur_Ty;
            P.Bit := +Gen_Index (Ix, Cur_Ty.Width);
            Cur_Ty := Word (1);
         end if;
      end loop;
      return P;
   end Gen_Place;

   function Load (P : Place; T : Ty) return String is
      R : constant String := New_Tmp;
   begin
      if not P.Is_Bit then
         Emit (R & " = load " & LLVM (T) & ", ptr " & To_String (P.Addr));
         return R;
      end if;
      declare
         W   : constant String := LLVM (P.Word_Ty);
         Amt : constant String := Convert (To_String (P.Bit), I64, P.Word_Ty);
         Sh  : constant String := New_Tmp;
         Tr  : constant String := New_Tmp;
      begin
         Emit (R & " = load " & W & ", ptr " & To_String (P.Addr));
         Emit (Sh & " = lshr " & W & " " & R & ", " & Amt);
         Emit (Tr & " = trunc " & W & " " & Sh & " to i1");
         return Tr;
      end;
   end Load;

   procedure Store (P : Place; T : Ty; V : String) is
   begin
      if not P.Is_Bit then
         Emit ("store " & LLVM (T) & " " & V & ", ptr " & To_String (P.Addr));
         return;
      end if;
      declare
         W       : constant String := LLVM (P.Word_Ty);
         Amt     : constant String := Convert (To_String (P.Bit), I64, P.Word_Ty);
         Old     : constant String := New_Tmp;
         Mask    : constant String := New_Tmp;
         Inv     : constant String := New_Tmp;
         Cleared : constant String := New_Tmp;
         Ext     : constant String := New_Tmp;
         Shifted : constant String := New_Tmp;
         Merged  : constant String := New_Tmp;
      begin
         Emit (Old & " = load " & W & ", ptr " & To_String (P.Addr));
         Emit (Mask & " = shl " & W & " 1, " & Amt);
         Emit (Inv & " = xor " & W & " " & Mask & ", -1");
         Emit (Cleared & " = and " & W & " " & Old & ", " & Inv);
         Emit (Ext & " = zext i1 " & V & " to " & W);
         Emit (Shifted & " = shl " & W & " " & Ext & ", " & Amt);
         Emit (Merged & " = or " & W & " " & Cleared & ", " & Shifted);
         Emit ("store " & W & " " & Merged & ", ptr " & To_String (P.Addr));
      end;
   end Store;

   -----------------
   -- Expressions --
   -----------------

   function Gen_Call (E : Expr) return String_Vectors.Vector is
      P    : constant Plan := E.Target;
      Args : Unbounded_String;
      Outs : String_Vectors.Vector;

      procedure Add (S : String) is
      begin
         if Length (Args) > 0 then
            Append (Args, ", ");
         end if;
         Append (Args, S);
      end Add;
   begin
      for K in P.Params.First_Index .. P.Params.Last_Index loop
         declare
            A  : constant Expr := E.Args (K);
            PT : constant Ty := P.Params (K).Ty;
         begin
            if Is_Scalar (PT) then
               Add (LLVM (PT) & " " & Convert (Gen_Value (A), A.Ty, PT));
            else
               Add ("ptr " & To_String (Gen_Place (A).Addr));
            end if;
         end;
      end loop;
      for Res of P.Results loop
         declare
            O : constant String := New_Tmp;
         begin
            Emit_Alloca (O, LLVM (Res.Ty));
            Add ("ptr " & O);
            Outs.Append (+O);
         end;
      end loop;
      Emit ("call void " & Function_Name (P) & "(" & To_String (Args) & ")");
      return Outs;
   end Gen_Call;

   function Gen_Binary (E : Expr) return String is
      L : constant String := Convert (Gen_Value (E.Left), E.Left.Ty, E.Op_Ty);
      R : constant String := Convert (Gen_Value (E.Right), E.Right.Ty, E.Op_Ty);
      T : constant String := LLVM (E.Op_Ty);
      X : constant String := New_Tmp;

      procedure Arith (Op : String) is
      begin
         Emit (X & " = " & Op & " " & T & " " & L & ", " & R);
      end Arith;

      procedure Cmp (Pred : String) is
      begin
         Emit (X & " = icmp " & Pred & " " & T & " " & L & ", " & R);
      end Cmp;
   begin
      case E.Bin_Op is
         when Op_Add => Arith ("add");
         when Op_Sub => Arith ("sub");
         when Op_Mul => Arith ("mul");
         when Op_And => Arith ("and");
         when Op_Or  => Arith ("or");
         when Op_Xor => Arith ("xor");
         when Op_Div | Op_Mod =>
            if E.Right.Kind /= E_Int then
               declare
                  Z : constant String := New_Tmp;
               begin
                  Emit (Z & " = icmp eq " & T & " " & R & ", 0");
                  Trap_If (Z, E.Line, E.Col, "division by zero");
               end;
            end if;
            Arith (if E.Bin_Op = Op_Div then "udiv" else "urem");
         when Op_Eq => Cmp ("eq");
         when Op_Ne => Cmp ("ne");
         when Op_Lt => Cmp ("ult");
         when Op_Le => Cmp ("ule");
         when Op_Gt => Cmp ("ugt");
         when Op_Ge => Cmp ("uge");
         when Op_Neg | Op_Not =>
            raise Program_Error;
      end case;
      return X;
   end Gen_Binary;

   function Gen_Value (E : Expr) return String is
   begin
      case E.Kind is
         when E_Int =>
            return Const (E.Value, E.Ty.Width);
         when E_Ref =>
            return Load (Gen_Place (E), E.Ty);
         when E_Unary =>
            declare
               V : constant String := Gen_Value (E.Operand);
               R : constant String := New_Tmp;
               T : constant String := LLVM (E.Ty);
            begin
               if E.Un_Op = Op_Neg then
                  Emit (R & " = sub " & T & " 0, " & V);
               else
                  Emit (R & " = xor " & T & " " & V & ", -1");
               end if;
               return R;
            end;
         when E_Binary =>
            return Gen_Binary (E);
         when E_Call =>
            declare
               Outs : constant String_Vectors.Vector := Gen_Call (E);
            begin
               return Load ((Addr => Outs.First_Element, others => <>), E.Ty);
            end;
      end case;
   end Gen_Value;

   ----------------
   -- Statements --
   ----------------

   procedure Assign (Target : Expr; V : String; From : Ty) is
      P : constant Place := Gen_Place (Target);
   begin
      if Is_Scalar (Target.Ty) then
         Store (P, Target.Ty, Convert (V, From, Target.Ty));
      else
         Store (P, Target.Ty, V);
      end if;
   end Assign;

   procedure Gen_Stmts (V : Stmt_Vectors.Vector);

   procedure Gen_Stmt (S : Stmt) is
   begin
      case S.Kind is
         when S_Assign =>
            if S.Source.Kind = E_Call then
               declare
                  Outs : constant String_Vectors.Vector := Gen_Call (S.Source);
                  P    : constant Plan := S.Source.Target;
               begin
                  for K in S.Targets.First_Index .. S.Targets.Last_Index loop
                     declare
                        RT : constant Ty := P.Results (K).Ty;
                        V  : constant String := Load ((Addr => Outs (K), others => <>), RT);
                     begin
                        Assign (S.Targets (K), V, RT);
                     end;
                  end loop;
               end;
            else
               declare
                  V : constant String := Gen_Value (S.Source);
               begin
                  Assign (S.Targets.First_Element, V, S.Source.Ty);
               end;
            end if;

         when S_Cond =>
            declare
               C    : constant String := Gen_Value (S.Cond);
               Then_L : constant String := New_Label;
               End_L  : constant String := New_Label;
            begin
               Emit_Term ("br i1 " & C & ", label %" & Then_L & ", label %" & End_L);
               Start_Block (Then_L);
               Gen_Stmt (S.Then_Part);
               Start_Block (End_L);
            end;

         when S_Block =>
            Gen_Stmts (S.Stmts);

         when S_Loop =>
            declare
               Head : constant String := New_Label;
               Done : constant String := New_Label;
            begin
               Start_Block (Head);
               Exit_Stack.Append (+Done);
               Gen_Stmts (S.Stmts);
               Emit_Term ("br label %" & Head);
               Exit_Stack.Delete_Last;
               Start_Block (Done);
            end;

         when S_While =>
            declare
               Head : constant String := New_Label;
               Body_L : constant String := New_Label;
               Done : constant String := New_Label;
            begin
               Start_Block (Head);
               declare
                  C : constant String := Gen_Value (S.While_Cond);
               begin
                  Emit_Term ("br i1 " & C & ", label %" & Body_L & ", label %" & Done);
               end;
               Start_Block (Body_L);
               Exit_Stack.Append (+Done);
               Gen_Stmts (S.While_Body);
               Emit_Term ("br label %" & Head);
               Exit_Stack.Delete_Last;
               Start_Block (Done);
            end;

         when S_Count =>
            declare
               N      : constant String := Convert (Gen_Value (S.Count), S.Count.Ty, I64);
               Base   : constant String := New_Tmp;
               K_Slot : constant String := Base & ".k";
               I_Slot : constant String := Base & ".i";
               Head   : constant String := New_Label;
               Body_L : constant String := New_Label;
               Latch  : constant String := New_Label;
               Done   : constant String := New_Label;
               KV     : constant String := New_Tmp;
               C      : constant String := New_Tmp;
            begin
               Emit_Alloca (K_Slot, "i64");
               Emit_Alloca (I_Slot, "i64");
               Emit ("store i64 0, ptr " & K_Slot);
               Start_Block (Head);
               Emit (KV & " = load i64, ptr " & K_Slot);
               Emit (C & " = icmp ult i64 " & KV & ", " & N);
               Emit_Term ("br i1 " & C & ", label %" & Body_L & ", label %" & Done);
               Start_Block (Body_L);
               if S.Down then
                  declare
                     Last : constant String := New_Tmp;
                     IV   : constant String := New_Tmp;
                  begin
                     Emit (Last & " = sub i64 " & N & ", 1");
                     Emit (IV & " = sub i64 " & Last & ", " & KV);
                     Emit ("store i64 " & IV & ", ptr " & I_Slot);
                  end;
               else
                  Emit ("store i64 " & KV & ", ptr " & I_Slot);
               end if;
               Exit_Stack.Append (+Done);
               Index_Vars.Append (+I_Slot);
               Gen_Stmts (S.Count_Body);
               Index_Vars.Delete_Last;
               Exit_Stack.Delete_Last;
               Start_Block (Latch);
               declare
                  K1 : constant String := New_Tmp;
                  K2 : constant String := New_Tmp;
               begin
                  Emit (K1 & " = load i64, ptr " & K_Slot);
                  Emit (K2 & " = add i64 " & K1 & ", 1");
                  Emit ("store i64 " & K2 & ", ptr " & K_Slot);
               end;
               Emit_Term ("br label %" & Head);
               Start_Block (Done);
            end;

         when S_Fin =>
            Emit_Term ("br label %" & To_String (Exit_Stack.Last_Element));
      end case;
   end Gen_Stmt;

   procedure Gen_Stmts (V : Stmt_Vectors.Vector) is
   begin
      for S of V loop
         Gen_Stmt (S);
      end loop;
   end Gen_Stmts;

   ---------------------
   -- Functions/plans --
   ---------------------

   procedure Reset_Function is
   begin
      Allocas := Null_Unbounded_String;
      Inits := Null_Unbounded_String;
      Code := Null_Unbounded_String;
      Block_Open := False;
      Exit_Stack.Clear;
      Index_Vars.Clear;
   end Reset_Function;

   function Assemble (Header : String) return String is
     (Header & " {" & LF & "entry:" & LF & To_String (Allocas) & To_String (Inits)
      & "  br label %body" & LF & To_String (Code) & "}" & LF & LF);

   procedure Local (Name : String; T : Ty) is
   begin
      Emit_Alloca (Name, LLVM (T));
      Append (Inits, "  store " & LLVM (T) & " zeroinitializer, ptr " & Name & LF);
   end Local;

   function Gen_Plan (P : Plan) return String is
      Sig : Unbounded_String;

      procedure Add (S : String) is
      begin
         if Length (Sig) > 0 then
            Append (Sig, ", ");
         end if;
         Append (Sig, S);
      end Add;
   begin
      Reset_Function;
      for X of P.Params loop
         declare
            N : constant String := "%V" & Img (X.Index);
         begin
            if Is_Scalar (X.Ty) then
               Add (LLVM (X.Ty) & " " & N);
               Emit_Alloca (N & ".addr", LLVM (X.Ty));
               Append (Inits, "  store " & LLVM (X.Ty) & " " & N & ", ptr " & N & ".addr" & LF);
            else
               Add ("ptr noalias readonly " & N);
            end if;
         end;
      end loop;
      for X of P.Results loop
         Add ("ptr noalias %out.R" & Img (X.Index));
         Local ("%R" & Img (X.Index), X.Ty);
      end loop;
      for C in P.Z_Vars.Iterate loop
         Local ("%Z" & Img (Ty_Maps.Key (C)), Ty_Maps.Element (C));
      end loop;

      Start_Block ("body");
      Gen_Stmts (P.Stmts);
      for X of P.Results loop
         declare
            V : constant String := New_Tmp;
            T : constant String := LLVM (X.Ty);
         begin
            Emit (V & " = load " & T & ", ptr %R" & Img (X.Index));
            Emit ("store " & T & " " & V & ", ptr %out.R" & Img (X.Index));
         end;
      end loop;
      Emit_Term ("ret void");
      return Assemble ("; plan " & Label (P) & LF
                       & "define internal void " & Function_Name (P) & "("
                       & To_String (Sig) & ")");
   end Gen_Plan;

   procedure Leaf_Paths (T : Ty; Prefix : String; Into : in out String_Vectors.Vector) is
   begin
      if Is_Scalar (T) then
         Into.Append (+Prefix);
      else
         for J in 0 .. T.Length - 1 loop
            Leaf_Paths (T.Elem, Prefix & ", i64 " & Img (J), Into);
         end loop;
      end if;
   end Leaf_Paths;

   function Gen_Main (P : Plan) return String is
      N    : constant Natural := Natural (P.Params.Length);
      Args : Unbounded_String;
      Outs : String_Vectors.Vector;

      procedure Add (S : String) is
      begin
         if Length (Args) > 0 then
            Append (Args, ", ");
         end if;
         Append (Args, S);
      end Add;
   begin
      Reset_Function;
      Start_Block ("body");
      Emit ("%argc.ok = icmp eq i32 %argc, " & Img (N + 1));
      Emit_Term ("br i1 %argc.ok, label %run, label %usage");
      Start_Block ("usage");
      Emit ("%prog = load ptr, ptr %argv");
      Emit ("call void @pk.usage(ptr %prog, i32 " & Img (N) & ")");
      Emit_Term ("unreachable");
      Start_Block ("run");

      for K in P.Params.First_Index .. P.Params.Last_Index loop
         declare
            X     : constant Param := P.Params (K);
            LT    : constant Ty := Leaf (X.Ty);
            Max   : constant String := Const (Max_Of (LT.Width), 64);
            Cur   : constant String := New_Tmp;
            Arg_P : constant String := New_Tmp;
            Arg_V : constant String := New_Tmp;
         begin
            Emit_Alloca (Cur, "ptr");
            Emit (Arg_P & " = getelementptr inbounds ptr, ptr %argv, i64 " & Img (K));
            Emit (Arg_V & " = load ptr, ptr " & Arg_P);
            Emit ("store ptr " & Arg_V & ", ptr " & Cur);
            if Is_Scalar (X.Ty) then
               declare
                  V : constant String := New_Tmp;
               begin
                  Emit (V & " = call i64 @pk.next(ptr " & Cur & ", i64 " & Max & ")");
                  Add (LLVM (X.Ty) & " " & Convert (V, I64, X.Ty));
               end;
            else
               declare
                  Storage : constant String := New_Tmp;
                  Paths   : String_Vectors.Vector;
               begin
                  Emit_Alloca (Storage, LLVM (X.Ty));
                  Leaf_Paths (X.Ty, "", Paths);
                  for Path of Paths loop
                     declare
                        V : constant String := New_Tmp;
                        G : constant String := New_Tmp;
                     begin
                        Emit (V & " = call i64 @pk.next(ptr " & Cur & ", i64 " & Max & ")");
                        Emit (G & " = getelementptr inbounds " & LLVM (X.Ty) & ", ptr "
                              & Storage & ", i64 0" & To_String (Path));
                        Emit ("store " & LLVM (LT) & " " & Convert (V, I64, LT) & ", ptr " & G);
                     end;
                  end loop;
                  Add ("ptr " & Storage);
               end;
            end if;
            Emit ("call void @pk.end(ptr " & Cur & ")");
         end;
      end loop;

      for Res of P.Results loop
         declare
            O : constant String := New_Tmp;
         begin
            Emit_Alloca (O, LLVM (Res.Ty));
            Add ("ptr " & O);
            Outs.Append (+O);
         end;
      end loop;
      Emit ("call void " & Function_Name (P) & "(" & To_String (Args) & ")");

      for K in P.Results.First_Index .. P.Results.Last_Index loop
         declare
            RT    : constant Ty := P.Results (K).Ty;
            LT    : constant Ty := Leaf (RT);
            Paths : String_Vectors.Vector;
            First : Boolean := True;
         begin
            Leaf_Paths (RT, "", Paths);
            for Path of Paths loop
               declare
                  Addr : Unbounded_String := Outs (K);
                  V    : constant String := New_Tmp;
               begin
                  if not First then
                     Emit ("call i32 @putchar(i32 44)");
                  end if;
                  First := False;
                  if not Is_Scalar (RT) then
                     declare
                        G : constant String := New_Tmp;
                     begin
                        Emit (G & " = getelementptr inbounds " & LLVM (RT) & ", ptr "
                              & To_String (Outs (K)) & ", i64 0" & To_String (Path));
                        Addr := +G;
                     end;
                  end if;
                  Emit (V & " = load " & LLVM (LT) & ", ptr " & To_String (Addr));
                  Emit ("call void @pk.print(i64 " & Convert (V, LT, I64) & ")");
               end;
            end loop;
            Emit ("call i32 @putchar(i32 10)");
         end;
      end loop;
      Emit_Term ("ret i32 0");
      return Assemble ("define i32 @main(i32 %argc, ptr %argv)");
   end Gen_Main;

   function Runtime return String is
     ("; runtime support" & LF
      & "declare i64 @strtoull(ptr, ptr, i32)" & LF
      & "declare i32 @printf(ptr, ...)" & LF
      & "declare i32 @dprintf(i32, ptr, ...)" & LF
      & "declare i32 @putchar(i32)" & LF
      & "declare void @exit(i32) noreturn" & LF & LF
      & LLVM_String ("pk.fmt.u64", "%llu")
      & LLVM_String ("pk.fmt.err", "plankalkul runtime error: %s" & LF)
      & LLVM_String ("pk.fmt.usage",
                     "usage: %s <%d argument(s)>; arrays are written as comma-separated values"
                     & LF)
      & LLVM_String ("pk.msg.badnum", "input: invalid or missing number")
      & LLVM_String ("pk.msg.range", "input: value too large for its parameter type")
      & LLVM_String ("pk.msg.extra", "input: too many values for a parameter")
      & LF
      & "define internal void @pk.trap(ptr %msg) cold noinline noreturn {" & LF
      & "  %r = call i32 (i32, ptr, ...) @dprintf(i32 2, ptr @pk.fmt.err, ptr %msg)" & LF
      & "  call void @exit(i32 1)" & LF
      & "  unreachable" & LF
      & "}" & LF & LF
      & "define internal void @pk.usage(ptr %prog, i32 %n) cold noinline noreturn {" & LF
      & "  %r = call i32 (i32, ptr, ...) @dprintf(i32 2, ptr @pk.fmt.usage, ptr %prog, i32 %n)"
      & LF
      & "  call void @exit(i32 2)" & LF
      & "  unreachable" & LF
      & "}" & LF & LF
      & "define internal i64 @pk.next(ptr %cur, i64 %max) {" & LF
      & "entry:" & LF
      & "  %end = alloca ptr" & LF
      & "  %s = load ptr, ptr %cur" & LF
      & "  %c0 = load i8, ptr %s" & LF
      & "  %d0 = sub i8 %c0, 48" & LF
      & "  %digit = icmp ult i8 %d0, 10" & LF
      & "  br i1 %digit, label %parse, label %bad" & LF
      & "parse:" & LF
      & "  %v = call i64 @strtoull(ptr %s, ptr %end, i32 0)" & LF
      & "  %e = load ptr, ptr %end" & LF
      & "  %big = icmp ugt i64 %v, %max" & LF
      & "  br i1 %big, label %range, label %sep" & LF
      & "sep:" & LF
      & "  %c = load i8, ptr %e" & LF
      & "  %comma = icmp eq i8 %c, 44" & LF
      & "  %nul = icmp eq i8 %c, 0" & LF
      & "  %okc = or i1 %comma, %nul" & LF
      & "  br i1 %okc, label %done, label %bad" & LF
      & "done:" & LF
      & "  %e1 = getelementptr inbounds i8, ptr %e, i64 1" & LF
      & "  %n = select i1 %comma, ptr %e1, ptr %e" & LF
      & "  store ptr %n, ptr %cur" & LF
      & "  ret i64 %v" & LF
      & "bad:" & LF
      & "  call void @pk.trap(ptr @pk.msg.badnum)" & LF
      & "  unreachable" & LF
      & "range:" & LF
      & "  call void @pk.trap(ptr @pk.msg.range)" & LF
      & "  unreachable" & LF
      & "}" & LF & LF
      & "define internal void @pk.end(ptr %cur) {" & LF
      & "  %s = load ptr, ptr %cur" & LF
      & "  %c = load i8, ptr %s" & LF
      & "  %more = icmp ne i8 %c, 0" & LF
      & "  br i1 %more, label %bad, label %ok" & LF
      & "bad:" & LF
      & "  call void @pk.trap(ptr @pk.msg.extra)" & LF
      & "  unreachable" & LF
      & "ok:" & LF
      & "  ret void" & LF
      & "}" & LF & LF
      & "define internal void @pk.print(i64 %v) {" & LF
      & "  %r = call i32 (ptr, ...) @printf(ptr @pk.fmt.u64, i64 %v)" & LF
      & "  ret void" & LF
      & "}" & LF);

   function Generate
     (Plans       : Plan_Vectors.Vector;
      Entry_Plan  : Plan;
      Source_Name : String) return String
   is
      Result : Unbounded_String;
   begin
      Globals := Null_Unbounded_String;
      Tmp_Count := 0;
      Label_Count := 0;
      Msg_Count := 0;
      Source_File := +Source_Name;
      Append (Result, "; LLVM IR generated by plankc from " & Source_Name & LF & LF);
      for P of Plans loop
         Append (Result, Gen_Plan (P));
      end loop;
      Append (Result, "; entry point: plan " & Label (Entry_Plan) & LF);
      Append (Result, Gen_Main (Entry_Plan));
      Append (Result, Runtime);
      Append (Result, To_String (Globals));
      return To_String (Result);
   end Generate;

end PK.Codegen;
