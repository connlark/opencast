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
  Lock,
  Mail,
  Rss,
  ShieldCheck,
  Smartphone,
  Sparkles,
} from "lucide-react";
import type { ReactNode } from "react";
import { ActionLink } from "@/components/ActionLink";
import { SiteFooter } from "@/components/SiteFooter";
import { createPageMetadata } from "@/lib/metadata";
import { githubURL, supportEmail, supportHost } from "@/lib/site";

export const metadata: Metadata = createPageMetadata({
  title: "opencast privacy policy",
  description:
    "opencast has no ads, no tracking, and no account. Nearly everything happens on your phone; this page lists the few things that leave it, why, and for how long.",
  url: `https://${supportHost}/privacy`,
});

const tocItems = [
  { id: "short-version", label: "The short version" },
  { id: "on-your-device", label: "On your device" },
  { id: "icloud-sync", label: "iCloud sync" },
  { id: "feeds-audio-and-search", label: "Feeds, audio, artwork, and search" },
  { id: "new-episode-notifications", label: "New Episode Notifications" },
  { id: "cloud-transcription", label: "Cloud transcription" },
  { id: "ad-detection-and-chapters", label: "Ad detection and Chapters & Summary" },
  { id: "purchases", label: "Purchases" },
  { id: "how-services-verify-the-app", label: "How services verify the app" },
  { id: "your-choices-and-deletion", label: "Your choices and deletion" },
  { id: "what-opencast-never-does", label: "What opencast never does" },
  { id: "open-source", label: "Open source" },
  { id: "changes-and-contact", label: "Changes and contact" },
] as const;

function PolicyTocLinks({ className, linkClassName }: { className: string; linkClassName: string }) {
  return (
    <ul className={className}>
      {tocItems.map((item) => (
        <li key={item.id}>
          <a href={`#${item.id}`} className={linkClassName}>
            {item.label}
          </a>
        </li>
      ))}
    </ul>
  );
}

function PolicySection({
  id,
  index,
  icon,
  title,
  children,
}: {
  id: string;
  index: string;
  icon: ReactNode;
  title: string;
  children: ReactNode;
}) {
  return (
    <section id={id} aria-labelledby={`${id}-heading`} className="policy-section">
      <div className="policy-section__head">
        <span className="policy-section__icon">{icon}</span>
        <p className="policy-section__index">{index}</p>
      </div>
      <h2 id={`${id}-heading`} className="policy-section__title">
        {title}
      </h2>
      <div className="policy-section__body">{children}</div>
    </section>
  );
}

