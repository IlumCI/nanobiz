with Ada.Command_Line; use Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO; use Ada.Text_IO;
with GNAT.OS_Lib;
with PK.AST; use type PK.AST.Plan;
with PK.Codegen;
with PK.Diagnostics;
with PK.Parser;
with PK.Sema;
with PK.Twodim;

--  plankc: Plankalkuel compiler driver.
procedure Plankc is

   Version : constant String := "plankc 0.2.0";

   Input      : Unbounded_String;
   Output     : Unbounded_String;
   Entry_Name : Unbounded_String;
   Clang      : Unbounded_String := To_Unbounded_String ("clang");
   Opt_Level  : Unbounded_String := To_Unbounded_String ("-O2");
   Emit_IR    : Boolean := False;
   Keep_IR    : Boolean := False;
   Assertions : Boolean := True;
   Linear     : Boolean := False;

   Usage_Error : exception;

   procedure Usage is
   begin
      Put_Line ("usage: plankc [options] FILE.pk");
      Put_Line ("  -o FILE         output file (default: FILE without .pk, or FILE.ll with -S)");
      Put_Line ("  -S, --emit-llvm write LLVM IR instead of building an executable");
      Put_Line ("  --entry NAME    plan to run from main (default: the first plan)");
      Put_Line ("  -O0 .. -O3      optimisation level passed to clang (default -O2)");
      Put_Line ("  --clang PATH    clang executable used to build (default: clang on PATH)");
      Put_Line ("  --keep-ll       keep the intermediate .ll file when building");
      Put_Line ("  --no-assertions type-check ASSERT statements but do not execute them");
      Put_Line ("  --linear        print the source translated to linear notation and stop");
      Put_Line ("  --version       print version");
   end Usage;

   function Read_File (Name : String) return String is
      package SIO renames Ada.Streams.Stream_IO;
      F : SIO.File_Type;
   begin
      SIO.Open (F, SIO.In_File, Name);
      declare
         S : String (1 .. Natural (SIO.Size (F)));
      begin
         String'Read (SIO.Stream (F), S);
         SIO.Close (F);
         return S;
      end;
   end Read_File;

   procedure Write_File (Name, Content : String) is
      package SIO renames Ada.Streams.Stream_IO;
      F : SIO.File_Type;
   begin
      SIO.Create (F, SIO.Out_File, Name);
      String'Write (SIO.Stream (F), Content);
      SIO.Close (F);
   end Write_File;

   function Strip_Ext (Name : String) return String is
     (if Name'Length > 3 and then Name (Name'Last - 2 .. Name'Last) = ".pk"
      then Name (Name'First .. Name'Last - 3) else Name & ".out");

   procedure Parse_Args is
      K : Positive := 1;

      function Next return String is
      begin
         if K >= Argument_Count then
            Put_Line (Standard_Error, "plankc: option " & Argument (K) & " needs a value");
            raise Usage_Error;
         end if;
         K := @ + 1;
         return Argument (K);
      end Next;
   begin
      while K <= Argument_Count loop
         declare
            A : constant String := Argument (K);
         begin
            if A = "-h" or else A = "--help" then
               Usage;
               Set_Exit_Status (Success);
               raise Usage_Error;
            elsif A = "--version" then
               Put_Line (Version);
               raise Usage_Error;
            elsif A = "-o" then
               Output := To_Unbounded_String (Next);
            elsif A = "-S" or else A = "--emit-llvm" then
               Emit_IR := True;
            elsif A = "--entry" then
               Entry_Name := To_Unbounded_String (Next);
            elsif A = "--clang" then
               Clang := To_Unbounded_String (Next);
            elsif A = "--keep-ll" then
               Keep_IR := True;
            elsif A = "--no-assertions" then
               Assertions := False;
            elsif A = "--linear" then
               Linear := True;
            elsif A in "-O0" | "-O1" | "-O2" | "-O3" then
               Opt_Level := To_Unbounded_String (A);
            elsif A'Length > 1 and then A (A'First) = '-' then
               Put_Line (Standard_Error, "plankc: unknown option " & A);
               raise Usage_Error;
            elsif Length (Input) > 0 then
               Put_Line (Standard_Error, "plankc: only one input file is accepted");
               raise Usage_Error;
            else
               Input := To_Unbounded_String (A);
            end if;
         end;
         K := @ + 1;
      end loop;
      if Length (Input) = 0 then
         Usage;
         Set_Exit_Status (Failure);
         raise Usage_Error;
      end if;
   end Parse_Args;

   function Build (IR_File, Exe : String) return Boolean is
      use GNAT.OS_Lib;
      Prog : GNAT.OS_Lib.String_Access := Locate_Exec_On_Path (To_String (Clang));
   begin
      if Prog = null then
         Put_Line (Standard_Error, "plankc: " & To_String (Clang)
                   & " not found; use -S to emit LLVM IR only");
         return False;
      end if;
      declare
         Args : Argument_List :=
           [new String'(To_String (Opt_Level)),
            new String'("-Wno-override-module"),
            new String'(IR_File),
            new String'("-o"),
            new String'(Exe)];
         Code : constant Integer := Spawn (Prog.all, Args);
      begin
         for A of Args loop
            Free (A);
         end loop;
         Free (Prog);
         return Code = 0;
      end;
   end Build;

begin
   Set_Exit_Status (Failure);
   Parse_Args;

   declare
      Name   : constant String := To_String (Input);
      Raw    : constant String := Read_File (Name);
      Plans  : PK.AST.Plan_Vectors.Vector;
      Main   : PK.AST.Plan;
   begin
      PK.Diagnostics.Set_File (Name);
      declare
         Source : constant String := PK.Twodim.Translate (Raw);
      begin
         if Linear then
            Put (Source);
            Set_Exit_Status (Success);
            return;
         end if;
         Plans := PK.Parser.Parse (Source);
      end;
      PK.Sema.Check (Plans);

      if Length (Entry_Name) = 0 then
         Main := Plans.First_Element;
      else
         Main := PK.Sema.Find_Plan (Plans, To_String (Entry_Name));
         if Main = null then
            Put_Line (Standard_Error, "plankc: no plan named " & To_String (Entry_Name));
            return;
         end if;
      end if;

      declare
         IR : constant String :=
           PK.Codegen.Generate (Plans, Main, Ada.Directories.Simple_Name (Name), Assertions);
      begin
         if Emit_IR then
            Write_File ((if Length (Output) > 0 then To_String (Output)
                         else Strip_Ext (Name) & ".ll"), IR);
            Set_Exit_Status (Success);
         else
            declare
               Exe     : constant String :=
                 (if Length (Output) > 0 then To_String (Output) else Strip_Ext (Name));
               IR_File : constant String := Exe & ".ll";
               Ok      : Boolean;
            begin
               Write_File (IR_File, IR);
               Ok := Build (IR_File, Exe);
               if not Keep_IR then
                  Ada.Directories.Delete_File (IR_File);
               end if;
               if Ok then
                  Set_Exit_Status (Success);
               end if;
            end;
         end if;
      end;
   end;
exception
   when Usage_Error | PK.Diagnostics.Compile_Error =>
      null;
   when Ada.Streams.Stream_IO.Name_Error =>
      Put_Line (Standard_Error, "plankc: cannot open " & To_String (Input));
   when E : others =>
      Put_Line (Standard_Error, "plankc: internal error: "
                & Ada.Exceptions.Exception_Information (E));
end Plankc;
