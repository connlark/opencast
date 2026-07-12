import { Chip, Link, Typography } from "@heroui/react";
import type { Metadata } from "next";
import {
  Bell,
  CodeXml,
  Lock,
  Mail,
  ShieldCheck,
  Smartphone,
} from "lucide-react";
import { ActionLink } from "@/components/ActionLink";
import { PolicySection } from "@/components/PolicySection";
import { SiteFooter } from "@/components/SiteFooter";
import { githubURL, supportEmail, supportHost } from "@/lib/site";

export const metadata: Metadata = {
  title: "opencast privacy policy",
  description:
    "opencast has no ads, tracking SDKs, or account system. The optional developer-run notification service is used only when New Episode Notifications are enabled.",
  alternates: { canonical: `https://${supportHost}/privacy` },
};

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
            opencast has no ads, tracking SDKs, or account system. The optional
            developer-run notification service is used only when New Episode
            Notifications are enabled.
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
            <PolicySection icon={<Lock aria-hidden="true" />} title="What opencast does not do">
              <p>
                opencast does not serve ads, use tracking SDKs or third-party
                analytics SDKs, sell your data, run a developer-run account
                system, or collect listening history on an opencast server.
              </p>
              <p>
                Notification data is not used for ads, tracking, marketing,
                sale, or cross-app profiling.
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
                with privacy questions. Effective date: June 21, 2026.
              </p>
            </PolicySection>
          </div>
        </div>
      </main>
      <SiteFooter variant="support" />
    </>
  );
}
