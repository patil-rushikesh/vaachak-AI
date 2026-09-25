#!/bin/sh
set -eu
cd -- "$(dirname -- "$0")"
npx --yes esbuild@0.28.2 app.js --bundle --format=iife --target=es2018 --outfile=bundle.js
