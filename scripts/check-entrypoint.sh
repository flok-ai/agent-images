#!/bin/sh
set -eu
check_dir=$(mktemp -d)
broker_pid=
cleanup() {
  gpgconf --homedir "$check_dir/generator" --kill all 2>/dev/null || :
  if [ -n "$broker_pid" ]; then kill "$broker_pid" 2>/dev/null || :; fi
  rm -rf "$check_dir"
}
trap cleanup EXIT
export HOME="$check_dir/home"
mkdir -m 700 "$HOME" "$check_dir/generator" "$check_dir/secrets"
unset GH_TOKEN GH_TOKEN_BROKER_URL GH_TOKEN_BROKER_TOKEN_PATH AI_GATEWAY_API_KEY GIT_USER_NAME GIT_USER_EMAIL GNUPGHOME
export AGENT_SECRETS_DIR="$check_dir/missing"
# With no broker configured, startup leaves GH_TOKEN unset and adds no helper.
/usr/local/bin/agent-entrypoint sh -eu -c '
  test -z "${GH_TOKEN+x}"
  test -z "${AI_GATEWAY_API_KEY+x}"
  test ! -e "$HOME/.gitconfig"
'
# Runtime values survive when no file is mounted or broker configured.
AI_GATEWAY_API_KEY=existing /usr/local/bin/agent-entrypoint sh -eu -c 'test "$AI_GATEWAY_API_KEY" = existing'
GH_TOKEN=existing /usr/local/bin/agent-entrypoint sh -eu -c '
  test "$GH_TOKEN" = existing
  test ! -e "$HOME/.gitconfig"
'

# Stub token broker on loopback, used only to test the entrypoint code
# (scripts/stub-token-broker.js). It is bind-mounted read-only because this
# check is piped in and the file is not in the image.
broker_js=${STUB_BROKER_JS:-/tmp/stub-token-broker.js}
test -r "$broker_js" || { echo "Missing $broker_js: mount scripts/stub-token-broker.js" >&2; exit 1; }
node "$broker_js" "$check_dir/port" &
broker_pid=$!
for _ in $(seq 50); do [ -s "$check_dir/port" ] && break; sleep 0.1; done
test -s "$check_dir/port"
printf %s good-projected > "$check_dir/broker-token"
export GH_TOKEN_BROKER_URL="http://127.0.0.1:$(cat "$check_dir/port")/token"
export GH_TOKEN_BROKER_TOKEN_PATH="$check_dir/broker-token"

gpg --homedir "$check_dir/generator" --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'Offline Test <offline@example.invalid>' ed25519 sign 0 >/dev/null 2>&1
expected=$(gpg --homedir "$check_dir/generator" --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
gpg --homedir "$check_dir/generator" --batch --armor --export-secret-keys > "$check_dir/secrets/agent-gpg-private-key"
printf '%s\n' fake-gateway > "$check_dir/secrets/vercel-ai-gateway-api-key"
export AGENT_SECRETS_DIR="$check_dir/secrets" GIT_USER_NAME='Offline Test' GIT_USER_EMAIL=offline@example.invalid
export expected
# Success: the broker token becomes GH_TOKEN and stays out of git config and output.
/usr/local/bin/agent-entrypoint sh -eu -c '
  trap '\''gpgconf --kill all'\'' EXIT
  test "$AI_GATEWAY_API_KEY" = fake-gateway
  test "$GH_TOKEN" = broker-token
  test "$(stat -c %a "$GNUPGHOME")" = 700
  test "$(git config --global user.signingkey)" = "$expected"
  test "$(git config --global commit.gpgsign)" = true
  git config --global --get-all credential.https://github.com.helper | rg -q "gh auth git-credential"
  # Credentials remain in the process environment, not the git config.
  ! rg -q "broker-token|good-projected|fake-gateway" "$HOME/.gitconfig"
  git init -q "$HOME/repo"
  cd "$HOME/repo"
  git commit -q --allow-empty -m "Offline signed commit"
  git verify-commit HEAD >/dev/null 2>&1
  test "$(git log -1 --format=%ae)" = offline@example.invalid
' > "$check_dir/out" 2>&1
! rg -q 'broker-token|good-projected|fake-gateway' "$check_dir/out"

printf '%s\n' invalid > "$check_dir/secrets/agent-gpg-private-key"
if /usr/local/bin/agent-entrypoint true > "$check_dir/error" 2>&1; then
  echo 'FAIL: invalid signing key accepted' >&2
  exit 1
fi
! rg -q 'invalid|broker-token|good-projected|fake-gateway' "$check_dir/error"

# Broker failures exit non-zero with one fixed line and no secrets.
broker_fail() {
  if /usr/local/bin/agent-entrypoint true > "$check_dir/error" 2>&1; then
    echo "FAIL: broker $1 accepted" >&2
    exit 1
  fi
  test "$(wc -l < "$check_dir/error")" -eq 1
  ! rg -q 'broker-token|good-projected|bad-projected|garbage-projected|leaky-body|not json|fake-gateway|127\.0\.0\.1' "$check_dir/error"
}
printf %s bad-projected > "$check_dir/broker-token"
broker_fail 'non-200 answer'
rg -q 'HTTP 403' "$check_dir/error"
printf %s garbage-projected > "$check_dir/broker-token"
broker_fail 'unparsable response'
rg -q 'HTTP 200' "$check_dir/error"
GH_TOKEN_BROKER_TOKEN_PATH="$check_dir/absent" broker_fail 'missing token file'
echo 'Entrypoint checks passed (fake secrets, offline signed commit, stub token broker).'
