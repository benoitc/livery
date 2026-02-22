#!/bin/bash
# Generate self-signed certificates for testing
# Creates both PEM (for HTTPS/HTTP2) and DER (for QUIC/HTTP3) formats

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/certs"

mkdir -p "${CERT_DIR}"

echo "Generating self-signed certificates in ${CERT_DIR}..."

# Generate private key
openssl genrsa -out "${CERT_DIR}/key.pem" 2048

# Generate self-signed certificate
openssl req -new -x509 \
    -key "${CERT_DIR}/key.pem" \
    -out "${CERT_DIR}/cert.pem" \
    -days 365 \
    -subj "/C=US/ST=Test/L=Test/O=Livery/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,DNS:server,IP:127.0.0.1"

# Convert to DER format for QUIC/HTTP3
openssl x509 -in "${CERT_DIR}/cert.pem" -outform DER -out "${CERT_DIR}/cert.der"
openssl rsa -in "${CERT_DIR}/key.pem" -outform DER -out "${CERT_DIR}/key.der"

# Set permissions
chmod 644 "${CERT_DIR}/cert.pem" "${CERT_DIR}/cert.der"
chmod 600 "${CERT_DIR}/key.pem" "${CERT_DIR}/key.der"

echo "Certificates generated successfully:"
ls -la "${CERT_DIR}"
