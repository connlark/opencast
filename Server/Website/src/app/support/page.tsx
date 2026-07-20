import { Chip, Link, Typography } from "@heroui/react";
import type { Metadata } from "next";
import { Cloud, LifeBuoy, Mail, Rss } from "lucide-react";
import { ActionLink } from "@/components/ActionLink";
import { PolicySection } from "@/components/PolicySection";
import { SiteFooter } from "@/components/SiteFooter";
import { createPageMetadata } from "@/lib/metadata";
import { githubIssueURL, supportEmail, supportHost } from "@/lib/site";

export const metadata: Metadata = createPageMetadata({
  title: "opencast support",
  description: "Support for the opencast podcast app.",
  url: `https://${supportHost}`,
});

export default function SupportPage() {
  return (
    <>
      <main className="relative isolate overflow-hidden">
        <div
          aria-hidden="true"
          className="ambient-orb pointer-events-none absolute left-[-180px] top-[-240px] -z-10 h-[560px] w-[760px] rounded-full"
        />
        <div className="mx-auto w-full max-w-4xl px-4 pb-20 pt-14 sm:px-6 sm:pt-20">
          <Chip color="accent" variant="soft" size="lg">
            <LifeBuoy className="size-4" aria-hidden="true" />
            <Chip.Label>Support</Chip.Label>
          </Chip>
          <Typography.Heading
            level={1}
            className="mt-6 max-w-[12ch] text-5xl font-semibold leading-[0.95] tracking-tight sm:text-7xl"
          >
            Help with <span className="text-accent">opencast</span>
          </Typography.Heading>
          <Typography.Paragraph
            color="muted"
            className="mt-5 max-w-xl text-lg leading-relaxed"
          >
            Support for the opencast podcast app.
          </Typography.Paragraph>
          <div className="mt-7">
            <ActionLink href={`mailto:${supportEmail}`}>
              <Mail aria-hidden="true" /> {supportEmail}
            </ActionLink>
          </div>
          <div className="mt-12 grid gap-4 md:grid-cols-2">
            <PolicySection icon={<LifeBuoy aria-hidden="true" />} title="Contact">
              <p>
                Email{" "}
                <Link
                  href={`mailto:${supportEmail}`}
                  className="font-semibold text-foreground"
                >
                  {supportEmail}
                </Link>{" "}
                for help, bug reports, App Store questions, or privacy requests.
              </p>
              <p>
                Prefer GitHub?{" "}
                <Link href={githubIssueURL} className="font-semibold text-foreground">
                  Open an issue
                </Link>
                .
              </p>
            </PolicySection>
            <PolicySection icon={<Rss aria-hidden="true" />} title="Helpful details">
              <p>
                For app issues, include your device, iOS version, opencast
                version, and the RSS URL if a feed is involved.
              </p>
            </PolicySection>
            <PolicySection
              icon={<Cloud aria-hidden="true" />}
              title="Remote Transcription"
              wide
            >
              <p>
                Remote Transcription is optional and separate from the
                on-device transcript model. Open the episode menu and choose
                Transcribe Remotely; opencast shows the estimated time and your
                balance before it starts.
              </p>
              <p>
                If Remote Transcription is unavailable, open Settings, find
                Remote Transcription, and choose Try Again. Check your network
                connection and App Store sign-in if it still cannot connect.
              </p>
              <p>
                For a stuck job, missing credit, purchase, or refund issue,
                email support with your opencast version and an approximate
                time of the event. Do not send App Store credentials or signed
                transaction data.
              </p>
            </PolicySection>
          </div>
        </div>
      </main>
      <SiteFooter variant="support" />
    </>
  );
}
