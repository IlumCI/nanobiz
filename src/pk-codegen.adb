with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;
with Interfaces; use Interfaces;
with PK.Types; use PK.Types;

package body PK.Codegen is

   use PK.AST;

   LF : constant Character := ASCII.LF;

   package String_Vectors is new Ada.Containers.Vectors (Positive, Unbounded_String);
   package String_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   function "+" (S : String) return Unbounded_String renames To_Unbounded_String;

   Globals     : Unbounded_String;
   Declares    : String_Sets.Set;         --  intrinsic declarations in use
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
   Checks_On   : Boolean := True;         --  emit ASSERT statements

   U64 : constant Ty := Word (64);
   S64 : constant Ty := Word (64, Signed => True);
   F64 : constant Ty := Float_Ty (64);

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

   function Hex (V : Unsigned_64; Digits_Count : Positive) return String is
      H : constant String := "0123456789ABCDEF";
      R : String (1 .. Digits_Count);
      X : Unsigned_64 := V;
   begin
      for K in reverse R'Range loop
         R (K) := H (Natural (X and 15) + 1);
         X := Shift_Right (X, 4);
      end loop;
      return R;
   end Hex;

   function LLVM_String (Name, Text : String) return String is
      Esc : Unbounded_String;
   begin
      for C of Text loop
         if C in ' ' .. '~' and then C not in '"' | '\' then
            Append (Esc, C);
         else
            Append (Esc, "\" & Hex (Unsigned_64 (Character'Pos (C)), 2));
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

   ---------------
   -- Constants --
   ---------------

   --  An integer constant given as a bit pattern, written in the signed
   --  form the LLVM parser accepts for every width.
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

   function Bits_Of is new Ada.Unchecked_Conversion (Long_Float, Unsigned_64);

   --  LLVM writes float and double constants as the hexadecimal binary64
   --  pattern; a float constant must be exactly representable in binary32.
   function Float_Const (V : Long_Float; T : Ty) return String is
      X : constant Long_Float := (if T.Bits = 32 then Long_Float (Float (V)) else V);
   begin
      return "0x" & Hex (Bits_Of (X), 16);
   end Float_Const;

   function Int_Literal (E : Expr) return String is
   begin
      if Is_Float (E.Ty) then
         declare
            M : constant Long_Float := Long_Float (E.Value);
         begin
            return Float_Const ((if E.Negative then -M else M), E.Ty);
         end;
      end if;
      return Const ((if E.Negative then (not E.Value) + 1 else E.Value), E.Ty.Width);
   end Int_Literal;

   function Max_Of (T : Ty) return Unsigned_64 is
     (if T.Signed then Shift_Left (1, T.Width - 1) - 1
      elsif T.Width >= 64 then Unsigned_64'Last
      else Shift_Left (1, T.Width) - 1);

   function Min_Of (T : Ty) return Unsigned_64 is
     ((not Shift_Left (1, T.Width - 1)) + 1);   --  -2**(w-1) as a 64-bit pattern

   -----------------
   -- Conversions --
   -----------------

   function Float_Suffix (T : Ty) return String is ("f" & Img (T.Bits));

   function Convert (V : String; From, To : Ty) return String is
      T : constant String := New_Tmp;
   begin
      if Is_Int (From) and then Is_Int (To) then
         if From.Width = To.Width then
            return V;
         end if;
         Emit (T & " = "
               & (if From.Width > To.Width then "trunc"
                  elsif From.Signed then "sext" else "zext")
               & " " & LLVM (From) & " " & V & " to " & LLVM (To));
      elsif Is_Int (From) then
         Emit (T & " = " & (if From.Signed then "sitofp" else "uitofp")
               & " " & LLVM (From) & " " & V & " to " & LLVM (To));
      elsif Is_Int (To) then
         --  Saturating conversion: out-of-range values clamp, NaN gives 0.
         declare
            Name : constant String :=
              "llvm.fpto" & (if To.Signed then "si" else "ui") & ".sat."
              & LLVM (To) & "." & Float_Suffix (From);
         begin
            Declares.Include ("declare " & LLVM (To) & " @" & Name & "(" & LLVM (From) & ")");
            Emit (T & " = call " & LLVM (To) & " @" & Name & "(" & LLVM (From) & " " & V & ")");
         end;
      else
         if From.Bits = To.Bits then
            return V;
         end if;
         Emit (T & " = " & (if From.Bits < To.Bits then "fpext" else "fptrunc")
               & " " & LLVM (From) & " " & V & " to " & LLVM (To));
      end if;
      return T;
   end Convert;

   function Function_Name (P : Plan) return String is ("@pk." & Label (P));

   --  Byte size of a type as an LLVM constant expression.
   function Size_Of (T : Ty) return String is
     ("ptrtoint (ptr getelementptr (" & LLVM (T) & ", ptr null, i32 1) to i64)");

   --  Copy a structure. memmove, because source and target may coincide.
   procedure Copy (Dst, Src : String; T : Ty) is
   begin
      Declares.Include ("declare void @llvm.memmove.p0.p0.i64(ptr, ptr, i64, i1)");
      Emit ("call void @llvm.memmove.p0.p0.i64(ptr " & Dst & ", ptr " & Src & ", i64 "
            & Size_Of (T) & ", i1 false)");
   end Copy;

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
      W : constant String := Convert (Gen_Value (Ix), Ix.Ty, (if Ix.Ty.Signed then S64 else U64));
   begin
      --  Literal indices were checked statically; narrow unsigned index
      --  words cannot exceed the bound. A negative signed index becomes a
      --  huge unsigned value and fails the check.
      if Ix.Kind /= E_Int
        and then not (not Ix.Ty.Signed and then Ix.Ty.Width < 24
                      and then 2 ** Ix.Ty.Width <= Bound)
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
         case Cur_Ty.Kind is
            when K_Array =>
               declare
                  I : constant String := Gen_Index (Ix, Cur_Ty.Length);
                  T : constant String := New_Tmp;
               begin
                  Emit (T & " = getelementptr inbounds " & LLVM (Cur_Ty) & ", ptr "
                        & To_String (P.Addr) & ", i64 0, i64 " & I);
                  P.Addr := +T;
                  Cur_Ty := Cur_Ty.Elem;
               end;
            when K_Record =>
               declare
                  K : constant Natural := Natural (Ix.Value);
                  T : constant String := New_Tmp;
               begin
                  Emit (T & " = getelementptr inbounds " & LLVM (Cur_Ty) & ", ptr "
                        & To_String (P.Addr) & ", i32 0, i32 " & Img (K));
                  P.Addr := +T;
                  Cur_Ty := Cur_Ty.Fields (Cur_Ty.Fields'First + K);
               end;
            when K_Word =>
               P.Is_Bit := True;
               P.Word_Ty := Cur_Ty;
               P.Bit := +Gen_Index (Ix, Cur_Ty.Width);
               Cur_Ty := Word (1);
            when K_Float =>
               raise Program_Error;   --  rejected by semantic analysis
         end case;
      end loop;
      return P;
   end Gen_Place;

   function Shift_Amount (P : Place) return String is
     (Convert (To_String (P.Bit), U64, Word (P.Word_Ty.Width)));

   function Load (P : Place; T : Ty) return String is
      R : constant String := New_Tmp;
   begin
      if not P.Is_Bit then
         Emit (R & " = load " & LLVM (T) & ", ptr " & To_String (P.Addr));
         return R;
      end if;
      declare
         W   : constant String := LLVM (P.Word_Ty);
         Amt : constant String := Shift_Amount (P);
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
         Amt     : constant String := Shift_Amount (P);
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
      L  : constant String := Convert (Gen_Value (E.Left), E.Left.Ty, E.Op_Ty);
      R  : constant String := Convert (Gen_Value (E.Right), E.Right.Ty, E.Op_Ty);
      OT : constant Ty := E.Op_Ty;
      T  : constant String := LLVM (OT);
      X  : constant String := New_Tmp;
      Fl : constant Boolean := Is_Float (OT);
      Sg : constant Boolean := Is_Signed (OT);

      procedure Arith (Op : String) is
      begin
         Emit (X & " = " & Op & " " & T & " " & L & ", " & R);
      end Arith;

      procedure Cmp (Int_Pred, Float_Pred : String) is
      begin
         if Fl then
            Emit (X & " = fcmp " & Float_Pred & " " & T & " " & L & ", " & R);
         else
            Emit (X & " = icmp " & Int_Pred & " " & T & " " & L & ", " & R);
         end if;
      end Cmp;

      function S_U (Signed_Op, Unsigned_Op : String) return String is
        (if Sg then Signed_Op else Unsigned_Op);
   begin
      case E.Bin_Op is
         when Op_Add => Arith (if Fl then "fadd" else "add");
         when Op_Sub => Arith (if Fl then "fsub" else "sub");
         when Op_Mul => Arith (if Fl then "fmul" else "mul");
         when Op_And => Arith ("and");
         when Op_Or  => Arith ("or");
         when Op_Xor => Arith ("xor");
         when Op_Div | Op_Mod =>
            if Fl then
               --  IEEE 754 semantics: division by zero gives an infinity or NaN.
               Arith (if E.Bin_Op = Op_Div then "fdiv" else "frem");
            else
               if E.Right.Kind /= E_Int then
                  declare
                     Z : constant String := New_Tmp;
                  begin
                     Emit (Z & " = icmp eq " & T & " " & R & ", 0");
                     Trap_If (Z, E.Line, E.Col, "division by zero");
                  end;
               end if;
               if Sg and then not (E.Right.Kind = E_Int
                                   and then not (E.Right.Negative and then E.Right.Value = 1))
               then
                  declare
                     M1 : constant String := New_Tmp;
                     Mn : constant String := New_Tmp;
                     Ov : constant String := New_Tmp;
                  begin
                     Emit (M1 & " = icmp eq " & T & " " & R & ", -1");
                     Emit (Mn & " = icmp eq " & T & " " & L & ", "
                           & Const (Min_Of (OT), OT.Width));
                     Emit (Ov & " = and i1 " & M1 & ", " & Mn);
                     Trap_If (Ov, E.Line, E.Col, "signed division overflow");
                  end;
               end if;
               Arith (if E.Bin_Op = Op_Div then S_U ("sdiv", "udiv") else S_U ("srem", "urem"));
            end if;
         when Op_Eq => Cmp ("eq", "oeq");
         when Op_Ne => Cmp ("ne", "une");
         when Op_Lt => Cmp (S_U ("slt", "ult"), "olt");
         when Op_Le => Cmp (S_U ("sle", "ule"), "ole");
         when Op_Gt => Cmp (S_U ("sgt", "ugt"), "ogt");
         when Op_Ge => Cmp (S_U ("sge", "uge"), "oge");
         when Op_Neg | Op_Not =>
            raise Program_Error;
      end case;
      return X;
   end Gen_Binary;

   function Gen_Value (E : Expr) return String is
   begin
      case E.Kind is
         when E_Int =>
            return Int_Literal (E);
         when E_Float =>
            return Float_Const (E.Float_Val, E.Ty);
         when E_Ref =>
            return Load (Gen_Place (E), E.Ty);
         when E_Unary =>
            declare
               V : constant String := Gen_Value (E.Operand);
               R : constant String := New_Tmp;
               T : constant String := LLVM (E.Ty);
            begin
               if E.Un_Op = Op_Neg then
                  if Is_Float (E.Ty) then
                     Emit (R & " = fneg " & T & " " & V);
                  else
                     Emit (R & " = sub " & T & " 0, " & V);
                  end if;
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
      Store (P, Target.Ty, Convert (V, From, Target.Ty));
   end Assign;

   --  Structure assignment from the storage at Src.
   procedure Assign_Structure (Target : Expr; Src : String) is
      P : constant Place := Gen_Place (Target);
   begin
      Copy (To_String (P.Addr), Src, Target.Ty);
   end Assign_Structure;

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
                     begin
                        if Is_Scalar (RT) then
                           Assign (S.Targets (K),
                                   Load ((Addr => Outs (K), others => <>), RT), RT);
                        else
                           Assign_Structure (S.Targets (K), To_String (Outs (K)));
                        end if;
                     end;
                  end loop;
               end;
            elsif not Is_Scalar (S.Source.Ty) then
               Assign_Structure (S.Targets.First_Element,
                                 To_String (Gen_Place (S.Source).Addr));
            else
               declare
                  V : constant String := Gen_Value (S.Source);
               begin
                  Assign (S.Targets.First_Element, V, S.Source.Ty);
               end;
            end if;

         when S_Cond =>
            declare
               C      : constant String := Gen_Value (S.Cond);
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
               Head   : constant String := New_Label;
               Body_L : constant String := New_Label;
               Done   : constant String := New_Label;
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
               Sg     : constant Boolean := S.Count.Ty.Signed;
               N      : constant String :=
                 Convert (Gen_Value (S.Count), S.Count.Ty, (if Sg then S64 else U64));
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
               --  A negative signed count repeats zero times.
               Emit (C & " = icmp " & (if Sg then "slt" else "ult") & " i64 " & KV & ", " & N);
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

         when S_Assert =>
            if Checks_On then
               declare
                  C : constant String := Gen_Value (S.Assert_Cond);
                  N : constant String := New_Tmp;
               begin
                  Emit (N & " = xor i1 " & C & ", true");
                  Trap_If (N, S.Line, S.Col,
                           "assertion failed: " & To_String (S.Assert_Text));
               end;
            end if;
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
      if Is_Scalar (T) then
         Append (Inits, "  store " & LLVM (T) & " zeroinitializer, ptr " & Name & LF);
      else
         Declares.Include ("declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)");
         Append (Inits, "  call void @llvm.memset.p0.i64(ptr " & Name & ", i8 0, i64 "
                 & Size_Of (T) & ", i1 false)" & LF);
      end if;
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
         if Is_Scalar (X.Ty) then
            declare
               V : constant String := New_Tmp;
               T : constant String := LLVM (X.Ty);
            begin
               Emit (V & " = load " & T & ", ptr %R" & Img (X.Index));
               Emit ("store " & T & " " & V & ", ptr %out.R" & Img (X.Index));
            end;
         else
            Copy ("%out.R" & Img (X.Index), "%R" & Img (X.Index), X.Ty);
         end if;
      end loop;
      Emit_Term ("ret void");
      return Assemble ("; plan " & Label (P) & LF
                       & "define internal void " & Function_Name (P) & "("
                       & To_String (Sig) & ")");
   end Gen_Plan;

   ---------------------
   -- Main and I/O    --
   ---------------------

   --  Read the next comma-separated value for a leaf of type T.
   function Read_Leaf (Cur : String; T : Ty) return String is
      V : constant String := New_Tmp;
   begin
      if Is_Float (T) then
         Emit (V & " = call double @pk.next_f(ptr " & Cur & ")");
         return Convert (V, F64, T);
      elsif T.Signed then
         Emit (V & " = call i64 @pk.next_s(ptr " & Cur & ", i64 " & Const (Min_Of (T), 64)
               & ", i64 " & Const (Max_Of (T), 64) & ")");
         return Convert (V, S64, T);
      else
         Emit (V & " = call i64 @pk.next(ptr " & Cur & ", i64 " & Const (Max_Of (T), 64) & ")");
         return Convert (V, U64, T);
      end if;
   end Read_Leaf;

   procedure Print_Leaf (V : String; T : Ty) is
   begin
      if Is_Float (T) then
         Emit ("call void @pk.print_f" & Img (T.Bits) & "(" & LLVM (T) & " " & V & ")");
      elsif T.Signed then
         Emit ("call void @pk.print_s(i64 " & Convert (V, T, S64) & ")");
      else
         Emit ("call void @pk.print(i64 " & Convert (V, T, U64) & ")");
      end if;
   end Print_Leaf;

   --  Emit a counted loop over 0 .. Length - 1; Each receives the i64 index.
   procedure For_Each (Length : Positive; Each : not null access procedure (Index : String)) is
      Slot : constant String := New_Tmp;
      Head : constant String := New_Label;
      Body_L : constant String := New_Label;
      Done : constant String := New_Label;
      IV   : constant String := New_Tmp;
      C    : constant String := New_Tmp;
      Next : constant String := New_Tmp;
   begin
      Emit_Alloca (Slot, "i64");
      Emit ("store i64 0, ptr " & Slot);
      Start_Block (Head);
      Emit (IV & " = load i64, ptr " & Slot);
      Emit (C & " = icmp ult i64 " & IV & ", " & Img (Length));
      Emit_Term ("br i1 " & C & ", label %" & Body_L & ", label %" & Done);
      Start_Block (Body_L);
      Each (IV);
      Emit (Next & " = add i64 " & IV & ", 1");
      Emit ("store i64 " & Next & ", ptr " & Slot);
      Emit_Term ("br label %" & Head);
      Start_Block (Done);
   end For_Each;

   --  Read the comma- or blank-separated leaves of a structure of type T
   --  into the storage at Addr.
   procedure Read_Into (T : Ty; Addr, Cur : String) is
   begin
      case T.Kind is
         when K_Word | K_Float =>
            Emit ("store " & LLVM (T) & " " & Read_Leaf (Cur, T) & ", ptr " & Addr);
         when K_Record =>
            for J in T.Fields'Range loop
               declare
                  G : constant String := New_Tmp;
               begin
                  Emit (G & " = getelementptr inbounds " & LLVM (T) & ", ptr " & Addr
                        & ", i32 0, i32 " & Img (J - T.Fields'First));
                  Read_Into (T.Fields (J), G, Cur);
               end;
            end loop;
         when K_Array =>
            declare
               procedure Element (Index : String) is
                  G : constant String := New_Tmp;
               begin
                  Emit (G & " = getelementptr inbounds " & LLVM (T) & ", ptr " & Addr
                        & ", i64 0, i64 " & Index);
                  Read_Into (T.Elem, G, Cur);
               end Element;
            begin
               For_Each (T.Length, Element'Access);
            end;
      end case;
   end Read_Into;

   --  Print the leaves of the structure at Addr, comma-separated; Flag is
   --  an i1 slot that is true before the first leaf of a result.
   procedure Print_From (T : Ty; Addr, Flag : String) is
   begin
      case T.Kind is
         when K_Word | K_Float =>
            declare
               V : constant String := New_Tmp;
            begin
               Emit ("call void @pk.comma(ptr " & Flag & ")");
               Emit (V & " = load " & LLVM (T) & ", ptr " & Addr);
               Print_Leaf (V, T);
            end;
         when K_Record =>
            for J in T.Fields'Range loop
               declare
                  G : constant String := New_Tmp;
               begin
                  Emit (G & " = getelementptr inbounds " & LLVM (T) & ", ptr " & Addr
                        & ", i32 0, i32 " & Img (J - T.Fields'First));
                  Print_From (T.Fields (J), G, Flag);
               end;
            end loop;
         when K_Array =>
            declare
               procedure Element (Index : String) is
                  G : constant String := New_Tmp;
               begin
                  Emit (G & " = getelementptr inbounds " & LLVM (T) & ", ptr " & Addr
                        & ", i64 0, i64 " & Index);
                  Print_From (T.Elem, G, Flag);
               end Element;
            begin
               For_Each (T.Length, Element'Access);
            end;
      end case;
   end Print_From;

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
            Cur   : constant String := New_Tmp;
            Arg_P : constant String := New_Tmp;
            Arg_V : constant String := New_Tmp;
            Text  : constant String := New_Tmp;
         begin
            Emit_Alloca (Cur, "ptr");
            Emit (Arg_P & " = getelementptr inbounds ptr, ptr %argv, i64 " & Img (K));
            Emit (Arg_V & " = load ptr, ptr " & Arg_P);
            Emit (Text & " = call ptr @pk.arg(ptr " & Arg_V & ")");
            Emit ("store ptr " & Text & ", ptr " & Cur);
            if Is_Scalar (X.Ty) then
               Add (LLVM (X.Ty) & " " & Read_Leaf (Cur, X.Ty));
            else
               declare
                  Storage : constant String := New_Tmp;
               begin
                  Emit_Alloca (Storage, LLVM (X.Ty));
                  Read_Into (X.Ty, Storage, Cur);
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
            Flag : constant String := New_Tmp;
         begin
            Emit_Alloca (Flag, "i1");
            Emit ("store i1 true, ptr " & Flag);
            Print_From (P.Results (K).Ty, To_String (Outs (K)), Flag);
            Emit ("call i32 @putchar(i32 10)");
         end;
      end loop;
      Emit_Term ("ret i32 0");
      return Assemble ("define i32 @main(i32 %argc, ptr %argv)");
   end Gen_Main;

   function Runtime return String is
     ("; runtime support" & LF
      & "declare i64 @strtoull(ptr, ptr, i32)" & LF
      & "declare i64 @strtoll(ptr, ptr, i32)" & LF
      & "declare double @strtod(ptr, ptr)" & LF
      & "declare i32 @printf(ptr, ...)" & LF
      & "declare i32 @snprintf(ptr, i64, ptr, ...)" & LF
      & "declare i32 @dprintf(i32, ptr, ...)" & LF
      & "declare i32 @putchar(i32)" & LF
      & "declare void @exit(i32) noreturn" & LF
      & "declare ptr @fopen(ptr, ptr)" & LF
      & "declare i32 @fseek(ptr, i64, i32)" & LF
      & "declare i64 @ftell(ptr)" & LF
      & "declare i64 @fread(ptr, i64, i64, ptr)" & LF
      & "declare i32 @fclose(ptr)" & LF
      & "declare ptr @malloc(i64)" & LF & LF
      & LLVM_String ("pk.fmt.u64", "%llu")
      & LLVM_String ("pk.fmt.i64", "%lld")
      & LLVM_String ("pk.fmt.g", "%.*g")
      & LLVM_String ("pk.fmt.s", "%s")
      & LLVM_String ("pk.fmt.err", "plankalkul runtime error: %s" & LF)
      & LLVM_String ("pk.fmt.usage",
                     "usage: %s <%d argument(s)>; structures are written as comma-separated values"
                     & LF)
      & LLVM_String ("pk.msg.badnum", "input: invalid or missing number")
      & LLVM_String ("pk.msg.range", "input: value out of range for its parameter type")
      & LLVM_String ("pk.msg.extra", "input: too many values for a parameter")
      & LLVM_String ("pk.msg.file", "input: cannot read the file named by an @ argument")
      & LLVM_String ("pk.fmt.rb", "rb")
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
      --  An argument "@FILE" stands for the contents of FILE.
      & "define internal ptr @pk.arg(ptr %s) {" & LF
      & "entry:" & LF
      & "  %c = load i8, ptr %s" & LF
      & "  %at = icmp eq i8 %c, 64" & LF
      & "  br i1 %at, label %file, label %plain" & LF
      & "plain:" & LF
      & "  ret ptr %s" & LF
      & "file:" & LF
      & "  %name = getelementptr inbounds i8, ptr %s, i64 1" & LF
      & "  %f = call ptr @fopen(ptr %name, ptr @pk.fmt.rb)" & LF
      & "  %nf = icmp eq ptr %f, null" & LF
      & "  br i1 %nf, label %bad, label %open" & LF
      & "open:" & LF
      & "  %r0 = call i32 @fseek(ptr %f, i64 0, i32 2)" & LF
      & "  %n = call i64 @ftell(ptr %f)" & LF
      & "  %neg = icmp slt i64 %n, 0" & LF
      & "  br i1 %neg, label %bad, label %size" & LF
      & "size:" & LF
      & "  %r1 = call i32 @fseek(ptr %f, i64 0, i32 0)" & LF
      & "  %n1 = add i64 %n, 1" & LF
      & "  %buf = call ptr @malloc(i64 %n1)" & LF
      & "  %nb = icmp eq ptr %buf, null" & LF
      & "  br i1 %nb, label %bad, label %read" & LF
      & "read:" & LF
      & "  %got = call i64 @fread(ptr %buf, i64 1, i64 %n, ptr %f)" & LF
      & "  %r2 = call i32 @fclose(ptr %f)" & LF
      & "  %e = getelementptr inbounds i8, ptr %buf, i64 %got" & LF
      & "  store i8 0, ptr %e" & LF
      & "  ret ptr %buf" & LF
      & "bad:" & LF
      & "  call void @pk.trap(ptr @pk.msg.file)" & LF
      & "  unreachable" & LF
      & "}" & LF & LF
      --  Skip blanks (space, tab, CR, LF) before a value.
      & "define internal void @pk.skip(ptr %cur) {" & LF
      & "entry:" & LF
      & "  br label %loop" & LF
      & "loop:" & LF
      & "  %s = load ptr, ptr %cur" & LF
      & "  %c = load i8, ptr %s" & LF
      & "  %sp = icmp eq i8 %c, 32" & LF
      & "  %ctl = icmp ult i8 %c, 32" & LF
      & "  %nz = icmp ne i8 %c, 0" & LF
      & "  %ctlnz = and i1 %ctl, %nz" & LF
      & "  %blank = or i1 %sp, %ctlnz" & LF
      & "  br i1 %blank, label %adv, label %done" & LF
      & "adv:" & LF
      & "  %s1 = getelementptr inbounds i8, ptr %s, i64 1" & LF
      & "  store ptr %s1, ptr %cur" & LF
      & "  br label %loop" & LF
      & "done:" & LF
      & "  ret void" & LF
      & "}" & LF & LF
      --  After a number: a comma is consumed; a blank or the end is left.
      & "define internal void @pk.sep(ptr %cur, ptr %e) {" & LF
      & "entry:" & LF
      & "  %c = load i8, ptr %e" & LF
      & "  %comma = icmp eq i8 %c, 44" & LF
      & "  %ctl = icmp ule i8 %c, 32" & LF
      & "  %okc = or i1 %comma, %ctl" & LF
      & "  br i1 %okc, label %done, label %bad" & LF
      & "done:" & LF
      & "  %e1 = getelementptr inbounds i8, ptr %e, i64 1" & LF
      & "  %n = select i1 %comma, ptr %e1, ptr %e" & LF
      & "  store ptr %n, ptr %cur" & LF
      & "  ret void" & LF
      & "bad:" & LF
      & "  call void @pk.trap(ptr @pk.msg.badnum)" & LF
      & "  unreachable" & LF
      & "}" & LF & LF
      --  Print a comma before every leaf of a result except the first.
      & "define internal void @pk.comma(ptr %first) {" & LF
      & "entry:" & LF
      & "  %f = load i1, ptr %first" & LF
      & "  store i1 false, ptr %first" & LF
      & "  br i1 %f, label %done, label %put" & LF
      & "put:" & LF
      & "  %r = call i32 @putchar(i32 44)" & LF
      & "  br label %done" & LF
      & "done:" & LF
      & "  ret void" & LF
      & "}" & LF & LF
      & "define internal i64 @pk.next(ptr %cur, i64 %max) {" & LF
      & "entry:" & LF
      & "  %end = alloca ptr" & LF
      & "  call void @pk.skip(ptr %cur)" & LF
      & "  %s = load ptr, ptr %cur" & LF
      & "  %c0 = load i8, ptr %s" & LF
      & "  %d0 = sub i8 %c0, 48" & LF
      & "  %digit = icmp ult i8 %d0, 10" & LF
      & "  br i1 %digit, label %parse, label %bad" & LF
      & "parse:" & LF
      & "  %v = call i64 @strtoull(ptr %s, ptr %end, i32 0)" & LF
      & "  %e = load ptr, ptr %end" & LF
      & "  %big = icmp ugt i64 %v, %max" & LF
      & "  br i1 %big, label %range, label %ok" & LF
      & "ok:" & LF
      & "  call void @pk.sep(ptr %cur, ptr %e)" & LF
      & "  ret i64 %v" & LF
      & "bad:" & LF
      & "  call void @pk.trap(ptr @pk.msg.badnum)" & LF
      & "  unreachable" & LF
      & "range:" & LF
      & "  call void @pk.trap(ptr @pk.msg.range)" & LF
      & "  unreachable" & LF
      & "}" & LF & LF
      & "define internal i64 @pk.next_s(ptr %cur, i64 %min, i64 %max) {" & LF
      & "entry:" & LF
      & "  %end = alloca ptr" & LF
      & "  call void @pk.skip(ptr %cur)" & LF
      & "  %s = load ptr, ptr %cur" & LF
      & "  %c0 = load i8, ptr %s" & LF
      & "  %minus = icmp eq i8 %c0, 45" & LF
      & "  %s1 = getelementptr inbounds i8, ptr %s, i64 1" & LF
      & "  %ds = select i1 %minus, ptr %s1, ptr %s" & LF
      & "  %c1 = load i8, ptr %ds" & LF
      & "  %d1 = sub i8 %c1, 48" & LF
      & "  %digit = icmp ult i8 %d1, 10" & LF
      & "  br i1 %digit, label %parse, label %bad" & LF
      & "parse:" & LF
      & "  %v = call i64 @strtoll(ptr %s, ptr %end, i32 0)" & LF
      & "  %e = load ptr, ptr %end" & LF
      & "  %lo = icmp slt i64 %v, %min" & LF
      & "  %hi = icmp sgt i64 %v, %max" & LF
      & "  %out = or i1 %lo, %hi" & LF
      & "  br i1 %out, label %range, label %ok" & LF
      & "ok:" & LF
      & "  call void @pk.sep(ptr %cur, ptr %e)" & LF
      & "  ret i64 %v" & LF
      & "bad:" & LF
      & "  call void @pk.trap(ptr @pk.msg.badnum)" & LF
      & "  unreachable" & LF
      & "range:" & LF
      & "  call void @pk.trap(ptr @pk.msg.range)" & LF
      & "  unreachable" & LF
      & "}" & LF & LF
      & "define internal double @pk.next_f(ptr %cur) {" & LF
      & "entry:" & LF
      & "  %end = alloca ptr" & LF
      & "  call void @pk.skip(ptr %cur)" & LF
      & "  %s = load ptr, ptr %cur" & LF
      & "  %c0 = load i8, ptr %s" & LF
      & "  %blank = icmp ule i8 %c0, 32" & LF
      & "  br i1 %blank, label %bad, label %parse" & LF
      & "parse:" & LF
      & "  %v = call double @strtod(ptr %s, ptr %end)" & LF
      & "  %e = load ptr, ptr %end" & LF
      & "  %none = icmp eq ptr %e, %s" & LF
      & "  br i1 %none, label %bad, label %ok" & LF
      & "ok:" & LF
      & "  call void @pk.sep(ptr %cur, ptr %e)" & LF
      & "  ret double %v" & LF
      & "bad:" & LF
      & "  call void @pk.trap(ptr @pk.msg.badnum)" & LF
      & "  unreachable" & LF
      & "}" & LF & LF
      & "define internal void @pk.end(ptr %cur) {" & LF
      & "  call void @pk.skip(ptr %cur)" & LF
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
      & "}" & LF & LF
      & "define internal void @pk.print_s(i64 %v) {" & LF
      & "  %r = call i32 (ptr, ...) @printf(ptr @pk.fmt.i64, i64 %v)" & LF
      & "  ret void" & LF
      & "}" & LF & LF
      --  Print with the smallest %.*g precision (15..17 for binary64,
      --  6..9 for binary32) that reads back to the same value.
      & "define internal void @pk.print_f64(double %v) {" & LF
      & "entry:" & LF
      & "  %buf = alloca [40 x i8]" & LF
      & "  br label %try" & LF
      & "try:" & LF
      & "  %p = phi i32 [ 15, %entry ], [ %p1, %next ]" & LF
      & "  %r1 = call i32 (ptr, i64, ptr, ...) @snprintf(ptr %buf, i64 40, ptr @pk.fmt.g, "
      & "i32 %p, double %v)" & LF
      & "  %back = call double @strtod(ptr %buf, ptr null)" & LF
      & "  %same = fcmp oeq double %back, %v" & LF
      & "  %last = icmp uge i32 %p, 17" & LF
      & "  %stop = or i1 %same, %last" & LF
      & "  br i1 %stop, label %out, label %next" & LF
      & "next:" & LF
      & "  %p1 = add i32 %p, 1" & LF
      & "  br label %try" & LF
      & "out:" & LF
      & "  %r3 = call i32 (ptr, ...) @printf(ptr @pk.fmt.s, ptr %buf)" & LF
      & "  ret void" & LF
      & "}" & LF & LF
      & "define internal void @pk.print_f32(float %f) {" & LF
      & "entry:" & LF
      & "  %buf = alloca [40 x i8]" & LF
      & "  %v = fpext float %f to double" & LF
      & "  br label %try" & LF
      & "try:" & LF
      & "  %p = phi i32 [ 6, %entry ], [ %p1, %next ]" & LF
      & "  %r1 = call i32 (ptr, i64, ptr, ...) @snprintf(ptr %buf, i64 40, ptr @pk.fmt.g, "
      & "i32 %p, double %v)" & LF
      & "  %back = call double @strtod(ptr %buf, ptr null)" & LF
      & "  %back32 = fptrunc double %back to float" & LF
      & "  %same = fcmp oeq float %back32, %f" & LF
      & "  %last = icmp uge i32 %p, 9" & LF
      & "  %stop = or i1 %same, %last" & LF
      & "  br i1 %stop, label %out, label %next" & LF
      & "next:" & LF
      & "  %p1 = add i32 %p, 1" & LF
      & "  br label %try" & LF
      & "out:" & LF
      & "  %r3 = call i32 (ptr, ...) @printf(ptr @pk.fmt.s, ptr %buf)" & LF
      & "  ret void" & LF
      & "}" & LF);

   function Generate
     (Plans       : Plan_Vectors.Vector;
      Entry_Plan  : Plan;
      Source_Name : String;
      Assertions  : Boolean := True) return String
   is
      Result : Unbounded_String;
   begin
      Globals := Null_Unbounded_String;
      Declares.Clear;
      Tmp_Count := 0;
      Label_Count := 0;
      Msg_Count := 0;
      Checks_On := Assertions;
      Source_File := +Source_Name;
      Append (Result, "; LLVM IR generated by plankc from " & Source_Name & LF & LF);
      for P of Plans loop
         Append (Result, Gen_Plan (P));
      end loop;
      Append (Result, "; entry point: plan " & Label (Entry_Plan) & LF);
      Append (Result, Gen_Main (Entry_Plan));
      Append (Result, Runtime);
      for D of Declares loop
         Append (Result, D & LF);
      end loop;
      Append (Result, To_String (Globals));
      return To_String (Result);
   end Generate;

end PK.Codegen;
