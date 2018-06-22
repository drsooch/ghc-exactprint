#!/bin/sh

# For GHC-8/master
# cabal install --allow-newer turtle Diff
# cabal configure -froundtrip --enable-tests --allow-newer
# cabal configure -froundtrip --enable-tests --allow-newer --enable-profiling

# cabal new-configure -fdev --enable-tests --with-compiler=/opt/ghc/8.5.20180614/bin/ghc --allow-newer
# cabal new-configure -fdev --enable-tests --with-compiler=/opt/ghc/8.5.20180617/bin/ghc --allow-newer
# cabal new-configure -fdev --enable-tests --with-compiler=/opt/ghc/8.5.20180619/bin/ghc --allow-newer
cabal new-configure -fdev --enable-tests --with-compiler=/opt/ghc/8.6.0.20180620/bin/ghc --allow-newer


# cabal new-configure -froundtrip --enable-tests --with-compiler=/opt/ghc/8.5.20180617/bin/ghc --allow-newer
# cabal new-configure -froundtrip --enable-tests --with-compiler=ghc-8.4.3
