# Save the Knowledge Website

Static marketing/documentation site for the Save the Knowledge project.

## Contents

- `index.html`: landing page with product overview, install snippets, and download section.
- `styles.css`: site styling.
- `vercel.json`: simple static hosting config.

## Run locally

```bash
cd website
python3 -m http.server 8080
```

Open: `http://localhost:8080`

## Deploy

### Vercel

```bash
cd website
vercel --prod
```

Or connect repo and set root directory to `website`.

### Netlify

Set publish directory to `website`, or drag/drop the folder into Netlify Drop.

## Before publishing

Replace placeholder links in `index.html`:

- `https://github.com/YOUR_GITHUB_USER/knowledge-cache`

Optional:

- Update download CTA to your latest release asset URL.
- Update footer legal text/policies if needed.

## Related docs

- Root project readme: `../README.md`
- Installation guide: `../docs/INSTALLATION.md`
- Project overview: `../docs/PROJECT-OVERVIEW.md`
- Homebrew distribution: `../docs/HOMEBREW-DISTRIBUTION.md`
