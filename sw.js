// ════════════════════════════════════════════════════════════════════
// SERVICE WORKER — StockVendedor (PWA)
// ════════════════════════════════════════════════════════════════════
// Cachea el "shell" de la app (HTML, manifest, íconos) y las librerías de
// CDN para que abra sin internet. NUNCA cachea las llamadas a Supabase
// (son dinámicas: stock, pedidos, central compartida) — esas van siempre
// a la red para no servir datos viejos.
//
// La versión del cache (CACHE) la estampa build.py — lo corre el workflow
// .github/workflows/stamp-sw.yml en cada push a main (o a mano:
// `python build.py`). Así cada release invalida el cache anterior y los
// usuarios reciben la última versión sin bump manual.
// ════════════════════════════════════════════════════════════════════

const CACHE = 'stockvendedor-20260613-124940';

// Recursos propios (mismo origen) — se precachean al instalar.
const PRECACHE = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icon-192.png',
  './icon-512.png',
  './icon-maskable.png'
];

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(
    caches.open(CACHE).then(c =>
      Promise.all(PRECACHE.map(u => c.add(u).catch(() => {})))
    )
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;

  let url;
  try { url = new URL(req.url); } catch (_) { return; }

  // NUNCA tocar Supabase: dejar pasar directo a la red.
  if (url.hostname.endsWith('supabase.co')) return;

  // Navegación / documento HTML: network-first, fallback a cache (offline).
  if (req.mode === 'navigate' || req.destination === 'document') {
    e.respondWith(
      fetch(req)
        .then(r => {
          const cp = r.clone();
          caches.open(CACHE).then(c => c.put(req, cp)).catch(() => {});
          return r;
        })
        .catch(() => caches.match(req).then(m => m || caches.match('./index.html')))
    );
    return;
  }

  // Resto (estáticos propios + librerías de CDN): cache-first.
  e.respondWith(
    caches.match(req).then(m => {
      if (m) return m;
      return fetch(req).then(r => {
        // Cachear respuestas válidas y también las "opaque" (CDN cross-origin).
        if (r && (r.ok || r.type === 'opaque')) {
          const cp = r.clone();
          caches.open(CACHE).then(c => c.put(req, cp)).catch(() => {});
        }
        return r;
      }).catch(() => m);
    })
  );
});
