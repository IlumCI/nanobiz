with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Ada.Strings.Wide_Wide_Fixed;
with Ada.Strings.Wide_Wide_Unbounded; use Ada.Strings.Wide_Wide_Unbounded;
with Ada.Strings.Unbounded;
with PK.Diagnostics; use PK.Diagnostics;

package body PK.Twodim is

   package UTF renames Ada.Strings.UTF_Encoding.Wide_Wide_Strings;

   subtype WWS is Wide_Wide_String;
   subtype WWC is Wide_Wide_Character;

   package Byte_Lines is new Ada.Containers.Indefinite_Vectors (Positive, String);
   package Wide_Lines is new Ada.Containers.Indefinite_Vectors (Positive, WWS);

   No_Row : constant WWC := WWC'Val (0);
   Main   : constant WWC := ' ';

   function Is_Ident (C : WWC) return Boolean is
     (C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_');

   function Expand_Tabs (L : WWS) return WWS is
      R : Unbounded_Wide_Wide_String;
   begin
      for C of L loop
         if C = WWC'Val (9) then
            loop
               Append (R, ' ');
               exit when Length (R) mod 8 = 0;
            end loop;
         elsif C /= WWC'Val (13) then
            Append (R, C);
         end if;
      end loop;
      return To_Wide_Wide_String (R);
   end Expand_Tabs;

   --  Blank out a trailing comment ('#' or "//").
   function Strip_Comment (L : WWS) return WWS is
      R : WWS := L;
   begin
      for K in R'Range loop
         if R (K) = '#' or else (R (K) = '/' and then K < R'Last and then R (K + 1) = '/') then
            R (K .. R'Last) := [others => ' '];
            exit;
         end if;
      end loop;
      return R;
   end Strip_Comment;

   function Bar (L : WWS) return Natural is
     (Ada.Strings.Wide_Wide_Fixed.Index (L, "|"));

   --  Main for a candidate main row, 'V', 'K' or 'S' for a subscript row
   --  (label A is a synonym of S), No_Row otherwise.
   function Row_Kind (L : WWS) return WWC is
      B : constant Natural := Bar (L);
   begin
      if B = 0 then
         return No_Row;
      end if;
      declare
         Lab : constant WWS :=
           Ada.Strings.Wide_Wide_Fixed.Trim (L (L'First .. B - 1), Ada.Strings.Both);
      begin
         if Lab = "V" or else Lab = "K" or else Lab = "S" then
            return Lab (Lab'First);
         elsif Lab = "A" then
            return 'S';
         end if;
         return Main;
      end;
   end Row_Kind;

   type Var_Info is record
      Col     : Positive;
      Letter  : WWC;
      V, K, S : Unbounded_Wide_Wide_String;
   end record;

   package Var_Vectors is new Ada.Containers.Indefinite_Vectors (Positive, Var_Info);

   function Narrow (S : WWS) return String is (UTF.Encode (S));

   function Translate_Block
     (Rows : Wide_Lines.Vector; First_Line : Positive) return WWS
   is
      M    : constant WWS := Rows (1);
      MB   : constant Positive := Bar (M);
      Vars : Var_Vectors.Vector;
      Seen : WWS (1 .. 3) := "   ";
   begin
      --  Variables of the main row.
      for P in MB + 1 .. M'Last loop
         if M (P) in 'V' | 'Z' | 'R' | 'i'
           and then (P = MB + 1 or else not Is_Ident (M (P - 1)))
           and then (P = M'Last or else not Is_Ident (M (P + 1)))
         then
            Vars.Append (Var_Info'(Col => P, Letter => M (P), others => <>));
         end if;
      end loop;

      --  Attach each subscript entry to the variable above it.
      for R in 2 .. Rows.Last_Index loop
         declare
            L    : constant WWS := Rows (R);
            Kind : constant WWC := Row_Kind (L);
            Line : constant Positive := First_Line + R - 1;
            P    : Natural := Bar (L) + 1;
         begin
            if Ada.Strings.Wide_Wide_Fixed.Index (Seen, [1 => Kind]) /= 0 then
               Error (Line, 1, "duplicate " & Narrow ([1 => Kind]) & " row in 2D block");
            end if;
            Seen (R - 1) := Kind;
            while P <= L'Last loop
               if L (P) = ' ' then
                  P := @ + 1;
               else
                  declare
                     S     : constant Positive := P;
                     Owner : Natural := 0;
                  begin
                     while P <= L'Last and then L (P) /= ' ' loop
                        P := @ + 1;
                     end loop;
                     for J in Vars.First_Index .. Vars.Last_Index loop
                        if Vars (J).Col in S .. P - 1 then
                           if Owner /= 0 then
                              Error (Line, S, "subscript '" & Narrow (L (S .. P - 1))
                                     & "' lies under more than one variable");
                           end if;
                           Owner := J;
                        end if;
                     end loop;
                     if Owner = 0 then
                        Error (Line, S, "subscript '" & Narrow (L (S .. P - 1))
                               & "' is not under a variable letter of the main row");
                     end if;
                     declare
                        V : Var_Info := Vars (Owner);
                        E : constant Unbounded_Wide_Wide_String :=
                          To_Unbounded_Wide_Wide_String (L (S .. P - 1));
                     begin
                        case Kind is
                           when 'V' =>
                              if Length (V.V) > 0 then
                                 Error (Line, S, "second V entry for one variable");
                              end if;
                              V.V := E;
                           when 'K' =>
                              if Length (V.K) > 0 then
                                 Error (Line, S, "second K entry for one variable");
                              end if;
                              V.K := E;
                           when others =>
                              if Length (V.S) > 0 then
                                 Error (Line, S, "second S entry for one variable");
                              end if;
                              V.S := E;
                        end case;
                        Vars.Replace_Element (Owner, V);
                     end;
                  end;
               end if;
            end loop;
         end;
      end loop;

      --  Rewrite the main row.
      declare
         Out_L : Unbounded_Wide_Wide_String :=
           To_Unbounded_Wide_Wide_String (M (M'First .. MB - 1)) & " ";
         Next  : Positive := Vars.First_Index;
      begin
         for P in MB + 1 .. M'Last loop
            if Next <= Vars.Last_Index and then Vars (Next).Col = P then
               declare
                  V   : constant Var_Info := Vars (Next);
                  Num : constant WWS := To_Wide_Wide_String (V.V);
               begin
                  if V.Letter /= 'i' then
                     if Num'Length = 0 then
                        Error (First_Line, P, "variable " & Narrow ([1 => V.Letter])
                               & " has no number in the V row");
                     end if;
                     if (for some C of Num => C not in '0' .. '9') then
                        Error (First_Line + 1, P, "the V row entry of a variable must be a "
                               & "number, found '" & Narrow (Num) & "'");
                     end if;
                  end if;
                  Append (Out_L, V.Letter & Num);
                  if Length (V.K) > 0 or else Length (V.S) > 0 then
                     Append (Out_L, "[" & V.K);
                     if Length (V.S) > 0 then
                        Append (Out_L, ":" & V.S);
                     end if;
                     Append (Out_L, "]");
                  end if;
                  Next := @ + 1;
               end;
            else
               Append (Out_L, M (P));
            end if;
         end loop;
         return To_Wide_Wide_String (Out_L);
      end;
   end Translate_Block;

   function Translate (Source : String) return String is
      Bytes : Byte_Lines.Vector;
      Wide  : Wide_Lines.Vector;   --  decoded, tabs expanded, comments blanked
   begin
      declare
         Start : Positive := Source'First;
      begin
         for K in Source'Range loop
            if Source (K) = ASCII.LF then
               Bytes.Append (Source (Start .. K - 1));
               Start := K + 1;
            end if;
         end loop;
         Bytes.Append (Source (Start .. Source'Last));
      end;

      for B of Bytes loop
         declare
         begin
            Wide.Append (Strip_Comment (Expand_Tabs (UTF.Decode (B))));
         exception
            when Ada.Strings.UTF_Encoding.Encoding_Error =>
               Wide.Append ("");   --  not 2D; the lexer reports bad characters
         end;
      end loop;

      declare
         Result : Ada.Strings.Unbounded.Unbounded_String;
         I      : Positive := 1;
         N      : constant Natural := Natural (Bytes.Length);

         First_Out : Boolean := True;

         procedure Put (S : String) is
         begin
            if not First_Out then
               Ada.Strings.Unbounded.Append (Result, ASCII.LF);
            end if;
            First_Out := False;
            Ada.Strings.Unbounded.Append (Result, S);
         end Put;
      begin
         while I <= N loop
            declare
               Kind : constant WWC := Row_Kind (Wide (I));
            begin
               if Kind = Main and then I < N and then Row_Kind (Wide (I + 1)) in 'V' | 'K' | 'S'
               then
                  declare
                     Rows : Wide_Lines.Vector;
                     J    : Positive := I + 1;
                  begin
                     Rows.Append (Wide (I));
                     while J <= N and then Row_Kind (Wide (J)) in 'V' | 'K' | 'S' loop
                        if J - I > 3 then
                           Error (J, 1, "a 2D block has at most the rows V, K and S");
                        end if;
                        Rows.Append (Wide (J));
                        J := @ + 1;
                     end loop;
                     Put (UTF.Encode (Translate_Block (Rows, I)));
                     for Unused in I + 1 .. J - 1 loop
                        Put ("");
                     end loop;
                     I := J;
                  end;
               elsif Kind in 'V' | 'K' | 'S' then
                  Error (I, 1, "subscript row without a main row above it");
               else
                  Put (Bytes (I));
                  I := @ + 1;
               end if;
            end;
         end loop;
         return Ada.Strings.Unbounded.To_String (Result);
      end;
   end Translate;

end PK.Twodim;
