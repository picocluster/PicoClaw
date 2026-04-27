#!/usr/bin/env bash
# Generate PicoClaw Local CA and server certs for claw.local + threadweaver.local.
# Run once during initial setup. Idempotent — skips anything that already exists.
# Certs are installed at /opt/picocluster/pki/ and mounted into the Caddy container.
#
# Usage: sudo bash scripts/generate-pki.sh

set -euo pipefail

PKI_DIR="${PKI_DIR:-/opt/picocluster/pki}"
DOMAINS=(claw.local threadweaver.local)
CA_DAYS=3650   # 10 years
CERT_DAYS=825  # Apple's max for trusted certs

mkdir -p "$PKI_DIR"
chmod 755 "$PKI_DIR"

log() { echo "  [pki] $*"; }

# ---------------------------------------------------------------------------
# CA
# ---------------------------------------------------------------------------
if [ -f "$PKI_DIR/ca.key" ]; then
    log "CA already exists — skipping CA generation"
else
    log "Generating CA key..."
    openssl genrsa -out "$PKI_DIR/ca.key" 4096
    chmod 600 "$PKI_DIR/ca.key"

    log "Generating CA cert (valid ${CA_DAYS} days)..."
    openssl req -x509 -new -nodes \
        -key "$PKI_DIR/ca.key" \
        -sha256 \
        -days "$CA_DAYS" \
        -out "$PKI_DIR/ca.crt" \
        -subj "/CN=PicoClaw Local CA/O=PicoClaw"
    chmod 644 "$PKI_DIR/ca.crt"

    log "CA cert: $PKI_DIR/ca.crt"
fi

# ---------------------------------------------------------------------------
# Server certs (one per domain)
# ---------------------------------------------------------------------------
for domain in "${DOMAINS[@]}"; do
    key="$PKI_DIR/${domain}.key"
    crt="$PKI_DIR/${domain}.crt"

    if [ -f "$key" ]; then
        log "Cert for ${domain} already exists — skipping"
        continue
    fi

    log "Generating cert for ${domain}..."

    openssl genrsa -out "$key" 2048
    chmod 600 "$key"

    csr=$(mktemp)
    ext=$(mktemp)

    openssl req -new \
        -key "$key" \
        -out "$csr" \
        -subj "/CN=${domain}/O=PicoClaw"

    cat > "$ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${domain}
EOF

    openssl x509 -req \
        -in "$csr" \
        -CA "$PKI_DIR/ca.crt" \
        -CAkey "$PKI_DIR/ca.key" \
        -CAcreateserial \
        -out "$crt" \
        -days "$CERT_DAYS" \
        -sha256 \
        -extfile "$ext"

    rm -f "$csr" "$ext"
    chmod 644 "$crt"
    log "Cert for ${domain}: $crt"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "PKI ready at $PKI_DIR"
echo ""
echo "Install the CA cert on each client device:"
echo "  Download: http://control.local/ca.crt"
echo ""
echo "  macOS:   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $PKI_DIR/ca.crt"
echo "  Linux:   sudo cp $PKI_DIR/ca.crt /usr/local/share/ca-certificates/picocluster.crt && sudo update-ca-certificates"
echo "  Windows: Double-click the downloaded .crt and install to 'Trusted Root Certification Authorities'"
echo "  iOS/Android: Open http://control.local/ca.crt in Safari/Chrome and follow prompts"
