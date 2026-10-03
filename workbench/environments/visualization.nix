let
  base = import ./base.nix;
in
{
  description = "Tabular data and declarative charts";
  python =
    ps:
    base.python ps
    ++ [
      ps.altair
      ps.polars
    ];
  tools = base.tools;
}
