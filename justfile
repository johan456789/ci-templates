default:
    @just --list

# Generate Android release keystore (PKCS12) + print base64 for GitHub secret
keystore-gen file="release-keystore.p12" alias="release":
    keytool -genkeypair -v -storetype PKCS12 -keystore {{file}} -keyalg RSA -keysize 2048 -validity 10000 -alias {{alias}}
    base64 -w0 {{file}}

# Upload a keystore + its password as `release` environment secrets of an app repo
[no-cd]
keystore-upload repo file="release-keystore.p12" env="release":
    #!/usr/bin/env bash
    # repo: owner/name, or just name for your own repos. Creates the environment
    # (deployable from v* tags only) if the repo doesn't have one yet.
    set -euo pipefail
    repo={{quote(repo)}} file={{quote(file)}} env={{quote(env)}}
    [[ "$repo" == */* ]] || repo="$(gh api user --jq .login)/$repo"
    [ -f "$file" ] || { echo "error: no keystore at $file" >&2; exit 1; }

    read -rsp "Password for $file: " KS_PASS; echo
    export KS_PASS
    # Catch a wrong password here, not at the first release
    if ! out="$(keytool -list -keystore "$file" -storepass:env KS_PASS 2>&1)"; then
        echo "error: couldn't open $file (${out%%$'\n'*})" >&2
        exit 1
    fi

    if ! gh api "repos/$repo/environments/$env" > /dev/null 2>&1; then
        echo "Creating environment '$env' in $repo, deployable from v* tags only"
        gh api -X PUT "repos/$repo/environments/$env" --input - > /dev/null <<< \
            '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
        gh api -X POST "repos/$repo/environments/$env/deployment-branch-policies" \
            -f name='v*' -f type=tag > /dev/null
    fi

    base64 -w0 "$file" | gh secret set ANDROID_KEYSTORE_BASE64 --env "$env" --repo "$repo"
    printf '%s' "$KS_PASS" | gh secret set ANDROID_KEYSTORE_PASSWORD --env "$env" --repo "$repo"
    gh secret list --env "$env" --repo "$repo"

    if gh secret list --repo "$repo" --json name --jq '.[].name' | grep -q '^ANDROID_'; then
        echo "warning: $repo still has repo-level ANDROID_* secrets, which any job can read. Delete them:" >&2
        gh secret list --repo "$repo" --json name --jq '.[].name | select(startswith("ANDROID_"))' \
            | sed "s|^|  gh secret delete --repo $repo |" >&2
    fi
