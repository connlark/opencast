import { Chip, Link, Typography } from "@heroui/react";
import type { Metadata } from "next";
import {
  Bell,
  Cloud,
  CodeXml,
  Lock,
  Mail,
  ShieldCheck,
  Smartphone,
} from "lucide-react";
import { ActionLink } from "@/components/ActionLink";
import { PolicySection } from "@/components/PolicySection";
import { SiteFooter } from "@/components/SiteFooter";
import { createPageMetadata } from "@/lib/metadata";
import { githubURL, supportEmail, supportHost } from "@/lib/site";

export const metadata: Metadata = createPageMetadata({
  title: "opencast privacy policy",
  description:
    "opencast has no ads, tracking SDKs, or account sign-in. Optional notification and remote transcription services run only when you enable or request them.",
  url: `https://${supportHost}/privacy`,
});

export default function PrivacyPage() {
  return (
    <>
      <main className="relative isolate overflow-hidden">
        <div
          aria-hidden="true"
          className="ambient-orb pointer-events-none absolute left-[-180px] top-[-240px] -z-10 h-[560px] w-[760px] rounded-full"
        />
        <div className="mx-auto w-full max-w-4xl px-4 pb-20 pt-14 sm:px-6 sm:pt-20">
          <Chip color="accent" variant="soft" size="lg">
            <Lock className="size-4" aria-hidden="true" />
            <Chip.Label>Privacy</Chip.Label>
          </Chip>
          <Typography.Heading
            level={1}
            className="mt-6 max-w-[12ch] text-5xl font-semibold leading-[0.95] tracking-tight sm:text-7xl"
          >
            Privacy <span className="text-accent">Policy</span>
          </Typography.Heading>
          <Typography.Paragraph
            color="muted"
            className="mt-5 max-w-2xl text-lg leading-relaxed"
          >
            opencast has no ads, tracking SDKs, or account sign-in. Optional
            notification and remote transcription services run only when you
            enable or request them.
          </Typography.Paragraph>
          <div className="mt-7">
            <ActionLink href={`mailto:${supportEmail}`}>
              <Mail aria-hidden="true" /> Ask a privacy question
            </ActionLink>
          </div>
          <div className="mt-12 grid gap-4 md:grid-cols-2">
            <PolicySection icon={<Smartphone aria-hidden="true" />} title="On your device">
              <p>
                opencast stores subscriptions, episode lists, playback
                progress, cached feeds, downloads, preferences, and
                notification settings so the app can work.
              </p>
            </PolicySection>
            <PolicySection icon={<ShieldCheck aria-hidden="true" />} title="Sync and network">
              <p>
                If iCloud sync is enabled, Apple may sync subscriptions and
                listening progress. Podcast feeds, audio, artwork, and
                directory or search requests go to the services needed to load
                them.
              </p>
            </PolicySection>
            <PolicySection icon={<Bell aria-hidden="true" />} title="Notifications" wide>
              <p>
                New Episode Notifications are off unless you enable them in
                Settings and grant iOS notification permission.
              </p>
              <ul className="grid list-disc gap-2.5 pl-5">
                <li>
                  When enabled, opencast sends your active podcast feed URLs
                  and APNs notification token to the opencast notification
                  service.
                </li>
                <li>
                  Feed URLs are used only to poll subscribed feeds and decide
                  whether to send a new episode notification.
                </li>
                <li>
                  Private RSS URLs may include access tokens from the podcast
                  provider. opencast stores the URL only so notification
                  polling works.
                </li>
                <li>
                  The backend stores an install-scoped identifier, App Attest
                  security metadata, APNs token state, feed polling metadata,
                  and notification send and dedupe logs.
                </li>
                <li>
                  Disabling notifications unregisters the device token and
                  disables notification subscriptions for that install.
                </li>
                <li>
                  Deleting app data or reinstalling may create a new
                  install-scoped identifier.
                </li>
                <li>
                  Apple APNs and Cloudflare are involved as infrastructure
                  providers for notification delivery.
                </li>
              </ul>
            </PolicySection>
            <PolicySection
              icon={<Cloud aria-hidden="true" />}
              title="Remote transcription"
              wide
            >
              <p>
                Remote Transcription is optional and runs only after you choose
                it for an episode. Transcription can also run entirely on your
                device without using this service.
              </p>
              <ul className="grid list-disc gap-2.5 pl-5">
                <li>
                  The service normally downloads the episode audio from its
                  podcast source. If it cannot obtain the same audio, the app
                  may upload the exact local episode audio after you request
                  remote transcription.
                </li>
                <li>
                  Audio is split into temporary chunks and processed by
                  Cloudflare Workers AI to create the transcript. Cloudflare
                  provides the service infrastructure and model processing.
                </li>
                <li>
                  Source audio, uploads, chunks, and model responses are kept
                  in private storage only while the job needs them and are
                  explicitly deleted during normal cleanup. One-day lifecycle
                  rules provide a deletion backstop.
                </li>
                <li>
                  A completed transcript is deleted after the app receives and
                  acknowledges it. A seven-day lifecycle rule is the backstop
                  if acknowledgment or cleanup does not complete.
                </li>
                <li>
                  The service retains operational records such as a stable
                  service identifier, keyed source hashes, job state and
                  timing, usage, security checks, and cleanup evidence. It does
                  not keep a permanent server-side library of your audio or
                  transcripts.
                </li>
              </ul>
            </PolicySection>
            <PolicySection
              icon={<ShieldCheck aria-hidden="true" />}
              title="Purchases and security"
              wide
            >
              <p>
                Remote Transcription uses Apple App Attest and Apple-signed app
                and purchase information to verify the app, prevent fraud,
                credit purchased transcription time, handle refunds, and keep
                an accurate balance. Apple and Cloudflare are involved as
                infrastructure providers.
              </p>
              <p>
                Purchase, credit, refund, reconciliation, and security records
                may be retained as needed to operate the paid service, protect
                it from abuse, and meet legal or accounting obligations.
              </p>
            </PolicySection>
            <PolicySection
              icon={<Lock aria-hidden="true" />}
              title="Your choices and deletion"
            >
              <p>
                You can use on-device transcription instead of Remote
                Transcription, cancel an active remote job, and disable New
                Episode Notifications at any time.
              </p>
              <p>
                Email the privacy contact to request deletion of service data.
                Some purchase, transaction, fraud-prevention, security, or
                accounting records may need to be retained.
              </p>
            </PolicySection>
            <PolicySection icon={<Lock aria-hidden="true" />} title="What opencast does not do">
              <p>
                opencast does not serve ads, use tracking SDKs or third-party
                analytics SDKs, sell your data, require an opencast login or
                profile, or collect listening history on an opencast server.
              </p>
              <p>
                Notification and remote transcription data are not used for
                ads, tracking, marketing, sale, or cross-app profiling.
              </p>
            </PolicySection>
            <PolicySection icon={<CodeXml aria-hidden="true" />} title="Open source">
              <p>
                Anyone can audit the app code on{" "}
                <Link href={githubURL} className="font-semibold text-foreground">
                  GitHub
                </Link>
                .
              </p>
            </PolicySection>
            <PolicySection icon={<Mail aria-hidden="true" />} title="Privacy contact" wide>
              <p>
                Email{" "}
                <Link
                  href={`mailto:${supportEmail}`}
                  className="font-semibold text-foreground"
                >
                  {supportEmail}
                </Link>{" "}
                with privacy questions. Effective date: June 21, 2026. Last
                updated: July 18, 2026.
              </p>
            </PolicySection>
          </div>
        </div>
      </main>
      <SiteFooter variant="support" />
    </>
  );
}
