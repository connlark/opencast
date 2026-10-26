import { Chip, Link, Typography } from "@heroui/react";
import type { Metadata } from "next";
import {
  AudioLines,
  Ban,
  Bell,
  Check,
  Cloud,
  CodeXml,
  CreditCard,
  ListMusic,
  Lock,
  Mail,
  Rss,
  ShieldCheck,
  Smartphone,
  Sparkles,
  WandSparkles,
} from "lucide-react";
import { ActionLink } from "@/components/ActionLink";
import { DataPathFacts } from "@/components/DataPathFacts";
import { PolicyArticleSection } from "@/components/PolicyArticleSection";
import { PolicyTocSidebar, type PolicyTocItem } from "@/components/PolicyToc";
import { SiteFooter } from "@/components/SiteFooter";
import { createPageMetadata } from "@/lib/metadata";
import { githubURL, supportEmail, supportHost } from "@/lib/site";

export const metadata: Metadata = createPageMetadata({
  title: "opencast privacy policy",
  description:
    "opencast has no ads, no tracking, and no account. Almost everything happens on your device; this page lists the few things that leave it, who receives them, and how long they are kept.",
  url: `https://${supportHost}/privacy`,
});

const effectiveDate = "June 21, 2026";
const lastUpdated = "October 25, 2026";

// The in-app notice shown once before the first Recap or Ask request. The
// sentences below are the app's own words and the section repeats them
// verbatim, so the two never drift apart.
const recapDisclosure =
  "Passages from this episode’s transcript are sent to Apple’s Private Cloud Compute to answer. Apple does not store them. Your audio is never sent. Results stay on this device.";

// The in-app notice on the Make a Playlist form, shown every time before a
// request is sent. The sentences below are the app's own words and the
// section repeats them verbatim, so the two never drift apart.
const playlistDisclosure =
  "This show’s name, its episode titles, dates, lengths and short descriptions, and your request are sent to Apple’s Private Cloud Compute to answer. Apple does not store them. Your audio and transcripts are never sent. Playlists you save sync through your iCloud like any other playlist.";

const tocItems = [
  { id: "short-version", label: "The short version" },
  { id: "on-your-device", label: "On your device" },
  { id: "icloud-sync", label: "iCloud sync" },
  { id: "feeds-audio-and-search", label: "Feeds, audio, artwork, and search" },
  { id: "new-episode-notifications", label: "New episode notifications" },
  { id: "cloud-transcription", label: "Cloud transcription" },
  { id: "ad-detection-and-chapters", label: "Your AI provider" },
  { id: "recap-and-ask", label: "Recap and Ask on Apple Intelligence" },
  { id: "ai-playlists", label: "Make a Playlist on Apple Intelligence" },
  { id: "purchases", label: "Purchases" },
  { id: "how-services-verify-the-app", label: "How services verify the app" },
  { id: "your-choices-and-deletion", label: "Your choices and deletion" },
  { id: "what-opencast-never-does", label: "What opencast never does" },
  { id: "open-source", label: "Open source" },
  { id: "changes-and-contact", label: "Changes and contact" },
] as const satisfies readonly PolicyTocItem[];

const optIn = { label: "Opt-in", tone: "accent" } as const;

