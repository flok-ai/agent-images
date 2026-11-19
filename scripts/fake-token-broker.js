// Fake GitHub token broker for scripts/check-entrypoint.sh. Listens on loopback
// and writes its port to the file named by argv[2]. The projected (bearer)
// token selects the answer: good -> 200 with a token, garbage -> 200 with a
// non-JSON body, anything else -> 403 with an error body.
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
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(process.argv[2], String(server.address().port));
});
