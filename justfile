default:
    @just --list

# Generate Android release keystore + print base64 for GitHub secret
jks-gen file="release-keystore.jks" alias="release":
    keytool -genkeypair -v -storetype PKCS12 -keystore {{file}} -keyalg RSA -keysize 2048 -validity 10000 -alias {{alias}}
    base64 -w0 {{file}}
