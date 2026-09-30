--  Plankalkuel structure types ("Strukturen").
--
--  Linear notation, after Rojas et al. (2000):
--     0        a single bit (S0)
--     n.0      a word of n bits, 1 <= n <= 64, used as an unsigned integer;
--              for n > 64, an array of n bits (no arithmetic)
--     m.T      an array of m components of type T (T not 0)
--  A single bit is represented as a word of width 1.
package PK.Types is

   Max_Width : constant := 64;

   type Ty_Kind is (K_Word, K_Array);

   type Ty_Rec;
   type Ty is access Ty_Rec;

   type Ty_Rec (Kind : Ty_Kind) is record
      case Kind is
         when K_Word =>
            Width : Positive;
         when K_Array =>
            Length : Positive;
            Elem   : Ty;
      end case;
   end record;

   function Word (Width : Positive) return Ty;
   function Arr (Length : Positive; Elem : Ty) return Ty;

   function Is_Scalar (T : Ty) return Boolean is (T.Kind = K_Word);

   function Same (A, B : Ty) return Boolean;
   --  Structural equality.

   function Leaf (T : Ty) return Ty is
     (if T.Kind = K_Word then T else Leaf (T.Elem));
   --  The word type at the bottom of an array type.

   function Leaf_Count (T : Ty) return Natural;

   function Image (T : Ty) return String;
   --  Plankalkuel notation, e.g. "0", "8.0", "4.16.0".

   function LLVM (T : Ty) return String;
   --  LLVM IR type, e.g. "i1", "i8", "[4 x i16]".

end PK.Types;
