#!/bin/bash
# Creates a local self-signed code-signing certificate and imports it into the login
# keychain. Run once.
#
# Why: macOS ties a privacy grant (microphone, speech recognition) to code identity. An
# ad-hoc signature has no certificate, so the grant keys on the binary hash and breaks on
# every rebuild -- sometimes as a re-prompt, sometimes as a silent denial where the mic
# returns nothing and no dialog appears. A stable certificate makes the grant stick.
#
# This certificate is self-signed and local. It is not trusted for distribution and is not
# meant to be; it exists only to give this app a stable identity on this machine. It is
# deliberately never added to a trust store.
#
# Requires OpenSSL 3. The system /usr/bin/openssl is LibreSSL and does NOT support
# `pkcs12 -legacy`, which macOS `security import` needs in order to read the archive.
# Override the binary with ORAL_OPENSSL if needed.
#
# To undo:  security delete-identity -c "Oral English Dev"
set -euo pipefail
cd "$(dirname "$0")"

CERT_NAME="Oral English Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
# EXIT alone does not fire on SIGINT/SIGTERM in every shell, and never on SIGKILL.
# The p12 below holds the private key, so shortening its lifetime matters.
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

# NOTE: no -v. `find-identity -v` lists only *valid* identities, and a self-signed
# certificate is reported CSSMERR_TP_NOT_TRUSTED because it chains to nothing. It is still
# perfectly usable for signing -- verified: codesign succeeds with it and emits an
# Authority line. Checking with -v would report "0 valid identities found" and make both
# scripts refuse to work.
if security find-identity -p codesigning | grep -q -F "$CERT_NAME"; then
    echo "Certificate \"$CERT_NAME\" already exists. Nothing to do."
    security find-identity -p codesigning | grep -F "$CERT_NAME"
    exit 0
fi

# --- Preflight: the right openssl ---------------------------------------------------
OPENSSL="${ORAL_OPENSSL:-$(command -v openssl || true)}"
if [ -z "$OPENSSL" ]; then
    echo "No openssl on PATH." >&2
    exit 1
fi
if ! "$OPENSSL" pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
    cat >&2 <<MSG
This openssl does not support 'pkcs12 -legacy':
  $OPENSSL  ->  $("$OPENSSL" version)

That flag is required: macOS 'security import' cannot read OpenSSL 3's modern PKCS#12
defaults, and LibreSSL (the system openssl at /usr/bin/openssl) has no -legacy option.

Fix it one of these ways:
  1. brew install openssl@3     then re-run this script
  2. ORAL_OPENSSL=/opt/homebrew/bin/openssl ./make-cert.sh
  3. Use Keychain Access instead: Certificate Assistant > Create a Certificate,
     name it "$CERT_NAME", Identity Type "Self Signed Root", Type "Code Signing".
  4. Skip the certificate entirely and accept re-prompts: ORAL_SIGN_ID=- ./build.sh
MSG
    exit 1
fi

echo "Creating a self-signed code-signing certificate: $CERT_NAME"
echo "using $("$OPENSSL" version)"

# Minimal, critical constraints: cannot issue other certificates, cannot be repurposed
# for TLS or for signing anything but code.
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$CERT_NAME/O=Oral English/C=US" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"

# A NON-EMPTY password is required. Verified against a throwaway keychain: an empty
# PKCS#12 password fails with "MAC verification failed during PKCS12 import", regardless
# of -macalg, because the Security framework and OpenSSL disagree on how the MAC is
# computed over an empty passphrase. A real password imports cleanly.
#
# Trade-off, stated plainly: `security import -P` takes the passphrase on the command
# line, where `ps` can see it for the duration of the import. It is generated fresh here
# and never reused or stored, so it has no value after this script exits, and there is no
# stdin alternative for that tool. The alternative is a script that does not work.
P12PASS="$("$OPENSSL" rand -hex 24)"

"$OPENSSL" pkcs12 -export -legacy \
    -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$CERT_NAME" -passout "pass:$P12PASS"

# -T grants access to codesign only. Deliberately NOT -A: that would let any process
# running as this user sign code with this certificate silently, which means any local
# process could forge this app's identity and inherit its microphone grant.
# -x makes the key non-extractable, so it cannot be copied off this machine.
# Expect one keychain prompt the first time codesign uses the key; choose Always Allow.
echo "Importing into the login keychain. macOS may ask for your password."
security import "$WORK/identity.p12" \
    -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign \
    -x

echo
if security find-identity -p codesigning | grep -q -F "$CERT_NAME"; then
    # Persist the SHA-1 hash and sign by hash from here on. Signing by common name is
    # ambiguous if the certificate is ever created twice -- e.g. after the 10-year expiry,
    # when the name check stops matching and a second one gets minted -- and codesign then
    # fails with an ambiguity error.
    HASH=$(security find-identity -p codesigning | grep -F "$CERT_NAME" | head -1 | awk '{print $2}')
    printf '%s\n' "$HASH" > .signing-identity
    echo "Done. codesign can now use this identity:"
    security find-identity -p codesigning | grep -F "$CERT_NAME"
    echo "Hash written to .signing-identity: $HASH"
    echo
    echo "It reports CSSMERR_TP_NOT_TRUSTED. That is expected and harmless: the"
    echo "certificate chains to nothing, which affects trust-store validation, not"
    echo "whether codesign can use it."
    echo
    echo "Next: ./run.sh"
    echo
    echo "Then verify the grant actually survives a rebuild, because everything in the"
    echo "development loop assumes it does:"
    echo "  1. ./run.sh, press record, grant the microphone"
    echo "  2. ./run.sh again"
    echo "  3. press record -- it should NOT prompt again"
else
    echo "The certificate was imported but codesign does not list it as usable." >&2
    echo "Try: security set-key-partition-list -S apple-tool:,apple: -s \"$CERT_NAME\" -k <login-password>" >&2
    echo "Or fall back to Keychain Access, or to ad-hoc: ORAL_SIGN_ID=- ./build.sh" >&2
    exit 1
fi
