#!/bin/bash
generate_keys() {

        echo "🔑 Generating new MOK keys..."
        openssl req -newkey rsa:4096 -nodes -keyout MOK.key \
            -new -x509 -sha256 -days 3650 -out MOK.crt \
            -subj "/CN=Shani OS Secure Boot Key/"
        openssl x509 -in MOK.crt -outform DER -out MOK.der

}

# Ensure Secure Boot keys are ready
generate_keys
echo "✅ Secure Boot keys are ready."
