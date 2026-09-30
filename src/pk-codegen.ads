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
--  (arrays as comma-separated values) and prints each result on a line.
package PK.Codegen is

   function Generate
     (Plans       : PK.AST.Plan_Vectors.Vector;
      Entry_Plan  : PK.AST.Plan;
      Source_Name : String) return String;

end PK.Codegen;
