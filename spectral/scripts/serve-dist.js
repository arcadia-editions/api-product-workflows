const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const rootDir = path.resolve(__dirname, '..');
const distDir = path.join(rootDir, 'dist');
const host = process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT || 8080);

const contentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.yml': 'text/yaml; charset=utf-8',
  '.yaml': 'text/yaml; charset=utf-8',
};

function send(res, statusCode, body, contentType = 'text/plain; charset=utf-8') {
  res.writeHead(statusCode, {
    'Content-Type': contentType,
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function resolveRequestPath(urlPathname) {
  const relativePath = decodeURIComponent(urlPathname === '/' ? '/spectral.js' : urlPathname);
  const normalizedPath = path.normalize(relativePath).replace(/^(\.\.(\/|\\|$))+/, '');
  return path.join(distDir, normalizedPath);
}

const server = http.createServer(async (req, res) => {
  if (!req.url) {
    send(res, 400, 'Bad Request');
    return;
  }

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
      'Access-Control-Allow-Headers': '*',
      'Cache-Control': 'no-store',
    });
    res.end();
    return;
  }

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    send(res, 405, 'Method Not Allowed');
    return;
  }

  const requestUrl = new URL(req.url, `http://${req.headers.host || `${host}:${port}`}`);
  const filePath = resolveRequestPath(requestUrl.pathname);
  const relative = path.relative(distDir, filePath);

  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    send(res, 403, 'Forbidden');
    return;
  }

  try {
    const stat = await fs.promises.stat(filePath);

    if (!stat.isFile()) {
      send(res, 404, 'Not Found');
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    const contentType = contentTypes[ext] || 'application/octet-stream';

    res.writeHead(200, {
      'Content-Type': contentType,
      'Content-Length': stat.size,
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'no-store',
    });

    if (req.method === 'HEAD') {
      res.end();
      return;
    }

    fs.createReadStream(filePath).pipe(res);
  } catch (error) {
    if (error && error.code === 'ENOENT') {
      send(res, 404, 'Not Found');
      return;
    }

    console.error(error);
    send(res, 500, 'Internal Server Error');
  }
});

server.listen(port, host, () => {
  console.log(`Serving ${distDir} at http://${host}:${port}/`);
  console.log(`Bundle URL: http://${host}:${port}/spectral.js`);
});
