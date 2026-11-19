#!/bin/sh
set -eu

secrets_dir=${AGENT_SECRETS_DIR:-/mnt/agent-secrets}
if [ -f "$secrets_dir/vercel-ai-gateway-api-key" ]; then
  AI_GATEWAY_API_KEY=$(cat "$secrets_dir/vercel-ai-gateway-api-key")
  export AI_GATEWAY_API_KEY
fi
if [ -n "${GH_TOKEN_BROKER_URL:-}" ]; then
  # Output stays fixed text: never print tokens, the URL or the response body.
  # The explicit hostname keeps `gh auth setup-git` offline; the helper reads
  # GH_TOKEN at use time.
  broker_token_file=${GH_TOKEN_BROKER_TOKEN_PATH:-/var/run/secrets/broker/token}
  if [ ! -r "$broker_token_file" ]; then
    echo 'GitHub token broker: projected token file not readable' >&2
    exit 1
  fi
  previous_umask=$(umask)
  umask 077
  broker_response=$(mktemp)
  umask "$previous_umask"
  # The header comes from stdin so the projected token never reaches argv.
  broker_status=$({ printf 'Authorization: Bearer '; cat "$broker_token_file"; printf '\n'; } |
    curl -s --max-time 30 -X POST -H @- -o "$broker_response" -w '%{http_code}' \
      "$GH_TOKEN_BROKER_URL" 2>/dev/null) || broker_status=000
  if [ "$broker_status" != 200 ]; then
    rm -f "$broker_response"
    echo "GitHub token broker request failed (HTTP $broker_status)" >&2
    exit 1
  fi
  broker_token=$(node -e '
    const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).token;
    if (typeof t !== "string" || t === "") process.exit(1);
    process.stdout.write(t);
  ' "$broker_response" 2>/dev/null) || broker_token=
  rm -f "$broker_response"
  if [ -z "$broker_token" ]; then
    echo "GitHub token broker returned an unparsable response (HTTP $broker_status)" >&2
    exit 1
  fi
  GH_TOKEN=$broker_token
  export GH_TOKEN
  gh auth setup-git --hostname github.com
fi

if [ -n "${GIT_USER_NAME:-}" ]; then
  git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then
  git config --global user.email "$GIT_USER_EMAIL"
fi
if [ -f "$secrets_dir/agent-gpg-private-key" ]; then
  # A fresh private directory avoids selecting a key left by an earlier run.
  previous_umask=$(umask)
  umask 077
  GNUPGHOME=$(mktemp -d "$HOME/.gnupg-agent.XXXXXX")
  umask "$previous_umask"
  export GNUPGHOME
  # Suppress GPG diagnostics: malformed input must not leak mounted contents.
  if ! gpg --batch --import "$secrets_dir/agent-gpg-private-key" >/dev/null 2>&1; then
    echo 'Failed to import agent signing key' >&2
    exit 1
  fi
  fingerprint=$(gpg --batch --with-colons --list-secret-keys 2>/dev/null |
    awk -F: '$1 == "fpr" {print $10; exit}')
  if [ -z "$fingerprint" ]; then
    echo 'Agent signing key contains no private key' >&2
    exit 1
  fi
  git config --global user.signingkey "$fingerprint"
  git config --global commit.gpgsign true
fi

exec "$@"
