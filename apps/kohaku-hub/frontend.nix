{ pkgs, lib, kohaku-hub }:

pkgs.stdenv.mkDerivation {
  pname = "kohaku-hub-frontend";
  version = "unstable";

  src = kohaku-hub;

  # 0003 makes `repoAPI.getInfo` request the metadata-only repo-info shape
  # (`include_siblings=false`, see 0002), so the SPA stops blocking the dataset
  # card on a multi-MB `siblings` array it never reads. Applied here rather than
  # to `src` because `npmDeps` is a fixed-output hash over the unpatched
  # `src/kohaku-hub-ui`, and this patch does not touch the package manifests.
  patches = [ ./patches/0003-ui-skip-siblings-on-repo-info.patch ];

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