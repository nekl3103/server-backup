#!/bin/sh
set -eu
cd "$(dirname "$0")"
for engine in pg maria mysql mysqlfull linux; do
    docker build -t "sb-validation-$engine:local" "$engine"
done
