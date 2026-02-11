# Save the Knowledge — Website

Breezy landing page for the Save the Knowledge macOS app.

## Preview locally

```bash
cd website
python3 -m http.server 8080
# Open http://localhost:8080
```

Or open `index.html` directly in a browser.

## Deploy to Vercel

```bash
cd website
vercel
```

Or connect the repo to Vercel and set the root directory to `website`.

## Deploy to Netlify

Drag the `website` folder to [Netlify Drop](https://app.netlify.com/drop), or connect the repo and set publish directory to `website`.

## Update download link

1. Zip your Release build: `zip -r KnowledgeCache.zip KnowledgeCache.app`
2. Upload to your host (e.g. Vercel Blob, S3, GitHub Releases)
3. In `index.html`, set the download button href to your file URL:
   ```html
   <a href="https://yoursite.com/KnowledgeCache.zip" class="cta-download">Download Save the Knowledge</a>
   ```

## Custom domain

Point savetheknowledge.com to your Vercel/Netlify deployment in your DNS settings.

## Newsletter

The subscribe form uses `action="#"`. Connect it to a service (Mailchimp, Buttondown, ConvertKit) by updating the form's `action` URL and adding `name` attributes for their API.
