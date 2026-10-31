import { AppleLogoIcon } from '@phosphor-icons/react'
import './App.css'

const appStoreUrl = import.meta.env.VITE_APP_STORE_URL?.trim()
const downloadUrl = appStoreUrl && /^https:\/\/apps\.apple\.com\//.test(appStoreUrl)
  ? appStoreUrl
  : undefined

function App() {
  return (
    <div className="landing">
      <header className="header">
        <div className="brand" aria-label="Spotter">
          <img className="brand-mark" src="/spotter-mark.png" alt="" width="40" height="40" />
          <span>spotter</span>
        </div>
        <span className="availability">{downloadUrl ? 'Made for iPhone' : 'Coming soon for iPhone'}</span>
      </header>

      <main className="hero">
        <div className="hero-copy">
          <h1>Stronger<span>together.</span></h1>
          <p className="description">A workout log that keeps up.<br />Track your sets, see your progress, and train with friends.</p>
          {downloadUrl ? (
            <a className="download" href={downloadUrl}>
              <AppleLogoIcon size={24} weight="fill" aria-hidden="true" />
              <span>Download on iOS</span>
            </a>
          ) : (
            <button className="download" type="button" disabled aria-describedby="download-status">
              <AppleLogoIcon size={24} weight="fill" aria-hidden="true" />
              <span>Download on iOS</span>
            </button>
          )}
          {!downloadUrl && <span id="download-status" className="sr-only">Coming soon. The App Store download is not available yet.</span>}
        </div>

        <div className="hero-visual">
          <div className="visual-disc" aria-hidden="true" />
          <img className="dumbbells" src="/spotter-dumbbells.webp"
            alt="A pair of white and indigo dumbbells, side by side."
            width="1024" height="1024" fetchPriority="high" />
        </div>
      </main>

      <footer className="footer">
        <p>Every set. A little stronger.</p>
        <span>Built for iPhone. iOS 18+</span>
      </footer>
    </div>
  )
}

export default App
