#!/bin/sh
# This script places the program binaries in directory layout that follows
# the Docker target platform names, so Docker's `dist/$TARGETPLATFORM/progname`
# matches with the file path.
#
# This script is used as helper for Dockerfile.release file in CI.

progname="${PROGNAME:-nightseekd}"
dist_dir="${DISTDIR:=dist}"
for binary in $progname-*-linux-*; do
  arch="${binary##*-linux-}"
  case "$arch" in
    arm32) platform='linux/arm/v7' ;;
    *)     platform="linux/$arch" ;;
  esac
  install -D -m 0755 "$binary" "$dist_dir/$platform/$progname"
done
find "$dist_dir" -type f -exec ls -alF {} +
