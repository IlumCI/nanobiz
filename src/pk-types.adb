package body PK.Types is

   function Word (Width : Positive) return Ty is
     (new Ty_Rec'(Kind => K_Word, Width => Width));

   function Arr (Length : Positive; Elem : Ty) return Ty is
     (new Ty_Rec'(Kind => K_Array, Length => Length, Elem => Elem));

   function Same (A, B : Ty) return Boolean is
   begin
      if A.Kind /= B.Kind then
         return False;
      end if;
      return
        (case A.Kind is
            when K_Word  => A.Width = B.Width,
            when K_Array => A.Length = B.Length and then Same (A.Elem, B.Elem));
   end Same;

   function Leaf_Count (T : Ty) return Natural is
     (if T.Kind = K_Word then 1 else T.Length * Leaf_Count (T.Elem));

   function Component_Image (T : Ty) return String is
     (case T.Kind is
         when K_Word  => Img (T.Width) & ".0",
         when K_Array =>
           (if T.Length > Max_Width and then T.Elem.Kind = K_Word and then T.Elem.Width = 1
            then Img (T.Length) & ".0"
            else Img (T.Length) & "." & Component_Image (T.Elem)));

   function Image (T : Ty) return String is
     (if T.Kind = K_Word and then T.Width = 1 then "0" else Component_Image (T));

   function LLVM (T : Ty) return String is
     (case T.Kind is
         when K_Word  => "i" & Img (T.Width),
         when K_Array => "[" & Img (T.Length) & " x " & LLVM (T.Elem) & "]");

end PK.Types;
