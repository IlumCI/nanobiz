with PK.AST;

--  Emits textual LLVM IR (opaque pointers, LLVM 15 or later).
--
--  Every plan becomes an internal function
--     void @pk.<label>(<V params>, ptr %out.R0, ...)
--  where word parameters are passed by value and array parameters by
--  reference (V variables are read-only, so no copy is needed). Results
--  are written through out pointers when the plan finishes. Variables are
--  stack slots; LLVM's mem2reg/SROA passes promote them to SSA registers.
--
--  A C-ABI @main reads the entry plan's parameters from the command line
--  (structures as comma-separated leaf values) and prints each result on
--  a line. A floating-point result is printed with the smallest %g
--  precision (15..17 for binary64, 6..9 for binary32) that reads back to
--  the same value.
package PK.Codegen is

   function Generate
     (Plans       : PK.AST.Plan_Vectors.Vector;
      Entry_Plan  : PK.AST.Plan;
      Source_Name : String;
      Assertions  : Boolean := True) return String;
   --  With Assertions False, ASSERT statements are type-checked but emit
   --  no code.

end PK.Codegen;
