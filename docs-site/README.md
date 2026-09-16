# Blueforce docs site (Docusaurus)

Static documentation is synced one-way from `../docs/*.md` into `./docs/`; never edit generated `./docs/` directly.

## Local development

```bash
cd docs-site
npm install
npm start              # http://127.0.0.1:3000 (loopback only)
npm run build
npm run serve          # local static preview on 127.0.0.1:3000
```

For an explicitly approved intranet preview, use `npm run start:intranet` or `npm run serve:intranet`; those commands bind `0.0.0.0:3000`.

## Deploy

Publish `build/` through the intranet web server. The site has no favicon reference until a maintained favicon asset is added.