function PolicyJumpStrip() {
  return (
    <nav aria-label="Jump to a section" className="policy-toc-mobile lg:hidden">
      <ul className="policy-toc-mobile__list">
        {tocItems.map((item) => (
          <li key={item.id}>
            <a href={`#${item.id}`} className="policy-toc-mobile__link">
              {item.label}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  );
}

export default function PrivacyPage() {
  return (
    <>
      {/* overflow-clip, not overflow-hidden: hidden would make <main> the
          scroll container for the sticky table of contents, so it would
          never stick. clip still keeps the ambient orb inside the page. */}
      <main className="relative isolate overflow-clip">
        <div
          aria-hidden="true"
          className="ambient-orb pointer-events-none absolute left-[-180px] top-[-240px] -z-10 h-[560px] w-[760px] rounded-full"
        />
        <div className="mx-auto w-full max-w-5xl px-4 pb-24 pt-14 sm:px-6 sm:pt-20">
          <div className="policy-hero">
            <Chip color="accent" variant="soft" size="lg">
              <Lock className="size-4" aria-hidden="true" />
              <Chip.Label>Privacy</Chip.Label>
            </Chip>
            <Typography.Heading
              level={1}
              className="mt-5 max-w-[12ch] text-4xl font-semibold leading-[0.95] tracking-tight sm:text-6xl"
            >
              Privacy <span className="text-accent">Policy</span>
            </Typography.Heading>
            <Typography.Paragraph
              color="muted"
              className="mt-4 max-w-xl text-lg leading-relaxed"
            >
              opencast has no ads, no tracking, and no account. Almost
              everything it does happens on your iPhone or iPad. This page
              lists the few things that leave your device, who receives them,
              and how long they are kept.
            </Typography.Paragraph>
            <p className="policy-hero__meta">
              Effective {effectiveDate}. Last updated {lastUpdated}.
            </p>
            <div className="mt-6">
              <ActionLink href={`mailto:${supportEmail}`}>
                <Mail aria-hidden="true" /> Ask a privacy question
              </ActionLink>
            </div>
          </div>

          <section
            id="short-version"
            aria-labelledby="short-version-heading"
            className="policy-callout"
          >
            <div className="policy-callout__head">
              <span className="policy-callout__icon">
                <ShieldCheck aria-hidden="true" />
              </span>
              <h2 id="short-version-heading" className="policy-callout__title">
                The short version
              </h2>
            </div>
            <ul className="policy-callout__list">
              <li>
                <Check aria-hidden="true" />
                <span>
                  No ads, no analytics or tracking SDKs, and no opencast
                  account. Nothing is sold, and nothing is shared for
                  marketing.
                </span>
              </li>
              <li>
                <Check aria-hidden="true" />
                <span>
                  Your subscriptions, listening history, and playlists live on
                  your device. iCloud sync, if you use it, goes through your
                  own Apple account and never through an opencast server.
                </span>
              </li>
              <li>
                <Check aria-hidden="true" />
                <span>
                  Every cloud feature is opt-in. When you use one, opencast
                  sends only what that job needs and deletes it when the job
                  is done. With your own AI key, the text goes straight to
                  your provider instead, under its terms.
                </span>
              </li>
              <li>
                <Check aria-hidden="true" />
                <span>
                  The app and every opencast service it talks to are open
                  source, so you can check each claim on this page against the
                  code.
                </span>
              </li>
            </ul>
          </section>

          <PolicyJumpStrip />

          <div className="policy-layout lg:grid lg:grid-cols-[13rem_minmax(0,1fr)] lg:items-start lg:gap-16">
            <PolicyTocSidebar items={tocItems} />

            <div className="policy-article">
              <PolicyArticleSection
                id="on-your-device"
                index="01"
                icon={<Smartphone aria-hidden="true" />}
                title="On your device"
                tags={[{ label: "Stays on your device" }]}
              >
                <p>
                  Everything opencast knows about your listening lives on your
                  device: subscriptions, episode lists, playback progress,
                  downloads, transcripts, ad-break analyses, generated chapters
                  and summaries, recaps, feed and artwork caches, downloaded
                  Whisper models, and your settings. None of it is sent
                  anywhere by default.
                </p>
                <p>
                  Settings › Delete Data removes all of it and tells
                  opencast&apos;s services to forget this install. Your device
                  backup may include this data under Apple&apos;s terms.
                </p>
              </PolicyArticleSection>

              <PolicyArticleSection
                id="icloud-sync"
                index="02"
                icon={<Cloud aria-hidden="true" />}
                title="iCloud sync"
                tags={[{ label: "Your Apple account" }]}
              >
                <p>
                  When your device is signed in to iCloud, opencast keeps your
                  subscriptions, listening progress, and playlists in your
                  private iCloud database so your other devices pick them up. Apple stores that
                  data under its own privacy policy. opencast has no server in
                  the path and cannot see it.
                </p>
                <p>
                  Sign out of iCloud, or turn iCloud off for opencast in iOS
                  Settings, and sync stops. The app keeps working on the
                  device.
                </p>
                <DataPathFacts
                  leaves="Subscriptions, listening progress, and playlists (their names, rules and the episodes in them)."
                  receiver="Your own iCloud account, under Apple's privacy policy."
                  kept="As long as it is in your iCloud. opencast holds no copy."
                />
              </PolicyArticleSection>

              <PolicyArticleSection
                id="feeds-audio-and-search"
                index="03"
                icon={<Rss aria-hidden="true" />}
                title="Feeds, audio, artwork, and search"
                tags={[
                  { label: "Podcast hosts" },
                  { label: "Apple" },
                  { label: "Podcast Index" },
                ]}
              >
                <p>
                  Like every podcast app, opencast fetches feeds, audio, and
                  artwork straight from each show&apos;s hosting provider. That
                  provider sees your IP address and the app&apos;s version
                  string, and some providers insert ads based on where you
                  appear to be.
                </p>
                <p>
                  Search terms go to Apple&apos;s podcast directory and, through
                  opencast&apos;s directory service, to Podcast Index. The
                  directory service passes each query straight through: it
                  keeps no log, its cache keys are hashed, and it forwards no
                  client address.
                </p>
                <p>
                  Whisper models and the in-app Help pages are plain file
                  downloads from opencast&apos;s own hosts. Those requests carry
                  nothing beyond the app&apos;s version string.
                </p>
                <DataPathFacts
                  leaves="Feed, audio, and artwork requests; search terms."
                  receiver="The show's host; Apple's directory; Podcast Index through opencast's pass-through."
                  kept="Whatever each host keeps under its own policy. opencast's directory service keeps nothing."
                />
              </PolicyArticleSection>

              <PolicyArticleSection
                id="new-episode-notifications"
                index="04"
                icon={<Bell aria-hidden="true" />}
                title="New episode notifications"
                tags={[optIn, { label: "opencast service" }, { label: "Apple Push" }]}
              >
                <p>
                  Notifications stay off until you turn them on in Settings and
                  allow them in iOS. When you do, opencast registers this
                  install with its notification service and sends the feed
                  URLs you follow along with the device&apos;s push token.
                </p>
                <ul className="policy-list">
                  <li>
                    The service polls those feeds and sends a push when a new
                    episode appears. It stores the accepted feed URLs, compact
                    show metadata, the latest episode&apos;s identity, poll
                    state, and the send records that prevent duplicates.
                  </li>
                  <li>
                    A private feed URL can contain your provider&apos;s access
                    token. opencast stores that URL only so polling works.
                  </li>
                  <li>
                    The service never stores raw feed content, show notes,
                    email addresses, Apple IDs, or IP addresses.
                  </li>
                  <li>
                    Turning notifications off disables the push token and ends
                    the subscriptions. Delete Data removes the install record
                    entirely.
                  </li>
                  <li>
                    Apple Push Notification service delivers the pushes.
                    Cloudflare hosts the service.
                  </li>
                </ul>
                <DataPathFacts
                  leaves="The feed URLs you follow and a push token."
                  receiver="opencast's notification service on Cloudflare; Apple delivers the push."
                  kept="While notifications are on. Turning them off ends the subscriptions; Delete Data removes the record."
                />
              </PolicyArticleSection>

              <PolicyArticleSection
                id="cloud-transcription"
                index="05"
                icon={<AudioLines aria-hidden="true" />}
                title="Cloud transcription"
                tags={[optIn, { label: "Cloudflare Workers AI" }]}
              >
                <p>
                  Transcribe Remotely and the cloud option of Detect Ads are
                  optional, and the same work can run entirely on your device.
                  When you choose the cloud, opencast&apos;s transcription
                  service fetches the episode&apos;s audio from its podcast
                  host, or accepts an upload of your local copy if the host
                  serves different bytes, and transcribes it with Whisper on
                  Cloudflare Workers AI.
                </p>
                <ul className="policy-list">
                  <li>
                    Source audio, uploads, chunks, and model output sit in
                    private storage only while the job runs and are deleted at
                    each stage. One-day lifecycle rules are the backstop.
                  </li>
                  <li>
                    The finished transcript is deleted once the app confirms it
                    has received it, with a seven-day backstop.
                  </li>
                  <li>
                    Episode URLs are encrypted at rest and cleared when staging
                    finishes. Logs and records hold keyed hashes, job state,
                    timing, and usage counts, never audio or text.
                  </li>
                  <li>The service keeps no library of your audio or transcripts.</li>
                </ul>
                <DataPathFacts
                  leaves="The episode's audio address, or the audio itself when the host serves different bytes."
                  receiver="opencast's transcription service, running Whisper on Cloudflare Workers AI."
                  kept="Audio only while the job runs. The transcript until the app confirms receipt, seven days at most."
                />
              </PolicyArticleSection>

              <PolicyArticleSection
                id="ad-detection-and-chapters"
                index="06"
                icon={<Sparkles aria-hidden="true" />}
                title="Your AI provider"
                tags={[optIn, { label: "Google Gemini" }, { label: "OpenAI" }]}
              >
                <p>
                  Detect Ads and Chapters &amp; Summary run on your device and
                  send transcript text, never audio, directly to the AI
                  provider whose key you added (Google or OpenAI).
                  opencast&apos;s servers are not in that path and never see
                  your key. The provider processes the text under its own API
                  terms.
                </p>
                <p>
                  Without a key, these requests go through opencast&apos;s
                  trial service, with no limit per install until January 1,
                  2027 and for five free analyses per install after that. The
                  trial service adds opencast&apos;s own Google key and
                  forwards your request. It holds the transcript in memory for
                  the request only and stores no results, and its logs record
                  event names and counts, never text.
                </p>
                <p>
                  To count free analyses and stay within its monthly budget, it
                  keeps this install&apos;s App Attest key (see How services
                  verify the app) and, under one-way hashes of the install and
                  of each run, how many free analyses the install has used and
                  each run&apos;s feature, times, token counts, and cost. The
                  install&apos;s count and the runs that used a free analysis
                  are kept for as long as the trial service runs, other runs
                  for up to 90 days. Daily and monthly totals of requests,
                  tokens, and cost, which carry no install or run identifier,
                  are also kept for as long as the service runs.
                </p>
                <ul className="policy-list">
                  <li>
                    The episode and show titles may go along as context.
                    Results come straight back to your device and are kept
                    only there.
                  </li>
                  <li>
                    Your key is stored in your device&apos;s Keychain, and in
                    your iCloud Keychain when sync is on, which Apple encrypts
                    end to end. It is never sent to opencast. Delete Data does
                    not remove it; remove it in Settings › AI Services.
                  </li>
                  <li>
                    Google, under its Gemini API terms: on the free tier it may
                    use what you send and its answers to improve its products,
                    and human reviewers may read them; with a paid key it does
                    not use your prompts or responses to improve its products,
                    and logs them for a limited period only to detect abuse and
                    meet legal requirements. Google does not use trial requests
                    to improve its products.
                  </li>
                  <li>
                    OpenAI, under its API terms: API data is not used to train
                    its models unless you opt in, and abuse-monitoring logs are
                    kept for up to 30 days.
                  </li>
                  <li>
                    Until opencast&apos;s previous analysis services retire in
                    2027, older app versions still use them:
                    they keep finished results for up to 24 hours and failed
                    runs for 30 minutes, and count usage per anonymous install
                    with daily counters that clear after 48 hours.
                  </li>
                </ul>
                <DataPathFacts
                  leaves="Transcript text, sometimes with the episode and show titles."
                  receiver="The provider whose key you added, straight from your device. Without a key, opencast's trial service, which forwards it to Google."
                  kept="By your provider under its API terms. The trial service keeps no text and no results; its hashed install count and the runs that used a free analysis for as long as it runs, other runs up to 90 days, and daily and monthly totals with no identifiers for as long as it runs."
                />
              </PolicyArticleSection>

              <PolicyArticleSection
                id="recap-and-ask"
                index="07"
                icon={<WandSparkles aria-hidden="true" />}
                title="Recap and Ask on Apple Intelligence"
                tags={[optIn, { label: "Apple Private Cloud Compute" }]}
              >
                <p>
                  Recap summarizes part of an episode, and Ask answers questions
                  about it, using a transcript that is already on your device.
                  Both run on Apple&apos;s Private Cloud Compute through
                  Apple&apos;s Foundation Models, and both exist only on devices
                  that support Apple Intelligence. Nothing runs until you tap
                  Recap or Ask, and before the first request the app tells you
                  what happens, in these words:
                </p>
                <figure className="policy-quote">
                  <blockquote>
                    <p>{recapDisclosure}</p>
                  </blockquote>
                  <figcaption>
                    The one-time notice in the app, shown before the first
                    request.
                  </figcaption>
                </figure>
                <ul className="policy-list">
                  <li>
                    Passages of the transcript go to Apple, along with the
                    question you type for Ask. No opencast server is involved,
                    and the passages never reach Google or Cloudflare.
                  </li>
                  <li>
                    Apple does not store the passages, and your audio is never
                    sent. Neither feature uses transcription minutes, and
                    there is nothing to buy.
                  </li>
                  <li>
                    Results stay on your device. Recaps are cached there so a
                    repeat tap answers at once; Ask conversations are never
                    saved. Delete Data removes the cache and the notice
                    acknowledgement.
                  </li>
                  <li>
                    Apple&apos;s model may decline a passage. When it does,
                    opencast shows a short notice, does not retry, and an Ask
                    conversation simply continues.
                  </li>
                  <li>
                    To stop using them, leave Recap and Ask untapped; opencast
                    never runs them on its own. Turning off Apple Intelligence
                    in iOS Settings means neither can send anything.
                  </li>
                </ul>
                <DataPathFacts
                  leaves="Passages of the episode's transcript, and your Ask question."
                  receiver="Apple's Private Cloud Compute. No opencast server is in the path."
                  kept="Not stored by Apple. Results live only on your device."
                />
              </PolicyArticleSection>

              <PolicyArticleSection
                id="ai-playlists"
                index="08"
                icon={<ListMusic aria-hidden="true" />}
                title="Make a Playlist on Apple Intelligence"
                tags={[
                  optIn,
                  { label: "Apple Private Cloud Compute" },
                  { label: "Beta" },
                ]}
              >
                <p>
                  Make a Playlist drafts playlists from one show&apos;s episode
                  list, either for a request you type or as suggested groups,
                  and you choose which ones to save. It runs on Apple&apos;s
                  Private Cloud Compute through Apple&apos;s Foundation Models,
                  exists only on devices that support Apple Intelligence, and
                  is labelled Beta in the app. Nothing is sent until you tap
                  Ask on the Make a Playlist form, and the form tells you what
                  happens every time, in these words:
                </p>
                <figure className="policy-quote">
                  <blockquote>
                    <p>{playlistDisclosure}</p>
                  </blockquote>
                  <figcaption>
                    The notice on the Make a Playlist form, shown every time.
                  </figcaption>
                </figure>
                <ul className="policy-list">
                  <li>
                    Apple receives the show&apos;s name, the request you type,
                    and for each listed episode its title, date, length, and a
                    short description of at most 200 characters. On a long
                    show, only part of the list may be sent: the episodes that
                    best match your request, chosen on your device by word
                    matching and on-device word vectors, or the newest
                    episodes that fit. Suggest Groups sends the list
                    without a request, and on a long show only its newest 150
                    episodes.
                  </li>
                  <li>
                    Your audio, transcripts, the feed URL, your listening
                    history, your other subscriptions, and account identifiers
                    are never sent. No opencast server is involved, and
                    nothing reaches Google or Cloudflare.
                  </li>
                  <li>
                    Apple does not store the request or the list. The drafts
                    live only in the open sheet. Playlists you save are
                    ordinary playlists that sync through your private iCloud
                    like any other playlist. You delete them like any other
                    playlist, or with Delete Data, which removes them on every
                    device signed in to that iCloud account.
                  </li>
                  <li>
                    Apple&apos;s model may decline a request or return an
                    answer opencast cannot read. When it does, opencast sends
                    the same request once more before telling you, and you can
                    try again. If the list is too long for Apple&apos;s model,
                    opencast sends a shorter one. When it declines, you can
                    also choose Try a Simpler Answer, an experimental retry
                    that asks Apple&apos;s model only for episode numbers and
                    names the playlists on your device. It sends the same kinds
                    of details as the first request and nothing else, and
                    follows the same once-more rule.
                  </li>
                  <li>
                    It shares the Apple Intelligence allowance that Recap and
                    Ask use. It uses no transcription minutes, and there is
                    nothing to buy.
                  </li>
                  <li>
                    To stop using it, leave Make a Playlist untapped; opencast
                    never runs it on its own. Turning off Apple Intelligence in
                    iOS Settings means it cannot send anything.
                  </li>
                </ul>
                <DataPathFacts
                  leaves="The show's name, its episode titles, dates, lengths and short descriptions, and your request."
                  receiver="Apple's Private Cloud Compute. No opencast server is in the path."
                  kept="Not stored by Apple. Results live only on your device."
                />
              </PolicyArticleSection>

              <PolicyArticleSection
                id="purchases"
                index="09"
                icon={<CreditCard aria-hidden="true" />}
                title="Purchases"
                tags={[{ label: "App Store" }]}
              >
                <p>
                  Transcription credits are one-time App Store purchases. Apple
                  handles payment, and opencast never sees your name, email, or
                  card.
                </p>
                <ul className="policy-list">
                  <li>
                    opencast&apos;s purchase service verifies Apple-signed app
                    and transaction records, keeps a per-account ledger of
                    credits, reservations, refunds, and the one-time free hour,
                    and answers balance queries. Accounts are keyed by an
                    Apple-issued app transaction identifier, not by you.
                  </li>
                  <li>
                    Refunds go through Apple. A refunded pack is removed from
                    the ledger and can leave a balance owed.
                  </li>
                  <li>
                    Purchase, credit, refund, reconciliation, and
                    fraud-prevention records are kept for as long as running
                    the paid service and meeting accounting and legal
                    obligations require.
                  </li>
                </ul>
                <DataPathFacts
                  leaves="Apple-signed transaction records; never your name, email, or card."
                  receiver="Apple handles payment; opencast's purchase service keeps the credit ledger."
                  kept="Ledger and fraud-prevention records for as long as the paid service and the law require."
                />
              </PolicyArticleSection>

              <PolicyArticleSection
                id="how-services-verify-the-app"
                index="10"
                icon={<ShieldCheck aria-hidden="true" />}
                title="How services verify the app"
                tags={[{ label: "Apple App Attest" }, { label: "Cloudflare" }]}
              >
                <p>
                  Every opencast service accepts requests only from a genuine
                  copy of the app, checked with Apple App Attest. Each install
                  generates its own key, Apple certifies it, and the services
                  store that public key and short-lived challenge hashes.
                </p>
                <p>
                  That identity is anonymous: it carries no Apple ID, device
                  serial, or contact details. Abuse limits use a keyed hash of
                  the connection source, never the raw address. Cloudflare
                  hosts every opencast service and sees connection metadata as
                  any host would.
                </p>
                <DataPathFacts
                  leaves="An App Attest key certified by Apple and short-lived challenges."
                  receiver="opencast's services on Cloudflare."
                  kept="The public key for the life of the install. Delete Data deregisters it."
                />
              </PolicyArticleSection>

              <PolicyArticleSection
                id="your-choices-and-deletion"
                index="11"
                icon={<Lock aria-hidden="true" />}
                title="Your choices and deletion"
              >
                <p>
                  Every cloud feature is opt-in and has an on-device
                  alternative. Turn notifications off in Settings, keep
                  transcription on the device, leave Recap, Ask, and Make a
                  Playlist untapped, or use Delete Data to erase local data
                  and deregister this install from every service.
                </p>
                <p>
                  Email the privacy contact to have service-side records
                  deleted. Some purchase, transaction, fraud-prevention, and
                  accounting records may have to be retained.
                </p>
              </PolicyArticleSection>

              <PolicyArticleSection
                id="what-opencast-never-does"
                index="12"
                icon={<Ban aria-hidden="true" />}
                title="What opencast never does"
              >
                <ul className="policy-list">
                  <li>No ads, and no ad networks.</li>
                  <li>No analytics, crash-reporting, or tracking SDKs.</li>
                  <li>No opencast account, login, or profile.</li>
                  <li>No listening history on an opencast server.</li>
                  <li>No sale of data, no marketing use, no cross-app profiling.</li>
                </ul>
              </PolicyArticleSection>

              <PolicyArticleSection
                id="open-source"
                index="13"
                icon={<CodeXml aria-hidden="true" />}
                title="Open source"
              >
                <p>
                  The app and every opencast service it talks to are open
                  source. Read
                  the code on{" "}
                  <Link href={githubURL} className="font-semibold text-foreground">
                    GitHub
                  </Link>
                  , or open an issue if something on this page looks wrong.
                </p>
              </PolicyArticleSection>

              <PolicyArticleSection
                id="changes-and-contact"
                index="14"
                icon={<Mail aria-hidden="true" />}
                title="Changes and contact"
              >
                <p>
                  Email{" "}
                  <Link
                    href={`mailto:${supportEmail}`}
                    className="font-semibold text-foreground"
                  >
                    {supportEmail}
                  </Link>{" "}
                  with privacy questions. This policy took effect on{" "}
                  {effectiveDate} and was last updated on {lastUpdated}. When it
                  changes, the date changes with it.
                </p>
              </PolicyArticleSection>
            </div>
          </div>
        </div>
      </main>
      <SiteFooter variant="support" />
    </>
  );
}
