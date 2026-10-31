# Spotter website

A single-screen marketing page for the Spotter iPhone workout log, built with React, TypeScript, and Vite. It follows the system light or dark appearance and respects reduced motion.

## Develop

```sh
npm install
npm run dev
```

## App Store launch

The page currently shows “Coming soon for iPhone” and a disabled download button. Once the listing is available, copy `.env.example` to `.env.local` and set:

```sh
VITE_APP_STORE_URL=https://apps.apple.com/app/your-published-listing
```

Restart the development server or rebuild the site. This enables the existing download button and changes the availability label to “Made for iPhone”. Only HTTPS `apps.apple.com` URLs are accepted.

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
