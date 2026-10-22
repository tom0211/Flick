#!/usr/bin/env bash
# Creates a self-signed code-signing identity, "Flick Local Signing", in the login keychain.
#
# macOS ties Accessibility and Screen Recording approval to an app's code signature. An ad-hoc signature changes
# with every build, so each rebuild silently loses the approval. Signed with this identity, the signature's
# requirement stays the same across builds and the approval sticks. The identity is only meaningful on this Mac.
# To remove it: Keychain Access → login → My Certificates → delete "Flick Local Signing".
set -euo pipefail

NAME="Flick Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -passout pass:flick -out "$WORK/identity.p12"
# -T lets codesign use the key without a keychain prompt.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P flick -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\" in the login keychain"
