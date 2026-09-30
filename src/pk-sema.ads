with PK.AST;

--  Name resolution and type checking. Annotates the AST in place.
package PK.Sema is

   procedure Check (Plans : PK.AST.Plan_Vectors.Vector);

   function Find_Plan
     (Plans : PK.AST.Plan_Vectors.Vector; Name : String) return PK.AST.Plan;
   --  Look up a plan by name or by its label P<n>; null if absent.

end PK.Sema;
