{ stdenv, fetchurl, nodejs, python, utillinux, runCommand }:

let
  buildNodeSourceDist =
    { name, version, src }:
    
    stdenv.mkDerivation {
      name = "node-tarball-${name}-${version}";
      inherit src;
      buildInputs = [ nodejs ];
      buildPhase = ''
        export HOME=$TMPDIR
        tgzFile=$(npm pack)
      '';
      installPhase = ''
        mkdir -p $out/tarballs
        mv $tgzFile $out/tarballs
        mkdir -p $out/nix-support
        echo "file source-dist $out/tarballs/$tgzFile" >> $out/nix-support/hydra-build-products
      '';
    };

  semver = buildNodePackage {
    name = "semver";
    version = "3.0.1";
    src = fetchurl {
      url = http://registry.npmjs.org/semver/-/semver-3.0.1.tgz;
      sha1 = "720ac012515a252f91fb0dd2e99a56a70d6cf078";
    };
  } {};
  
  buildNodePackage =
    { name, version, src, dependencies ? {}, buildInputs ? [], production ? true, npmFlags ? "", meta ? {}, linkDependencies ? false }:
    { providedDependencies ? {} }:

    let
      # Generate and import a Nix expression that contains a list of dependencies
      # that we actually need to include privately in this package folder. The
      # ones that have been provided by any parent package, must be excluded.
  
      requiredDependencies = 
        if dependencies == {} then []
        else
          import (stdenv.mkDerivation {
            name = "${name}-${version}-requiredDependencies.nix";
            buildInputs = [ semver ];
            buildCommand = ''
              cat > $out <<EOF
              [
              ${stdenv.lib.concatMapStrings (dependencyName:
                let
                  dependency = builtins.getAttr dependencyName dependencies;
                  versionSpecs = builtins.attrNames dependency;
                in
                stdenv.lib.concatMapStrings (versionSpec:
                  if builtins.hasAttr dependencyName providedDependencies # Search for any provided dependencies that match the required version spec. If one matches, the dependency should not be included
                  then
                    let
                      providedDependency = builtins.getAttr dependencyName providedDependencies;
                      versions = builtins.attrNames providedDependency;
                    in
                    "$(if ! semver -r '${versionSpec}' ${toString versions} >/dev/null; then echo '{ name = \"${dependencyName}\"; versionSpec = \"${versionSpec}\"; }'; fi)"
                  else # If a dependency is not provided by an includer, we must always include it ourselves
                    "{ name = \"${dependencyName}\"; versionSpec = \"${versionSpec}\"; }\n"
                ) versionSpecs
              ) (builtins.attrNames dependencies)}
              ]
              EOF
            '';
          });
  
      # Generate and import a Nix expression that specifies a list of dependencies
      # for which we need to generate shims to allow the deployment to succeed
      # which correspond to the dependencies that have been provided by any of the
      # package's parents.
  
      shimmedDependencies =
        if dependencies == {} then []
        else
          import (stdenv.mkDerivation {
            name = "${name}-${version}-shimmedDependencies.nix";
            buildInputs = [ semver ];
            buildCommand = ''
              cat > $out <<EOF
              [
              ${stdenv.lib.concatMapStrings (dependencyName:
                let
                  dependency = builtins.getAttr dependencyName dependencies;
                  versionSpecs = builtins.attrNames dependency;
                in
                stdenv.lib.concatMapStrings (versionSpec:
                  stdenv.lib.optionalString (builtins.hasAttr dependencyName providedDependencies)
                    (let
                      providedDependency = builtins.getAttr dependencyName providedDependencies;
                      versions = builtins.attrNames providedDependency;
                    in
                    ''
                      $(if semver -r '${versionSpec}' ${toString versions} >/dev/null; then echo "{ name = \"${dependencyName}\"; version = \"$(semver -r '${versionSpec}' ${toString versions} | tail -1 | tr -d '\n')\"; }"; fi)
                    '')
                ) versionSpecs
              ) (builtins.attrNames dependencies)}
              ]
              EOF
            '';
          });

      # Extract the Node.js source code which is used to compile packages with native bindings
      nodeSources = runCommand "node-sources" {} ''
        tar --no-same-owner --no-same-permissions -xf ${nodejs.src}
        mv node-* $out
      '';
  
      # Compose dependency information that this package must propagate to its
      # dependencies, so that provided dependencies are not included a second time.
      # This prevents cycles and wildcard version mismatches.
  
      propagatedProvidedDependencies =
        (stdenv.lib.mapAttrs (dependencyName: dependency:
          builtins.listToAttrs (map (versionSpec:
            { name = dependency."${versionSpec}".version;
              value = true;
            }
          ) (builtins.attrNames dependency))
        ) dependencies) //
        providedDependencies //
        { "${name}"."${version}" = true; };
        
    
      # Compose a derivation containing all required dependencies. We compose it
      # seperately, so that it can also be provided as a shell hook for development environments.
      
      nodeDependencies = stdenv.mkDerivation {
        name = "node-dependencies-${name}-${version}";
        inherit src;
        buildCommand = ''
          mkdir -p $out/lib/node_modules
          cd $out/lib/node_modules
          
          # Create copies of (or symlinks to) the dependencies that must be deployed in this package's private node_modules folder.
          # This package's private dependencies are NPM packages that have not been provided by any of the includers.
          
          ${stdenv.lib.concatMapStrings (requiredDependency:
            ''
              depPath=$(echo ${dependencies."${requiredDependency.name}"."${requiredDependency.versionSpec}".pkg { providedDependencies = propagatedProvidedDependencies; }}/lib/node_modules/*)
             
              if [ ! -x "node_modules/$(basename $depPath)" ]
              then
                ${if linkDependencies then ''
                  ln -s $depPath .
                '' else ''
                  cp -r $depPath .
                ''}
            fi
            ''
          ) requiredDependencies}
        '';
      };
    
      # Deploy the Node package with some tricks
      self = stdenv.lib.makeOverridable stdenv.mkDerivation {
        inherit src meta;
      
        name = "node-${name}-${version}";
        buildInputs = [ nodejs python ] ++ stdenv.lib.optional (stdenv.isLinux) utillinux ++ buildInputs;
        buildPhase = "true";
    
        installPhase = ''
          # Move the contents of the tarball into the output folder
          mkdir -p "$out/lib/node_modules/${name}"
          mv * "$out/lib/node_modules/${name}"
      
          # Enter the target directory
        
          cd "$out/lib/node_modules/${name}"
        
          # Copy the required dependencies
          
          mkdir node_modules
          
          ${stdenv.lib.optionalString (requiredDependencies != []) ''
            cp -a ${nodeDependencies}/lib/node_modules/* node_modules
          ''}
          
          # Create shims for the packages that have been provided by earlier includers to allow the NPM install operation to still succeed
      
          ${stdenv.lib.concatMapStrings (shimmedDependency:
            ''
              mkdir -p node_modules/${shimmedDependency.name}
              cat > node_modules/${shimmedDependency.name}/package.json <<EOF
              {
                  "name": "${shimmedDependency.name}",
                  "version": "${shimmedDependency.version}"
              }
              EOF
            ''
          ) shimmedDependencies}
        
          # Some version specifiers (latest, unstable, URLs) force NPM to make remote connections. Replace these by * to prevent that
          
          sed -i -e "s/:\s*\"latest\"/:  \"*\"/" \
              -e "s/:\s*\"unstable\"/:  \"*\"/" \
              -e "s/:\s*\"\(https\?\|git\(\+\(ssh\|http\|https\)\)\?\):\/\/[^\"]*\"/: \"*\"/" \
              package.json
        
          # Deploy the Node.js package by running npm install. Since the dependencies have been symlinked, it should not attempt to install them again,
          # which is good, because we want to make it Nix's responsibility. If it needs to install any dependencies anyway (e.g. because the dependency
          # parameters are incomplete/incorrect), it fails.
  
          export HOME=$TMPDIR
          npm --registry http://www.example.com --nodedir=${nodeSources} ${npmFlags} ${stdenv.lib.optionalString production "--production --ignore-scripts"} install
          
          ${stdenv.lib.optionalString production ''
            # Run the install script explicitly, because script execution has been disabled to prevent the prepublish step from being executed
            npm run install --registry http://www.example.com --nodedir=${nodeSources} ${npmFlags} ${stdenv.lib.optionalString production "--production"}
          ''}
        
          # After deployment of the NPM package, we must remove the shims again
          ${stdenv.lib.concatMapStrings (shimmedDependency:
            ''
              rm node_modules/${shimmedDependency.name}/package.json
              rmdir node_modules/${shimmedDependency.name}
            ''
          ) shimmedDependencies}
          
          # It makes no sense to keep an empty node_modules folder around, so delete it if this is the case
          if [ -d node_modules ]
          then
              rmdir --ignore-fail-on-non-empty node_modules
          fi
        
          # Create symlink to the deployed executable folder, if applicable
          if [ -d "$out/lib/node_modules/.bin" ]
          then
              ln -s $out/lib/node_modules/.bin $out/bin
          fi
          
          # Create symlinks to the deployed manual page folders, if applicable
          if [ -d "$out/lib/node_modules/${name}/man" ]
          then
              mkdir -p $out/share
              for dir in "$out/lib/node_modules/${name}/man/"*
              do
                  mkdir -p $out/share/man/$(basename "$dir")
                  for page in "$dir"/*
                  do
                      ln -s $page $out/share/man/$(basename "$dir")
                  done
              done
          fi
        '';
        
        shellHook = ''
          export NODE_PATH=${nodeDependencies}/lib/node_modules
        '';
      };
    in
    self;
in
{ inherit buildNodeSourceDist buildNodePackage; }
