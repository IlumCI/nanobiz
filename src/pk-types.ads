--  Plankalkuel structure types ("Strukturen").
--
--  Linear notation (Rojas et al. 2000, extended):
--     0             a single bit
--     n.0 / n x 0   an unsigned word of n bits (n <= 64); for n > 64 an
--                   array of n bits
--     +-n.0         a signed (two's complement) word of n bits; also
--                   written with the plus-minus sign
--     A8, A9        natural number: 64.0          (Zuse's A-types)
--     A10           whole number:   +-64.0
--     f32, f64      IEEE 754 binary32 / binary64 floating point
--     m.T / m x T   an array of m components of type T
--     (T1, ..., Tk) a record (tuple) of components of possibly mixed type
package PK.Types is

   Max_Width : constant := 64;

   type Ty_Kind is (K_Word, K_Float, K_Array, K_Record);

   type Ty_Rec;
   type Ty is access Ty_Rec;

   type Ty_List is array (Positive range <>) of Ty;
   type Ty_List_Access is access Ty_List;

   type Ty_Rec (Kind : Ty_Kind) is record
      case Kind is
         when K_Word =>
            Width  : Positive;
            Signed : Boolean;
         when K_Float =>
            Bits : Positive;               --  32 or 64
         when K_Array =>
            Length : Positive;
            Elem   : Ty;
         when K_Record =>
            Fields : Ty_List_Access;
      end case;
   end record;

   function Word (Width : Positive; Signed : Boolean := False) return Ty;
   function Float_Ty (Bits : Positive) return Ty;
   function Arr (Length : Positive; Elem : Ty) return Ty;
   function Rec (Fields : Ty_List) return Ty;

   function Is_Scalar (T : Ty) return Boolean is (T.Kind in K_Word | K_Float);
   function Is_Int (T : Ty) return Boolean is (T.Kind = K_Word);
   function Is_Float (T : Ty) return Boolean is (T.Kind = K_Float);
   function Is_Signed (T : Ty) return Boolean is (T.Kind = K_Word and then T.Signed);
   function Is_Bit (T : Ty) return Boolean is
     (T.Kind = K_Word and then T.Width = 1 and then not T.Signed);

   function Same (A, B : Ty) return Boolean;
   --  Structural equality.

   function Image (T : Ty) return String;
   --  Plankalkuel notation, e.g. "0", "8.0", "+-16.0", "4.(f64, 0)".

   function LLVM (T : Ty) return String;
   --  LLVM IR type, e.g. "i1", "double", "[4 x i16]", "{ double, i1 }".

end PK.Types;
