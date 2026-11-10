default:
    @just --list

# Generate Android release keystore (PKCS12) + print base64 for GitHub secret
keystore-gen file="release-keystore.p12" alias="release":
    keytool -genkeypair -v -storetype PKCS12 -keystore {{file}} -keyalg RSA -keysize 2048 -validity 10000 -alias {{alias}}
    base64 -w0 {{file}}
