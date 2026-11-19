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
/usr/local/bin/agent-entrypoint sh -eu -c '
  test -z "${GH_TOKEN+x}"
  test -z "${AI_GATEWAY_API_KEY+x}"
  test ! -e "$HOME/.gitconfig"
'
# Runtime values survive when no file is mounted.
AI_GATEWAY_API_KEY=existing /usr/local/bin/agent-entrypoint sh -eu -c 'test "$AI_GATEWAY_API_KEY" = existing'

gpg --homedir "$check_dir/generator" --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'Offline Test <offline@example.invalid>' ed25519 sign 0 >/dev/null 2>&1
expected=$(gpg --homedir "$check_dir/generator" --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
gpg --homedir "$check_dir/generator" --batch --armor --export-secret-keys > "$check_dir/secrets/agent-gpg-private-key"
printf '%s\n' fake-gateway > "$check_dir/secrets/vercel-ai-gateway-api-key"
printf '%s\n' fake-github > "$check_dir/secrets/julieio-goose-github-pat"
export AGENT_SECRETS_DIR="$check_dir/secrets" GIT_USER_NAME='Offline Test' GIT_USER_EMAIL=offline@example.invalid
export expected
/usr/local/bin/agent-entrypoint sh -eu -c '
  trap '\''gpgconf --kill all'\'' EXIT
  test "$AI_GATEWAY_API_KEY" = fake-gateway
  test "$GH_TOKEN" = fake-github
  test "$(stat -c %a "$GNUPGHOME")" = 700
  test "$(git config --global user.signingkey)" = "$expected"
  test "$(git config --global commit.gpgsign)" = true
  git config --global --get-all credential.https://github.com.helper | rg -q "gh auth git-credential"
  # Credentials remain in the process environment, not the git config.
  ! rg -q "fake-github|fake-gateway" "$HOME/.gitconfig"
  git init -q "$HOME/repo"
  cd "$HOME/repo"
  git commit -q --allow-empty -m "Offline signed commit"
  git verify-commit HEAD >/dev/null 2>&1
  test "$(git log -1 --format=%ae)" = offline@example.invalid
'
# Fake token broker on loopback: the projected token selects the answer.
cat > "$check_dir/broker.js" <<'BROKER'
const http = require('http');
const fs = require('fs');
const server = http.createServer((req, res) => {
  const auth = req.headers.authorization;
  res.setHeader('content-type', 'application/json');
  if (req.method === 'POST' && auth === 'Bearer good-projected') {
    res.end(JSON.stringify({ token: 'broker-token', expiresAt: '2099-01-01T00:00:00Z' }));
  } else if (req.method === 'POST' && auth === 'Bearer garbage-projected') {
    res.end('not json');
  } else {
    res.statusCode = 403;
    res.end(JSON.stringify({ error: { code: 'leaky-body' } }));
  }
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[2], String(server.address().port)));
BROKER
node "$check_dir/broker.js" "$check_dir/port" &
broker_pid=$!
for _ in $(seq 50); do [ -s "$check_dir/port" ] && break; sleep 0.1; done
test -s "$check_dir/port"
export GH_TOKEN_BROKER_URL="http://127.0.0.1:$(cat "$check_dir/port")/token"
export GH_TOKEN_BROKER_TOKEN_PATH="$check_dir/broker-token"

# Success: the broker token wins over the mounted PAT and stays out of git config and output.
printf %s good-projected > "$check_dir/broker-token"
/usr/local/bin/agent-entrypoint sh -eu -c '
  test "$GH_TOKEN" = broker-token
  git config --global --get-all credential.https://github.com.helper | rg -q "gh auth git-credential"
  ! rg -q "broker-token|good-projected" "$HOME/.gitconfig"
' > "$check_dir/out" 2>&1
! rg -q 'broker-token|good-projected|fake-github' "$check_dir/out"

# Failures exit non-zero with one fixed line and no secrets.
broker_fail() {
  if /usr/local/bin/agent-entrypoint true > "$check_dir/error" 2>&1; then
    echo "FAIL: broker $1 accepted" >&2
    exit 1
  fi
  test "$(wc -l < "$check_dir/error")" -eq 1
  ! rg -q 'broker-token|good-projected|bad-projected|garbage-projected|leaky-body|not json|fake-github|127\.0\.0\.1' "$check_dir/error"
}
printf %s bad-projected > "$check_dir/broker-token"
broker_fail 'non-200 answer'
rg -q 'HTTP 403' "$check_dir/error"
printf %s garbage-projected > "$check_dir/broker-token"
broker_fail 'unparsable response'
rg -q 'HTTP 200' "$check_dir/error"
GH_TOKEN_BROKER_TOKEN_PATH="$check_dir/absent" broker_fail 'missing token file'
unset GH_TOKEN_BROKER_URL GH_TOKEN_BROKER_TOKEN_PATH
# Without GH_TOKEN_BROKER_URL the mounted PAT path is unchanged.
/usr/local/bin/agent-entrypoint sh -eu -c 'test "$GH_TOKEN" = fake-github'

printf '%s\n' invalid > "$check_dir/secrets/agent-gpg-private-key"
if /usr/local/bin/agent-entrypoint true > "$check_dir/error" 2>&1; then
  echo 'FAIL: invalid signing key accepted' >&2
  exit 1
fi
! rg -q 'invalid|fake-github|fake-gateway' "$check_dir/error"
echo 'Entrypoint checks passed (fake secrets, offline signed commit, fake token broker).'