export default function PrivacyPage() {
  return (
    <>
      <main className="relative isolate overflow-hidden">
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
              opencast has no ads, no tracking, and no account. Nearly everything
              it does happens on your phone. This page lists the few things that
              leave it, why, and for how long.
            </Typography.Paragraph>
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
                  No ads, no analytics or tracking SDKs, no opencast account,
                  and nothing is sold or shared for marketing.
                </span>
              </li>
              <li>
                <Check aria-hidden="true" />
                <span>
                  Your subscriptions and listening history stay on your device.
                  iCloud sync, if you use it, moves them through your own Apple
                  account and never through an opencast server.
                </span>
              </li>
              <li>
                <Check aria-hidden="true" />
                <span>
                  Cloud features are opt-in. When you use one, opencast sends
                  only what that job needs and deletes it when the job is done.
                </span>
              </li>
              <li>
                <Check aria-hidden="true" />
                <span>
                  The app and every service it talks to are open source, so you
                  can check these claims against the code.
                </span>
              </li>
            </ul>
          </section>

          <PolicyTocLinks
            className="policy-toc-mobile flex gap-2 lg:hidden"
            linkClassName="policy-toc-mobile__link"
          />

          <div className="policy-layout lg:grid lg:grid-cols-[13rem_minmax(0,1fr)] lg:items-start lg:gap-16">
            <nav aria-label="On this page" className="policy-toc hidden lg:block">
              <p className="policy-toc__eyebrow">On this page</p>
              <PolicyTocLinks className="policy-toc__list" linkClassName="policy-toc__link" />
            </nav>

            <div className="policy-article">
              <PolicySection
                id="on-your-device"
                index="01"
                icon={<Smartphone aria-hidden="true" />}
                title="On your device"
              >
                <p>
                  opencast stores subscriptions, episode lists, playback progress,
                  downloads, transcripts, ad-break analyses, generated chapters and
                  summaries, feed and artwork caches, downloaded Whisper models,
                  and your settings on the device. Nothing in that list is sent
                  anywhere by default.
                </p>
                <p>
                  Settings › Delete Data removes all of it and tells opencast&apos;s
                  services to forget the install. Your iOS device backup may
                  include this data under Apple&apos;s terms.
                </p>
              </PolicySection>

              <PolicySection
                id="icloud-sync"
                index="02"
                icon={<Cloud aria-hidden="true" />}
                title="iCloud sync"
              >
                <p>
                  If your device is signed in to iCloud, opencast syncs
                  subscriptions and listening progress through your private iCloud
                  database so your other devices pick them up. Apple stores that
                  data under its own privacy policy; opencast has no server in the
                  path and cannot see it.
                </p>
                <p>
                  Signing out of iCloud, or turning off iCloud for opencast in iOS
                  Settings, stops sync. The app keeps working locally.
                </p>
              </PolicySection>

              <PolicySection
                id="feeds-audio-and-search"
                index="03"
                icon={<Rss aria-hidden="true" />}
                title="Feeds, audio, artwork, and search"
              >
                <p>
                  Like any podcast app, opencast fetches feeds, audio, and artwork
                  directly from each show&apos;s hosting provider. Those providers
                  see your IP address and the app&apos;s version string, and some
                  insert ads based on where you appear to be.
                </p>
                <p>
                  Search terms go to Apple&apos;s podcast directory and, through
                  opencast&apos;s directory service, to Podcast Index. The
                  directory service passes queries straight through: it does not
                  persist or log them, its cache keys are hashed, and it forwards
                  no client address.
                </p>
                <p>
                  Whisper models and the in-app Help pages are plain file
                  downloads from opencast&apos;s own hosts. Those requests carry no
                  identifiers beyond the app&apos;s version string.
                </p>
              </PolicySection>

              <PolicySection
                id="new-episode-notifications"
                index="04"
                icon={<Bell aria-hidden="true" />}
                title="New Episode Notifications"
              >
                <p>
                  Notifications are off until you turn them on in Settings and
                  allow them in iOS. When on, opencast registers this install with
                  its notification service and sends the feed URLs you follow plus
                  the device&apos;s push token.
                </p>
                <ul className="policy-list">
                  <li>
                    The service polls those feeds and sends a push when a new
                    episode appears. It stores accepted feed URLs, compact show
                    metadata, latest-episode identity, poll state, and the send
                    records it uses to avoid duplicates.
                  </li>
                  <li>
                    Private feed URLs can contain your provider&apos;s access
                    token. opencast stores the URL only so polling works.
                  </li>
                  <li>
                    The service does not store raw feed content, show notes, email
                    addresses, Apple IDs, or IP addresses.
                  </li>
                  <li>
                    Turning notifications off disables the push token and stops the
                    subscriptions. Delete Data deletes the install record
                    entirely.
                  </li>
                  <li>
                    Apple Push Notification service and Cloudflare deliver and host
                    the service.
                  </li>
                </ul>
              </PolicySection>

              <PolicySection
                id="cloud-transcription"
                index="05"
                icon={<AudioLines aria-hidden="true" />}
                title="Cloud transcription"
              >
                <p>
                  Transcribe Remotely and cloud Detect Ads are optional, and the
                  same work can run entirely on your device. When you choose the
                  cloud, opencast&apos;s transcription service fetches the
                  episode&apos;s audio from its podcast host, or takes an upload of
                  your local copy if the host serves different bytes, and
                  transcribes it with Whisper on Cloudflare Workers AI.
                </p>
                <ul className="policy-list">
                  <li>
                    Source audio, uploads, chunks, and model output live in private
                    storage only while the job runs and are deleted at each stage.
                    One-day lifecycle rules are the backstop.
                  </li>
                  <li>
                    The finished transcript is deleted once the app confirms it
                    received it, with a seven-day backstop.
                  </li>
                  <li>
                    Episode URLs are encrypted at rest and cleared when staging
                    finishes. Logs and records carry keyed hashes, job state,
                    timing, and usage counts, never audio or text.
                  </li>
                  <li>The service keeps no library of your audio or transcripts.</li>
                </ul>
              </PolicySection>

              <PolicySection
                id="ad-detection-and-chapters"
                index="06"
                icon={<Sparkles aria-hidden="true" />}
                title="Ad detection and Chapters &amp; Summary"
              >
                <p>
                  Detect Ads and Chapters &amp; Summary send transcript text, never
                  audio, to opencast&apos;s analysis services, which use
                  Google&apos;s Gemini models to find ad breaks or write chapters
                  and a summary. This also applies to on-device ad detection: the
                  transcript is made on your phone and only its text is analyzed.
                </p>
                <ul className="policy-list">
                  <li>
                    The episode and show titles may be sent as context. Full
                    transcripts and raw model responses are held in memory for the
                    run and never written to storage.
                  </li>
                  <li>
                    Finished results, meaning ad spans with short evidence quotes,
                    chapter titles, and summaries, are kept for up to 24 hours so
                    the app can collect them, then purged. Failed runs are cleared
                    within 30 minutes.
                  </li>
                  <li>
                    Google processes the text under its Gemini API terms. opencast
                    keeps no copy of it.
                  </li>
                  <li>
                    Usage limits are tracked per anonymous install with daily
                    counters that clear after 48 hours.
                  </li>
                </ul>
              </PolicySection>

              <PolicySection
                id="purchases"
                index="07"
                icon={<CreditCard aria-hidden="true" />}
                title="Purchases"
              >
                <p>
                  Transcription credits are one-time App Store purchases. Apple
                  handles payment, and opencast never sees your name, email, or
                  card.
                </p>
                <ul className="policy-list">
                  <li>
                    opencast&apos;s purchase service verifies Apple-signed app and
                    transaction records, keeps a per-account ledger of credits,
                    reservations, refunds, and the one-time free hour, and answers
                    balance queries. Accounts are keyed by an Apple-issued app
                    transaction identifier, not by you.
                  </li>
                  <li>
                    Refunds are requested through Apple. A refunded pack is removed
                    from the ledger and can leave a balance owed.
                  </li>
                  <li>
                    Purchase, credit, refund, reconciliation, and fraud-prevention
                    records are retained as long as needed to run the paid service
                    and meet accounting and legal obligations.
                  </li>
                </ul>
              </PolicySection>

              <PolicySection
                id="how-services-verify-the-app"
                index="08"
                icon={<ShieldCheck aria-hidden="true" />}
                title="How services verify the app"
              >
                <p>
                  Every opencast service accepts requests only from a genuine copy
                  of the app, using Apple App Attest. Each install generates its
                  own key that Apple certifies; the services store that public key
                  and short-lived challenge hashes.
                </p>
                <p>
                  This identity is anonymous: it carries no Apple ID, device
                  serial, or contact details. Abuse limits use a keyed hash of the
                  connection source, never the raw address. Cloudflare hosts all
                  opencast services and sees connection metadata as any host
                  would.
                </p>
              </PolicySection>

              <PolicySection
                id="your-choices-and-deletion"
                index="09"
                icon={<Lock aria-hidden="true" />}
                title="Your choices and deletion"
              >
                <p>
                  Every cloud feature is opt-in and has an on-device alternative.
                  Turn notifications off in Settings, keep transcription on the
                  device, or use Delete Data to erase local data and deregister the
                  install from every service.
                </p>
                <p>
                  Email the privacy contact to have service-side records deleted.
                  Some purchase, transaction, fraud-prevention, and accounting
                  records may need to be retained.
                </p>
              </PolicySection>

              <PolicySection
                id="what-opencast-never-does"
                index="10"
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
              </PolicySection>

              <PolicySection
                id="open-source"
                index="11"
                icon={<CodeXml aria-hidden="true" />}
                title="Open source"
              >
                <p>
                  The app and every service it talks to are open source. Read the
                  code on{" "}
                  <Link href={githubURL} className="font-semibold text-foreground">
                    GitHub
                  </Link>
                  , or open an issue if something here looks wrong.
                </p>
              </PolicySection>

              <section
                id="changes-and-contact"
                aria-labelledby="changes-and-contact-heading"
                className="policy-closing"
              >
                <h2 id="changes-and-contact-heading" className="policy-closing__title">
                  Changes and contact
                </h2>
                <p>
                  Email{" "}
                  <Link
                    href={`mailto:${supportEmail}`}
                    className="font-semibold text-foreground"
                  >
                    {supportEmail}
                  </Link>{" "}
                  with privacy questions. Effective date: June 21, 2026. Last
                  updated: September 24, 2026. When this policy changes, the date
                  changes with it.
                </p>
              </section>
            </div>
          </div>
        </div>
      </main>
      <SiteFooter variant="support" />
    </>
  );
}
