{ pkgs, manifest }:
let
  packages = (builtins.fromTOML (builtins.readFile manifest)).packages;
  fetch =
    package:
    pkgs.fetchurl {
      url = "https://repo.hex.pm/tarballs/${package.name}-${package.version}.tar";
      sha256 = package.outer_checksum;
    };
in
pkgs.runCommand "ibs-hex-dependencies" { } ''
  mkdir -p $out/packages
  ${pkgs.lib.concatMapStringsSep "\n" (package: ''
    mkdir -p $out/packages/${package.name}
    tar -xOf ${fetch package} contents.tar.gz | tar -xz -C $out/packages/${package.name}
  '') packages}
  cat > $out/packages/packages.toml <<'EOF'
  [packages]
  ${pkgs.lib.concatMapStringsSep "\n" (package: ''${package.name} = "${package.version}"'') packages}
  [git]
  EOF
''
