{ pkgs, lib, kohaku-hub }:

pkgs.stdenv.mkDerivation {
  pname = "kohaku-hub-frontend";
  version = "unstable";

  src = kohaku-hub;

  nativeBuildInputs = with pkgs; [
    nodejs
    npmHooks.npmConfigHook
  ];

  postPatch = ''
    cp src/kohaku-hub-ui/package-lock.json ./package-lock.json
    cp src/kohaku-hub-ui/package.json ./package.json
  '';

  npmDeps = pkgs.fetchNpmDeps {
    name = "kohaku-hub-frontend-npm-deps";
    src = "${kohaku-hub}/src/kohaku-hub-ui";
    hash = "sha256-yWWFx+5lKuGVmnEo/nSbqxBdNbus8/XRSi+hUGOAjiQ=";
  };

  buildPhase = ''
    runHook preBuild

    cd src/kohaku-hub-ui
    npm run build

    runHook postBuild
  '';

  installPhase = ''
    mkdir -p "$out/ui"
    cp -r dist/. "$out/ui/"
  '';

  meta = {
    description = "KohakuHub frontend";
    homepage = "https://github.com/KohakuBlueleaf/KohakuHub";
  };
}