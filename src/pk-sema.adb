with Ada.Containers; use type Ada.Containers.Count_Type;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces; use Interfaces;
with PK.Diagnostics; use PK.Diagnostics;
with PK.Types; use PK.Types;

package body PK.Sema is

   use PK.AST;

   All_Plans   : Plan_Vectors.Vector;
   Current     : Plan;
   V_Vars      : Ty_Maps.Map;
   R_Vars      : Ty_Maps.Map;
   Count_Depth : Natural := 0;   --  enclosing W1/W2 loops
   Any_Depth   : Natural := 0;   --  enclosing loops of any kind

   function Find_Plan (Plans : Plan_Vectors.Vector; Name : String) return Plan is
   begin
      for P of Plans loop
         if To_String (P.Name) = Name or else "P" & Img (P.Number) = Name then
            return P;
         end if;
      end loop;
      return null;
   end Find_Plan;

   function Fits (V : Unsigned_64; Width : Positive) return Boolean is
     (Width >= 64 or else V < Shift_Left (1, Width));

   procedure Require_Scalar (T : Ty; At_Expr : Expr; What : String) is
   begin
      if not Is_Scalar (T) then
         Error (At_Expr.Line, At_Expr.Col,
                What & " must be a word, not an array of type " & Image (T));
      end if;
   end Require_Scalar;

   function Check_Expr (E : Expr; Expected : Ty) return Ty;

   procedure Check_Ref (E : Expr; Is_Target : Boolean) is
      Name : constant String := Var_Name (E);
      Base : Ty;
   begin
      case E.Class is
         when C_V =>
            if Is_Target then
               Error (E.Line, E.Col, "input variable " & Name & " is read-only");
            end if;
            if not V_Vars.Contains (E.Index) then
               Error (E.Line, E.Col, Name & " is not a parameter of plan " & Label (Current));
            end if;
            Base := V_Vars (E.Index);
         when C_R =>
            if not R_Vars.Contains (E.Index) then
               Error (E.Line, E.Col, Name & " is not a result of plan " & Label (Current));
            end if;
            Base := R_Vars (E.Index);
         when C_Z =>
            if Current.Z_Vars.Contains (E.Index) then
               Base := Current.Z_Vars (E.Index);
            elsif E.Decl_Annot /= null then
               Base := E.Decl_Annot;
               Current.Z_Vars.Insert (E.Index, Base);
            else
               Error (E.Line, E.Col, Name & " is used before its type is declared (write "
                      & Name & "[:type] at its first use)");
            end if;
         when C_Loop =>
            if Is_Target then
               Error (E.Line, E.Col, "loop index " & Name & " is read-only");
            end if;
            if Count_Depth = 0 then
               Error (E.Line, E.Col, "loop index " & Name & " used outside a W1/W2 loop");
            end if;
            if E.Index < 0 then
               E.Loop_Depth := Count_Depth - 1;
            elsif E.Index >= Count_Depth then
               Error (E.Line, E.Col, "loop index " & Name
                      & " does not name an enclosing W1/W2 loop (outermost is i0)");
            else
               E.Loop_Depth := E.Index;
            end if;
            Base := Word (64);
      end case;

      if E.Decl_Annot /= null and then not Same (E.Decl_Annot, Base) then
         Error (E.Line, E.Col, Name & " has type " & Image (Base)
                & ", annotated as " & Image (E.Decl_Annot));
      end if;
      E.Base_Ty := Base;

      declare
         Cur_Ty : Ty := Base;
      begin
         for K in E.Indices.First_Index .. E.Indices.Last_Index loop
            declare
               Ix    : constant Expr := E.Indices (K);
               It    : constant Ty := Check_Expr (Ix, null);
               Bound : Positive;
            begin
               Require_Scalar (It, Ix, "a component index");
               case Cur_Ty.Kind is
                  when K_Array =>
                     Bound := Cur_Ty.Length;
                     Cur_Ty := Cur_Ty.Elem;
                  when K_Word =>
                     if Cur_Ty.Width = 1 then
                        Error (Ix.Line, Ix.Col, "cannot select a component of a single bit");
                     end if;
                     Bound := Cur_Ty.Width;
                     Cur_Ty := Word (1);
               end case;
               if Ix.Kind = E_Int and then Ix.Value >= Unsigned_64 (Bound) then
                  Error (Ix.Line, Ix.Col, "component index " & Img_U (Ix.Value)
                         & " is outside 0 .. " & Img (Bound - 1));
               end if;
               if E.Index_Annots (K) /= null and then not Same (E.Index_Annots (K), Cur_Ty) then
                  Error (Ix.Line, Ix.Col, "component of " & Name & " has type "
                         & Image (Cur_Ty) & ", annotated as " & Image (E.Index_Annots (K)));
               end if;
            end;
         end loop;
         E.Ty := Cur_Ty;
      end;
   end Check_Ref;

   procedure Check_Call (E : Expr) is
      P : constant Plan := Find_Plan (All_Plans, To_String (E.Callee));
   begin
      if P = null then
         Error (E.Line, E.Col, "no plan named " & To_String (E.Callee));
      end if;
      if E.Args.Length /= P.Params.Length then
         Error (E.Line, E.Col, "plan " & Label (P) & " expects "
                & Img (Natural (P.Params.Length)) & " argument(s), got "
                & Img (Natural (E.Args.Length)));
      end if;
      for K in P.Params.First_Index .. P.Params.Last_Index loop
         declare
            A  : constant Expr := E.Args (K);
            PT : constant Ty := P.Params (K).Ty;
         begin
            if Is_Scalar (PT) then
               declare
                  T : constant Ty := Check_Expr (A, PT);
               begin
                  if not Is_Scalar (T) then
                     Error (A.Line, A.Col, "argument " & Img (K) & " of " & Label (P)
                            & " must have type " & Image (PT) & ", not " & Image (T));
                  end if;
               end;
            else
               if A.Kind /= E_Ref then
                  Error (A.Line, A.Col, "argument " & Img (K) & " of " & Label (P)
                         & " must be a variable of type " & Image (PT));
               end if;
               Check_Ref (A, False);
               if not Same (A.Ty, PT) then
                  Error (A.Line, A.Col, "argument " & Img (K) & " of " & Label (P)
                         & " must have type " & Image (PT) & ", not " & Image (A.Ty));
               end if;
            end if;
         end;
      end loop;
      E.Target := P;
   end Check_Call;

   procedure Check_Binary (E : Expr; Expected : Ty) is
      Pass : constant Ty :=
        (if Expected /= null and then Is_Scalar (Expected)
           and then E.Bin_Op not in Compare_Op
         then Expected else null);
      LT, RT : Ty;
   begin
      --  An untyped literal takes the type of the other operand.
      if E.Left.Kind = E_Int and then E.Right.Kind /= E_Int then
         RT := Check_Expr (E.Right, null);
         Require_Scalar (RT, E.Right, "an operand");
         LT := Check_Expr (E.Left, RT);
      elsif E.Right.Kind = E_Int and then E.Left.Kind /= E_Int then
         LT := Check_Expr (E.Left, null);
         Require_Scalar (LT, E.Left, "an operand");
         RT := Check_Expr (E.Right, LT);
      else
         LT := Check_Expr (E.Left, Pass);
         RT := Check_Expr (E.Right, Pass);
      end if;
      Require_Scalar (LT, E.Left, "an operand");
      Require_Scalar (RT, E.Right, "an operand");
      if E.Bin_Op in Op_Div | Op_Mod and then E.Right.Kind = E_Int and then E.Right.Value = 0 then
         Error (E.Right.Line, E.Right.Col, "division by zero");
      end if;
      E.Op_Ty := Word (Positive'Max (LT.Width, RT.Width));
      E.Ty := (if E.Bin_Op in Compare_Op then Word (1) else E.Op_Ty);
   end Check_Binary;

   function Check_Expr (E : Expr; Expected : Ty) return Ty is
   begin
      case E.Kind is
         when E_Int =>
            if Expected /= null and then Is_Scalar (Expected) then
               if not Fits (E.Value, Expected.Width) then
                  Error (E.Line, E.Col, "literal " & Img_U (E.Value)
                         & " does not fit in type " & Image (Expected));
               end if;
               E.Ty := Expected;
            else
               E.Ty := Word (64);
            end if;
         when E_Ref =>
            Check_Ref (E, False);
         when E_Unary =>
            declare
               T : constant Ty := Check_Expr (E.Operand, Expected);
            begin
               Require_Scalar (T, E.Operand, "an operand");
               E.Ty := T;
            end;
         when E_Binary =>
            Check_Binary (E, Expected);
         when E_Call =>
            Check_Call (E);
            if E.Target.Results.Length /= 1 then
               Error (E.Line, E.Col, "plan " & Label (E.Target) & " yields "
                      & Img (Natural (E.Target.Results.Length))
                      & " results; use it as '" & Label (E.Target)
                      & "(...) -> target, target'");
            end if;
            E.Ty := E.Target.Results.First_Element.Ty;
      end case;
      return E.Ty;
   end Check_Expr;

   procedure Check_Assignable (Src : Ty; Dst : Expr) is
   begin
      if Is_Scalar (Src) and then Is_Scalar (Dst.Ty) then
         return;   --  words are zero-extended or truncated to the target width
      end if;
      if not Same (Src, Dst.Ty) then
         Error (Dst.Line, Dst.Col, "cannot assign a value of type " & Image (Src)
                & " to " & Var_Name (Dst) & " of type " & Image (Dst.Ty));
      end if;
   end Check_Assignable;

   procedure Check_Cond (C : Expr) is
      T : constant Ty := Check_Expr (C, Word (1));
   begin
      if not Same (T, Word (1)) then
         Error (C.Line, C.Col, "a condition must have type 0 (one bit), not " & Image (T));
      end if;
   end Check_Cond;

   procedure Check_Stmts (V : Stmt_Vectors.Vector);

   procedure Check_Stmt (S : Stmt) is
   begin
      case S.Kind is
         when S_Assign =>
            if S.Source.Kind = E_Call then
               Check_Call (S.Source);
               declare
                  P : constant Plan := S.Source.Target;
               begin
                  if S.Targets.Length /= P.Results.Length then
                     Error (S.Line, S.Col, "plan " & Label (P) & " yields "
                            & Img (Natural (P.Results.Length)) & " result(s), but "
                            & Img (Natural (S.Targets.Length)) & " target(s) are given");
                  end if;
                  for K in S.Targets.First_Index .. S.Targets.Last_Index loop
                     Check_Ref (S.Targets (K), True);
                     Check_Assignable (P.Results (K).Ty, S.Targets (K));
                  end loop;
                  S.Source.Ty := P.Results.First_Element.Ty;
               end;
            else
               if S.Targets.Length > 1 then
                  Error (S.Line, S.Col, "several targets require a plan call as the source");
               end if;
               declare
                  Tgt : constant Expr := S.Targets.First_Element;
                  Src : Ty;
               begin
                  if S.Source.Kind = E_Int then
                     Check_Ref (Tgt, True);
                     Src := Check_Expr (S.Source, Tgt.Ty);
                  else
                     Src := Check_Expr (S.Source, null);
                     Check_Ref (Tgt, True);
                  end if;
                  Check_Assignable (Src, Tgt);
               end;
            end if;
         when S_Cond =>
            Check_Cond (S.Cond);
            Check_Stmt (S.Then_Part);
         when S_Block =>
            Check_Stmts (S.Stmts);
         when S_Loop =>
            Any_Depth := @ + 1;
            Check_Stmts (S.Stmts);
            Any_Depth := @ - 1;
         when S_While =>
            Check_Cond (S.While_Cond);
            Any_Depth := @ + 1;
            Check_Stmts (S.While_Body);
            Any_Depth := @ - 1;
         when S_Count =>
            Require_Scalar (Check_Expr (S.Count, null), S.Count, "a repetition count");
            Any_Depth := @ + 1;
            Count_Depth := @ + 1;
            Check_Stmts (S.Count_Body);
            Count_Depth := @ - 1;
            Any_Depth := @ - 1;
         when S_Fin =>
            if Any_Depth = 0 then
               Error (S.Line, S.Col, "FIN outside a W loop");
            end if;
      end case;
   end Check_Stmt;

   procedure Check_Stmts (V : Stmt_Vectors.Vector) is
   begin
      for S of V loop
         Check_Stmt (S);
      end loop;
   end Check_Stmts;

   procedure Check_Plan (P : Plan) is
   begin
      Current := P;
      V_Vars.Clear;
      R_Vars.Clear;
      P.Z_Vars.Clear;
      Count_Depth := 0;
      Any_Depth := 0;
      for X of P.Params loop
         if V_Vars.Contains (X.Index) then
            Error (X.Line, X.Col, "duplicate parameter V" & Img (X.Index));
         end if;
         V_Vars.Insert (X.Index, X.Ty);
      end loop;
      for X of P.Results loop
         if R_Vars.Contains (X.Index) then
            Error (X.Line, X.Col, "duplicate result R" & Img (X.Index));
         end if;
         R_Vars.Insert (X.Index, X.Ty);
      end loop;
      Check_Stmts (P.Stmts);
   end Check_Plan;

   procedure Check (Plans : Plan_Vectors.Vector) is
   begin
      All_Plans := Plans;
      for I in Plans.First_Index .. Plans.Last_Index loop
         for J in I + 1 .. Plans.Last_Index loop
            if Plans (I).Number = Plans (J).Number then
               Error (Plans (J).Line, Plans (J).Col, "plan number P" & Img (Plans (J).Number)
                      & " is already used on line " & Img (Plans (I).Line));
            end if;
            if Length (Plans (J).Name) > 0 and then Plans (I).Name = Plans (J).Name then
               Error (Plans (J).Line, Plans (J).Col, "plan name " & To_String (Plans (J).Name)
                      & " is already used on line " & Img (Plans (I).Line));
            end if;
         end loop;
      end loop;
      for P of Plans loop
         Check_Plan (P);
      end loop;
   end Check;

end PK.Sema;
