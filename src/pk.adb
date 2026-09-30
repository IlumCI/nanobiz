package body PK is

   function Img (N : Integer) return String is
      S : constant String := Integer'Image (N);
   begin
      return (if S (S'First) = ' ' then S (S'First + 1 .. S'Last) else S);
   end Img;

   function Img_U (N : Interfaces.Unsigned_64) return String is
      S : constant String := Interfaces.Unsigned_64'Image (N);
   begin
      return S (S'First + 1 .. S'Last);
   end Img_U;

end PK;
