import './App.css'
import Privacy from './Privacy'

const appStoreUrl = import.meta.env.VITE_APP_STORE_URL?.trim()
const downloadUrl = appStoreUrl && /^https:\/\/apps\.apple\.com\//.test(appStoreUrl)
  ? appStoreUrl
  : undefined

function App() {
  if (/^\/privacy\/?$/.test(window.location.pathname)) return <Privacy />

  if (/^\/support\/?$/.test(window.location.pathname)) {
    return (
      <div className="landing">
        <title>Support · Spotter</title>
        <header className="header">
          <div className="brand" aria-label="Spotter">
            <img className="brand-mark" src="/spotter-mark.png" alt="" width="40" height="40" />
            <span>spotter</span>
          </div>
        </header>
        <main className="support">
          <div>
            <h1>Support</h1>
            <p className="description">Need a hand with Spotter? Email us.</p>
            <a className="support-email" href="mailto:kazoom.apps@gmail.com">kazoom.apps@gmail.com</a>
          </div>
        </main>
      </div>
    )
  }

  return (
    <div className="landing">
      <header className="header">
        <div className="brand" aria-label="Spotter">
          <img className="brand-mark" src="/spotter-mark.png" alt="" width="40" height="40" />
          <span>spotter</span>
        </div>
      </header>

      <main className="hero">
        <div className="hero-copy">
          <h1>Stronger<span>together.</span></h1>
          <p className="description">A workout log that keeps up.<br />Track your sets, see your progress, and train with friends.</p>
          {downloadUrl ? (
            <a className="download" href={downloadUrl}>
              <img className="download-badge" src="/app-store-badge.svg" alt="Download on the App Store" width="168" height="56" />
            </a>
          ) : (
            <button className="download" type="button" disabled aria-describedby="download-status">
              <img className="download-badge" src="/app-store-badge.svg" alt="Download on the App Store" width="168" height="56" />
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

    </div>
  )
}

export default App
