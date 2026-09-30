with Ada.Containers.Vectors;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces;

--  Tokenizer for the linear Plankalkuel notation. Accepts ASCII and the
--  Unicode operator forms (-> or =>, <=, >=, !=, *, /, &, |, ^, !).
package PK.Lexer is

   type Token_Kind is
     (Tk_Int, Tk_Float, Tk_Ident, Tk_Var, Tk_PlusMinus,
      Tk_Arrow, Tk_LParen, Tk_RParen, Tk_LBrack, Tk_RBrack,
      Tk_Colon, Tk_Comma, Tk_Semi, Tk_Dot,
      Tk_Plus, Tk_Minus, Tk_Star, Tk_Slash, Tk_Percent,
      Tk_Eq, Tk_Ne, Tk_Lt, Tk_Le, Tk_Gt, Tk_Ge,
      Tk_And, Tk_Or, Tk_Xor, Tk_Not,
      Tk_NL, Tk_EOF);

   type Token is record
      Kind      : Token_Kind := Tk_EOF;
      Line, Col : Positive := 1;
      Value     : Interfaces.Unsigned_64 := 0;   --  Tk_Int
      Float_Val : Long_Float := 0.0;             --  Tk_Float
      Start     : Natural := 0;                  --  byte range in the source
      Stop      : Natural := 0;
      Text      : Unbounded_String;             --  Tk_Ident
      Var_Class : Character := ' ';             --  Tk_Var: 'V', 'Z' or 'R'
      Var_Index : Natural := 0;                 --  Tk_Var
   end record;

   package Token_Vectors is new Ada.Containers.Vectors (Positive, Token);

   function Tokenize (Source : String) return Token_Vectors.Vector;
   --  Newlines are significant outside parentheses and are returned as
   --  Tk_NL. The result always ends with Tk_EOF.
   --
   --  After ':' and up to the next ']' the lexer is in type mode: numbers
   --  are plain decimal and 'x' separates dimensions (4x0 = 4.0). Inside
   --  brackets, "5.3" is a component path, not a floating-point literal.

   function Describe (T : Token) return String;

end PK.Lexer;
