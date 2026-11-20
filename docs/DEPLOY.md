# Deploying the web app for a classroom

Short, and specific to what the live quiz needs from its host.

## Path URLs need a rewrite

The app uses path URLs (`/join/ABC123`, not `/#/join/ABC123`) so a join link or QR code reaches
the server and opens the join screen with the code filled in. Every unknown path must serve
`index.html`:

- **nginx:** `location / { try_files $uri $uri/ /index.html; }`
- **Firebase Hosting:** `"rewrites": [{ "source": "**", "destination": "/index.html" }]`
- **Netlify:** `_redirects` containing `/*  /index.html  200`

`flutter run -d chrome` already does this in development.

## Build settings

```
flutter build web --release \
  --dart-define=BACKEND=remote \
  --dart-define=API_BASE=https://api.example.school \
  --dart-define=APP_URL=https://quiz.example.school
```

- `APP_URL` is the origin students open. The lobby's join link and QR code use it. On web it
  defaults to the page's own origin, so it is only required when that is not the address
  students should use (and for native builds).
- Do not deploy the `.symbols` files from `build/web`.

## Backend behind a proxy

- Set `TRUST_PROXY_HOPS` to the number of reverse proxies in front of the Node server (usually
  `1`). Leave it at `0` when clients connect directly; any higher lets a client choose its own IP
  via `X-Forwarded-For` and walk past the rate limits.
- The proxy must pass WebSocket upgrades on `/ws` and allow idle connections of at least 60 s
  (the server pings every 30 s).
- Add the app's origin to `CORS_ORIGINS`.

## Link previews

`web/index.html` points `og:image` at `icons/Icon-512.png`. Link-preview crawlers need an
absolute URL: replace it with `https://<your app host>/icons/Icon-512.png` at deploy time.
