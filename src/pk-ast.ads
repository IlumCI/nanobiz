with Ada.Containers.Vectors;
with Ada.Containers.Ordered_Maps;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces;
with PK.Types;

--  Abstract syntax of Plankalkuel plans (Rechenplaene).
package PK.AST is

   use type PK.Types.Ty;

   --  Variable classes: V input (read-only), Z intermediate, R result,
   --  and the index of a W1/W2 counting loop (i, i0, i1, ...).
   type Var_Class is (C_V, C_Z, C_R, C_Loop);

   type Op_Kind is
     (Op_Add, Op_Sub, Op_Mul, Op_Div, Op_Mod,
      Op_Eq, Op_Ne, Op_Lt, Op_Le, Op_Gt, Op_Ge,
      Op_And, Op_Or, Op_Xor,
      Op_Neg, Op_Not);

   subtype Compare_Op is Op_Kind range Op_Eq .. Op_Ge;

   type Plan_Decl;
   type Plan is access Plan_Decl;

   type Expr_Node;
   type Expr is access Expr_Node;

   package Expr_Vectors is new Ada.Containers.Vectors (Positive, Expr);
   package Ty_Vectors is new Ada.Containers.Vectors (Positive, PK.Types.Ty);

   type Expr_Kind is (E_Int, E_Ref, E_Unary, E_Binary, E_Call);

   type Expr_Node (Kind : Expr_Kind) is record
      Line, Col : Positive := 1;
      Ty        : PK.Types.Ty;                --  set by semantic analysis
      case Kind is
         when E_Int =>
            Value : Interfaces.Unsigned_64 := 0;
         when E_Ref =>
            Class        : Var_Class := C_Z;
            Index        : Integer := 0;       --  -1 for the bare loop index i
            Decl_Annot   : PK.Types.Ty;        --  X[:T]
            Indices      : Expr_Vectors.Vector;
            Index_Annots : Ty_Vectors.Vector;  --  X[k:T], null if absent
            Base_Ty      : PK.Types.Ty;        --  sema: type of the variable
            Loop_Depth   : Natural := 0;       --  sema: C_Loop only
         when E_Unary =>
            Un_Op   : Op_Kind := Op_Neg;
            Operand : Expr;
         when E_Binary =>
            Bin_Op      : Op_Kind := Op_Add;
            Left, Right : Expr;
            Op_Ty       : PK.Types.Ty;         --  sema: common operand type
         when E_Call =>
            Callee : Unbounded_String;
            Args   : Expr_Vectors.Vector;
            Target : Plan;                     --  sema
      end case;
   end record;

   type Stmt_Node;
   type Stmt is access Stmt_Node;

   package Stmt_Vectors is new Ada.Containers.Vectors (Positive, Stmt);

   type Stmt_Kind is
     (S_Assign,   --  Source -> Target {, Target}
      S_Cond,     --  Cond -> statement      (bedingte Anweisung)
      S_Block,    --  [ statements ]
      S_Loop,     --  W [ ... ]              repeat until FIN
      S_While,    --  W (Cond) [ ... ]
      S_Count,    --  W1 (n) [ ... ] / W2 (n) [ ... ]
      S_Fin);     --  FIN                    leave the innermost loop

   type Stmt_Node (Kind : Stmt_Kind) is record
      Line, Col : Positive := 1;
      case Kind is
         when S_Assign =>
            Source  : Expr;
            Targets : Expr_Vectors.Vector;
         when S_Cond =>
            Cond      : Expr;
            Then_Part : Stmt;
         when S_Block | S_Loop =>
            Stmts : Stmt_Vectors.Vector;
         when S_While =>
            While_Cond : Expr;
            While_Body : Stmt_Vectors.Vector;
         when S_Count =>
            Count      : Expr;
            Down       : Boolean := False;
            Count_Body : Stmt_Vectors.Vector;
         when S_Fin =>
            null;
      end case;
   end record;

   type Param is record
      Index     : Natural := 0;
      Ty        : PK.Types.Ty;
      Line, Col : Positive := 1;
   end record;

   package Param_Vectors is new Ada.Containers.Vectors (Positive, Param);
   package Ty_Maps is new Ada.Containers.Ordered_Maps (Natural, PK.Types.Ty);

   type Plan_Decl is record
      Number    : Natural := 0;
      Name      : Unbounded_String;             --  may be empty
      Line, Col : Positive := 1;
      Params    : Param_Vectors.Vector;         --  V variables
      Results   : Param_Vectors.Vector;         --  R variables
      Stmts     : Stmt_Vectors.Vector;
      Z_Vars    : Ty_Maps.Map;                  --  sema
   end record;

   package Plan_Vectors is new Ada.Containers.Vectors (Positive, Plan);

   function Label (P : Plan) return String is
     (if Length (P.Name) > 0 then To_String (P.Name) else "P" & Img (P.Number));

   function Var_Name (E : Expr) return String is
     (case E.Class is
         when C_V    => "V" & Img (E.Index),
         when C_Z    => "Z" & Img (E.Index),
         when C_R    => "R" & Img (E.Index),
         when C_Loop => (if E.Index < 0 then "i" else "i" & Img (E.Index)));

end PK.AST;
