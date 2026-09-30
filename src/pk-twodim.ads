--  Zuse's two-dimensional notation.
--
--  A 2D block is a main row followed by subscript rows. Every row has a
--  label, a '|' and a body; the main row's label is empty or a plan
--  header prefix ("P1 max"):
--
--             | Z + V => R
--           V | 0   1    0
--           K |     2
--           S | 8.0 3.8.0 8.0
--
--  Row labels: V (variable number), K (component, a dotted path such as
--  2.3 or i), S or A (structure type). In the main row every standalone
--  letter V, Z, R or i is a variable; each subscript entry (a run of
--  non-blank characters) belongs to the variable whose letter lies within
--  the run's columns. The block above becomes
--
--     Z0[:8.0] + V1[2:3.8.0] => R0[:8.0]
--
--  Columns count Unicode code points; tabs advance to multiples of 8.
--  Each block is replaced by one linear line followed by empty lines, so
--  line numbers of diagnostics stay valid.
package PK.Twodim is

   function Translate (Source : String) return String;

end PK.Twodim;
