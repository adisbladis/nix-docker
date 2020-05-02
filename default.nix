{ pkgs ? import <nixpkgs> {} }:

let

  inherit (pkgs) lib;

  users = {

    root = {
      uid = 0;
      shell = "/bin/bash";
      home = "/root";
      gid = 0;
    };

  } // lib.listToAttrs (
    map (
      n: {
        name = "nixbld${toString n}";
        value = {
          uid = 30000 + n;
          gid = 30000;
          groups = [ "nixbld" ];
          description = "Nix build user ${toString n}";
        };
      }
    ) (lib.lists.range 1 32)
  );

  groups = {
    root.gid = 0;
    nixbld.gid = 30000;
  };

  userToPasswd = (
    k:
    { uid
    , gid ? 65534
    , home ? "/var/empty"
    , description ? ""
    , shell ? "/bin/false"
    , groups ? []
    }: "${k}:x:${toString uid}:${toString gid}:${description}:${home}:${shell}"
  );
  passwdContents = (
    lib.concatStringsSep "\n"
    (lib.attrValues (lib.mapAttrs userToPasswd users))
  );

  userToShadow = k: { ... }: "${k}:!:1::::::";
  shadowContents = (
    lib.concatStringsSep "\n"
    (lib.attrValues (lib.mapAttrs userToShadow users))
  );

  # Map groups to members
  # {
  #   group = [ "user1" "user2" ];
  # }
  groupMemberMap = (let
    # Create a flat list of user/group mappings
    mappings = (
      builtins.foldl' (
        acc: user: let
          groups = users.${user}.groups or [];
        in acc ++ map (group: {
          inherit user group;
        }) groups
      )
      []
      (lib.attrNames users)
    );
  in (
    builtins.foldl' (
      acc: v: acc // {
        ${v.group} = acc.${v.group} or [] ++ [ v.user ];
      }
    )
    {}
    mappings)
  );

  groupToGroup = k: { gid }: let
    members = groupMemberMap.${k} or [];
  in "${k}:x:${toString gid}:${lib.concatStringsSep "," members}";
  groupContents = (
    lib.concatStringsSep "\n"
    (lib.attrValues (lib.mapAttrs groupToGroup groups))
  );

  nixConf = {
    sandbox = "false";
    build-users-group = "nixbld";
    trusted-public-keys = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
  };
  nixConfContents = (lib.concatStringsSep "\n" (lib.mapAttrsFlatten (n: v: "${n} = ${v}") nixConf)) + "\n";

  passwd = pkgs.runCommand "base-system" {
    inherit passwdContents groupContents shadowContents nixConfContents;
    passAsFile = [
      "passwdContents"
      "groupContents"
      "shadowContents"
      "nixConfContents"
    ];
    allowSubstitutes = false;
    preferLocalBuild = true;
  } ''
    env
    set -x
    mkdir -p $out/etc

    cat $passwdContentsPath > $out/etc/passwd
    echo "" >> $out/etc/passwd

    cat $groupContentsPath > $out/etc/group
    echo "" >> $out/etc/group

    cat $shadowContentsPath > $out/etc/shadow
    echo "" >> $out/etc/shadow

    mkdir $out/tmp

    mkdir -p $out/etc/nix
    cat $nixConfContentsPath > $out/etc/nix/nix.conf

  '';


in
pkgs.dockerTools.buildLayeredImageWithNixDb {

  name = "nix";
  tag = "latest";

  contents = [
    # Save ~10M image size
    (pkgs.nix.override {
      withAWS = false;
    })
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.gnutar
    pkgs.gzip
    pkgs.gnugrep
    passwd
  ];

  config = {
    Env = [
      "SSL_CERT_FILE=${pkgs.cacert.out}/etc/ssl/certs/ca-bundle.crt"
      "USER=root"
      "PATH=/nix/var/nix/profiles/default/bin:/nix/var/nix/profiles/default/sbin:/bin:/sbin:/usr/bin:/usr/sbin"
      "GIT_SSL_CAINFO=${pkgs.cacert.out}/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=${pkgs.cacert.out}/etc/ssl/certs/ca-bundle.crt"
      "NIX_PATH=nixpkgs=${pkgs.nix-gitignore.gitignoreSource [ ".git" ] pkgs.path}"
    ];
  };

}
