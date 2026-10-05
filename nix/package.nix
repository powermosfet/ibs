{
  pkgs,
  src,
  dependencies,
}:
pkgs.stdenv.mkDerivation {
  pname = "iterative-barcode-searcher";
  version = "0.1.0";
  inherit src;
  nativeBuildInputs = with pkgs; [
    gleam
    beamPackages.erlang
    beamPackages.rebar3
    makeWrapper
  ];
  configurePhase = ''
    runHook preConfigure
    export HOME=$TMPDIR
    export ERL_FLAGS="+S 2:2"
    mkdir -p build
    cp -r ${dependencies}/packages build/
    chmod -R u+w build
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    gleam export erlang-shipment
    runHook postBuild
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    gleam format --check src test
    gleam test
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/ibs $out/bin
    cp -r build/erlang-shipment/* $out/lib/ibs/
    patchShebangs $out/lib/ibs/entrypoint.sh
    makeWrapper $out/lib/ibs/entrypoint.sh $out/bin/iterative-barcode-searcher \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.beamPackages.erlang ]} \
      --add-flags run
    runHook postInstall
  '';
  meta = {
    description = "Route scanned barcodes through a REST product lookup and RabbitMQ";
    mainProgram = "iterative-barcode-searcher";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
