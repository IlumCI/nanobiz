--  Error reporting. The compiler stops at the first error.
package PK.Diagnostics is

   Compile_Error : exception;

   procedure Set_File (Name : String);

   procedure Error (Line, Col : Positive; Msg : String)
     with No_Return;
   --  Report Msg as FILE:LINE:COL and raise Compile_Error.

end PK.Diagnostics;
