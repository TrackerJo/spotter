# Spotter website

A single-screen marketing page for the Spotter iPhone workout log, built with React, TypeScript, and Vite. It follows the system light or dark appearance and respects reduced motion.

## Develop

```sh
npm install
npm run dev
```

## App Store launch

The download button is disabled until the App Store listing is available. Once it is, copy `.env.example` to `.env.local` and set:

```sh
VITE_APP_STORE_URL=https://apps.apple.com/app/your-published-listing
```

Restart the development server or rebuild the site. This enables the existing download button. Only HTTPS `apps.apple.com` URLs are accepted.

## Verify and build

```sh
npm run lint
npm run build
npm run preview
```

The production site is generated in `dist/`.

## Brand assets

`public/spotter-mark.png` is an optimized copy of the existing Spotter logo. `public/spotter-icon.png` packages that mark on the brand indigo background. `public/spotter-dumbbells.webp` is optimized transparent hero art created with the built-in imagegen tool, using the existing Spotter App Store artwork as its reference.

Art direction: a premium 3D studio rendering of two parallel diagonal dumbbells, one porcelain white and one periwinkle indigo, with rounded weight heads, finely knurled grips, matte texture, soft studio lighting, and a transparent background; no text or logos.

The download CTA uses Apple’s unmodified official App Store badge, stored locally at `public/app-store-badge.svg`. Source: https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg

## GitHub Pages deployment

Production URL: https://spotter.kazoom.app

The repository-root workflow `.github/workflows/deploy-website.yml` installs from the lockfile, checks and builds `spotter-website`, and uploads only `spotter-website/dist`. It runs on website changes pushed to `main`, or manually from GitHub Actions. Native iPhone app changes alone do not trigger a deployment.

### One-time launch setup

1. In [repository Pages settings](https://github.com/TrackerJo/spotter/settings/pages), set **Source → GitHub Actions**.
2. In those settings, save **Custom domain → spotter.kazoom.app** before changing DNS.
3. At the DNS provider for `kazoom.app`, create a **CNAME** record with name **spotter** and target **trackerjo.github.io**. Use DNS-only mode if your provider offers proxying, and replace any conflicting records for the same hostname.
4. Commit and push the website and workflow to `main`, or run **Deploy Spotter website** manually once those files are on GitHub.
5. Once GitHub’s DNS check and certificate provisioning finish, enable **Enforce HTTPS** in Pages settings.

The `public/CNAME` file is included in the build, but GitHub Actions deployments still require the custom domain to be saved in repository settings. No DNS or GitHub settings are changed by a local build.

The website uses root asset paths for the custom domain. It is not configured to be served under the `/spotter/` repository subpath. `/support` and `/privacy` have real HTML entry points, so direct visits work without a single-page-app rewrite (the host may redirect them to their trailing-slash forms).

Once the App Store listing is live, add the repository Actions variable **VITE_APP_STORE_URL** in **Settings → Secrets and variables → Actions → Variables**, then rerun the workflow. This is a public URL, not a secret. Until it is set, the download button stays disabled.

After deployment, check the home page, `/support`, `/privacy`, `/robots.txt`, and `/sitemap.xml` on the custom domain, including direct page reloads and mobile layouts.

References: [GitHub custom domains](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site), [Vite on GitHub Pages](https://vite.dev/guide/static-deploy#github-pages).
