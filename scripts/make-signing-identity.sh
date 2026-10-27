#!/bin/bash
# Creates a self-signed code signing identity for building mac-rdp-server on
# this Mac. Apps signed with it keep their macOS permissions (Screen
# Recording, Accessibility) across rebuilds; ad-hoc signed ones lose them.
#
# The identity lives in its own keychain, unlocked with a random password
# kept next to it, so signing never prompts. scripts/bundle.sh uses it
# automatically. Run once:
#
#   ./scripts/make-signing-identity.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="mac-rdp-server Local Signing"
KEYCHAIN="$HOME/Library/Keychains/mac-rdp-server-signing.keychain-db"
SECRETS="$HOME/Library/Application Support/mac-rdp-server-signing"
OPENSSL=third_party/prefix/bin/openssl

if [ -f "$KEYCHAIN" ]; then
    echo "already set up: $KEYCHAIN"
    exit 0
fi
[ -x "$OPENSSL" ] || OPENSSL=/usr/bin/openssl

mkdir -p "$SECRETS"
chmod 700 "$SECRETS"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# The bundled OpenSSL has no default config file.
printf '[req]\ndistinguished_name = dn\n[dn]\n' > "$WORK/openssl.cnf"
export OPENSSL_CONF="$WORK/openssl.cnf"

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"
P12_PASSWORD=$(openssl rand -hex 16)
# Older PKCS#12 algorithms, which the security tool can read.
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$P12_PASSWORD" -out "$WORK/identity.p12"

openssl rand -hex 24 > "$SECRETS/keychain-password"
chmod 600 "$SECRETS/keychain-password"
PASSWORD=$(cat "$SECRETS/keychain-password")

# create-keychain adds the keychain to the search list; keep the list as it was.
SEARCH=$(security list-keychains -d user | tr -d '"')
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
# shellcheck disable=SC2086
security list-keychains -d user -s $SEARCH
security set-keychain-settings "$KEYCHAIN" # never lock on its own
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

echo "created \"$NAME\" in $KEYCHAIN"
