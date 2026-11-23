#!/bin/sh
# Certificates for tls_http's and cert_issuer's tests. Everything here is
# invented, every private key is thrown away when this exits, and nothing below
# chains to a real root. Only bridge-leaf.der is real: a Bridge's own public
# certificate, captured from a handshake, which this script does not touch.
#
# Run from this directory. Tests use a fixed clock inside these dates, so they
# do not go stale.
set -eu

id=AABBCCDDEEFF0011
from=20250101000000Z
to=20500101000000Z

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

key() { openssl ecparam -name prime256v1 -genkey -noout -out "$work/$1.key"; }

# issue NAME SUBJECT ISSUER_CERT ISSUER_KEY EXTENSIONS
issue() {
    key "$1"
    printf '%b\n' "$5" >"$work/$1.ext"
    openssl req -new -key "$work/$1.key" -subj "$2" -out "$work/$1.csr"
    openssl x509 -req -in "$work/$1.csr" -CA "$3" -CAkey "$4" -CAcreateserial \
        -not_before "$from" -not_after "$to" -sha256 \
        -extfile "$work/$1.ext" -out "$work/$1.pem" 2>/dev/null
    openssl x509 -in "$work/$1.pem" -outform DER -out "$1.der"
}

# selfsign NAME SUBJECT NOT_AFTER EXTENSIONS
selfsign() {
    key "$1"
    printf '%b\n' "$4" >"$work/$1.ext"
    openssl req -new -key "$work/$1.key" -subj "$2" -out "$work/$1.csr"
    openssl x509 -req -in "$work/$1.csr" -signkey "$work/$1.key" \
        -not_before "$from" -not_after "$3" -sha256 \
        -extfile "$work/$1.ext" -out "$work/$1.pem" 2>/dev/null
}

ca='basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign'
end='basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature'

# The trusted root. Outlives what it signs, so that a clock past their expiry
# reports them expired rather than finding no root at all.
selfsign root '/O=Test/CN=test-root' 20600101000000Z "$ca"
cp "$work/root.pem" test-root.pem

issue leaf "/O=Test/CN=$id" "$work/root.pem" "$work/root.key" "$end"

issue intermediate '/O=Test/CN=test-intermediate' "$work/root.pem" "$work/root.key" "$ca"
issue leaf-via-intermediate "/O=Test/CN=$id" "$work/intermediate.pem" "$work/intermediate.key" "$end"

# A genuine device certificate, used to sign another: what someone holding one
# Bridge's private key could try in order to pose as any other Bridge.
issue not-a-ca '/O=Test/CN=FFFFFFFFFFFFFFFF' "$work/root.pem" "$work/root.key" "$end"
issue leaf-via-not-a-ca "/O=Test/CN=$id" "$work/not-a-ca.pem" "$work/not-a-ca.key" "$end"

# Signed by the root but with no basicConstraints at all: not a CA either.
issue no-constraints '/O=Test/CN=test-no-constraints' "$work/root.pem" "$work/root.key" 'keyUsage=critical,keyCertSign'

# The right name, signed by nobody trusted.
selfsign self-signed "/O=Test/CN=$id" "$to" "$end"
openssl x509 -in "$work/self-signed.pem" -outform DER -out self-signed.der

# A root with the trusted root's exact name and a different key, so the name
# lookup finds the real root and only the signature can tell them apart.
selfsign fake-root '/O=Test/CN=test-root' 20600101000000Z "$ca"
issue forged-leaf "/O=Test/CN=$id" "$work/fake-root.pem" "$work/fake-root.key" "$end"
