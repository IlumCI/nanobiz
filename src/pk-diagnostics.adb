with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

package body PK.Diagnostics is

   File : Unbounded_String;

   procedure Set_File (Name : String) is
   begin
      File := To_Unbounded_String (Name);
   end Set_File;

   procedure Error (Line, Col : Positive; Msg : String) is
   begin
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         To_String (File) & ":" & Img (Line) & ":" & Img (Col)
         & ": error: " & Msg);
      raise Compile_Error;
   end Error;

end PK.Diagnostics;
