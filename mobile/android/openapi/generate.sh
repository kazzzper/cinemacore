#!/usr/bin/env bash
# Regenerate the Android wire client from contracts/openapi.yaml.
#
# The generated tree is committed so an Android build never needs Node or a
# network call to the generator. Never edit data/api by hand.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
out="$here/../app/src/main/java/com/cinemacore/app/data/api"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cd "$here/.."
npx --yes @openapitools/openapi-generator-cli@2.20.0 generate \
  -i "$repo/contracts/openapi.yaml" \
  -g kotlin \
  -o "$tmp" \
  --library jvm-retrofit2 \
  --additional-properties="packageName=com.cinemacore.app.data.api,apiPackage=com.cinemacore.app.data.api.apis,modelPackage=com.cinemacore.app.data.api.models,serializationLibrary=kotlinx_serialization,dateLibrary=java8,useCoroutines=true,enumPropertyNaming=UPPERCASE,omitGradleWrapper=true"

rm -rf "$out"
mkdir -p "$(dirname "$out")"
cp -R "$tmp/src/main/kotlin/com/cinemacore/app/data/api" "$out"

echo "Regenerated $out"
