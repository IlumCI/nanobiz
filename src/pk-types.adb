with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body PK.Types is

   function Word (Width : Positive; Signed : Boolean := False) return Ty is
     (new Ty_Rec'(Kind => K_Word, Width => Width, Signed => Signed));

   function Float_Ty (Bits : Positive) return Ty is
     (new Ty_Rec'(Kind => K_Float, Bits => Bits));

   function Arr (Length : Positive; Elem : Ty) return Ty is
     (new Ty_Rec'(Kind => K_Array, Length => Length, Elem => Elem));

   function Rec (Fields : Ty_List) return Ty is
     (new Ty_Rec'(Kind => K_Record, Fields => new Ty_List'(Fields)));

   function Same (A, B : Ty) return Boolean is
   begin
      if A.Kind /= B.Kind then
         return False;
      end if;
      case A.Kind is
         when K_Word =>
            return A.Width = B.Width and then A.Signed = B.Signed;
         when K_Float =>
            return A.Bits = B.Bits;
         when K_Array =>
            return A.Length = B.Length and then Same (A.Elem, B.Elem);
         when K_Record =>
            if A.Fields'Length /= B.Fields'Length then
               return False;
            end if;
            for K in A.Fields'Range loop
               if not Same (A.Fields (K), B.Fields (K - A.Fields'First + B.Fields'First)) then
                  return False;
               end if;
            end loop;
            return True;
      end case;
   end Same;

   function Join (L : Ty_List; Sep : String; F : access function (T : Ty) return String)
     return String
   is
      R : Unbounded_String;
   begin
      for K in L'Range loop
         if K > L'First then
            Append (R, Sep);
         end if;
         Append (R, F (L (K)));
      end loop;
      return To_String (R);
   end Join;

   function Component_Image (T : Ty) return String;

   function Image (T : Ty) return String is
     (if Is_Bit (T) then "0" else Component_Image (T));

   function Component_Image (T : Ty) return String is
     (case T.Kind is
         when K_Word =>
           (if T.Signed then "+-" else "") & Img (T.Width) & ".0",
         when K_Float => "f" & Img (T.Bits),
         when K_Array =>
           (if T.Length > Max_Width and then Is_Bit (T.Elem)
            then Img (T.Length) & ".0"
            else Img (T.Length) & "." & Component_Image (T.Elem)),
         when K_Record => "(" & Join (T.Fields.all, ", ", Image'Access) & ")");

   function LLVM (T : Ty) return String is
     (case T.Kind is
         when K_Word   => "i" & Img (T.Width),
         when K_Float  => (if T.Bits = 32 then "float" else "double"),
         when K_Array  => "[" & Img (T.Length) & " x " & LLVM (T.Elem) & "]",
         when K_Record => "{ " & Join (T.Fields.all, ", ", LLVM'Access) & " }");

end PK.Types;
