with Interfaces;

--  Root of the Plankalkuel compiler.
package PK is

   function Img (N : Integer) return String;
   --  Decimal image without the leading blank.

   function Img_U (N : Interfaces.Unsigned_64) return String;

end PK;
