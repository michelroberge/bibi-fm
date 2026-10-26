#!/usr/bin/env bash
# Creates "bibi local code signing", a self-signed code-signing certificate in your login keychain.
#
# macOS remembers privacy permissions (Contacts, Calendars, Reminders, Automation) per code identity. An ad-hoc
# signed binary gets a new identity on every build, so macOS forgets bibi's permissions each time. Signed with this
# certificate, every build keeps the same identity and the permissions stay.
#
# Remove it any time: security delete-identity -c "bibi local code signing"
set -euo pipefail
NAME="bibi local code signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
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
CNF
# macOS's own LibreSSL writes a PKCS#12 file the keychain can import.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"
# -T: codesign may use the key without asking each time.
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\" in your login keychain. Builds are now signed with it (make build, make install, bin/bibi)."
echo "macOS asks for each permission once more for the newly signed bibi; after that, rebuilds keep them."
