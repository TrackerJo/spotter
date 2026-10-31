import './Privacy.css'

export default function Privacy() {
  return (
    <div className="privacy-page">
      <title>Privacy Policy · Spotter</title>
      <header className="header">
        <div className="brand" aria-label="Spotter">
          <img className="brand-mark" src="/spotter-mark.png" alt="" width="40" height="40" />
          <span>spotter</span>
        </div>
      </header>
      <main className="privacy-content">
        <h1>Privacy policy</h1>
        <p className="privacy-date">Effective October 31, 2026</p>
        <p>Spotter is an iPhone workout log provided by Kazoom Apps (“we”). This policy explains how information is handled in the app and on this website. Questions or privacy requests? Email <a href="mailto:kazoom.apps@gmail.com">kazoom.apps@gmail.com</a>.</p>

        <section>
          <h2>Your workout data</h2>
          <p>Spotter saves the information you enter or import: profile names and identifiers, workouts, exercises, sets, weights, repetitions, durations, distances, effort ratings, notes, training plans, and preferences. It uses this information to log training, calculate progress, and provide the features you choose. Basic logging does not require a Spotter account.</p>
          <p>Your library is stored on your device. Spotter does not upload it to a server operated by Kazoom Apps. The app does not include advertising or third-party tracking or analytics SDKs, sell personal information, or use workout data for advertising. It does not read Apple Health data or request access to your contacts or precise location.</p>
        </section>

        <section>
          <h2>Optional iCloud sync</h2>
          <p>If you connect iCloud, Apple stores your personal library in your account’s private CloudKit database so it can sync across your devices. This includes plans, solo workouts, custom exercises, settings, and profiles you manage. Shared-workout records and nearby pairing details are excluded from this sync. Device backups may separately retain app data according to your Apple settings. Apple handles its services under its <a href="https://www.apple.com/legal/privacy/">privacy policy</a>.</p>
        </section>

        <section>
          <h2>Training with other people</h2>
          <p>When you invite or join a nearby partner, Spotter uses Local Network access and an encrypted connection to exchange shared-session information, including participant profiles, exercises, sets, notes, and recent exercise performance used as starting values. Both people can view and log for session participants. Your full private workout library is not sent to the partner.</p>
          <p>Only share invitation codes with people you trust. Information already shared can remain on their phone after you disconnect. If you create a profile or enter information for someone else, get their permission, including before sharing their data with a partner or an AI service. You can withdraw Local Network permission in iPhone Settings.</p>
        </section>

        <section>
          <h2>Optional ChatGPT features</h2>
          <p>Connecting ChatGPT is optional. Sign-in shares authentication information with OpenAI. Spotter keeps the connected account’s identifier, email, and access credentials in the iPhone Keychain. It does not receive your ChatGPT password.</p>
          <p>When you use an AI feature, your messages, conversation context, and relevant data are sent directly to OpenAI to generate a response. Training questions and plan suggestions can use your completed workouts, notes, plans, exercise library, and the names and workout histories of profiles you manage. Records belonging to connected friends are excluded from these data tools. The CSV repair feature sends the CSV you select and its parsing context, without granting access to your saved workout history.</p>
          <p>Chats are temporary in Spotter, and requests disable response storage. This does not guarantee that OpenAI retains no data; its security logs, retention rules, and your account’s applicable terms still apply. Read <a href="https://openai.com/policies/privacy-policy/">OpenAI’s privacy policy</a> and <a href="https://developers.openai.com/api/docs/guides/your-data">data controls</a>. Service providers may process information outside your country.</p>
          <p>You can stop using AI at any time and disconnect ChatGPT in the app’s profile settings. Disconnecting removes the app’s saved account credentials and attempts to revoke access. If revocation cannot be confirmed, remove Spotter’s access in ChatGPT settings too. Disconnecting does not delete information already processed by OpenAI.</p>
        </section>

        <section>
          <h2>Support and this website</h2>
          <p>If you email us, we receive your email address, message, and any attachments. We use them to respond, troubleshoot, and handle privacy requests, and retain them only as needed for those purposes or legal obligations. Avoid sending sensitive workout information unless it is needed for your request.</p>
          <p>This website does not set advertising or analytics cookies. Website hosting and email providers process the information needed to deliver their services, such as network requests, IP addresses, and email messages, and may keep operational or security logs under their own policies.</p>
        </section>

        <section>
          <h2>Retention, deletion, and your choices</h2>
          <p>Your saved library stays on your device and, if enabled, in iCloud until you remove it. You can edit profiles and delete sets or workouts in the app. Deletions remove records from normal views, but earlier versions and deletion markers may remain in the app’s sync and conflict-resolution history. Removing a managed profile hides it and keeps its saved workout records.</p>
          <p>To remove the local library, delete Spotter from your iPhone rather than offloading it. Manage any remaining iCloud app data and device backups through your Apple account settings. Disconnect ChatGPT before deleting the app: Keychain credentials can survive app removal. Copies held by a partner or a service provider must be managed separately; deleting the app does not erase them.</p>
          <p>Depending on where you live, you may have rights to access, correct, receive a copy of, or request deletion of personal information, object to or restrict its use, withdraw consent, or contact a privacy regulator. Email us to exercise applicable rights or get help removing data. We may need to verify your identity. We cannot directly retrieve or erase a library stored only on your device, in your private iCloud account, or on someone else’s phone.</p>
        </section>

        <section>
          <h2>Security and children</h2>
          <p>Spotter uses iOS data protection for local files, Keychain protection for ChatGPT credentials, and encryption for nearby and online connections. No storage or transmission method is completely secure.</p>
          <p>Spotter is not directed to children under 13. We do not knowingly collect their personal information through support or this website. Contact us if you believe a child has provided information to us so we can address it.</p>
        </section>

        <section>
          <h2>Policy updates</h2>
          <p>We may update this policy as Spotter changes. We will post the updated policy here with a new effective date and provide additional notice or request consent when required.</p>
        </section>
      </main>
    </div>
  )
}
