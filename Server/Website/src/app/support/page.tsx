import { Chip, Link, Typography } from "@heroui/react";
import type { Metadata } from "next";
import {
  Cloud,
  LifeBuoy,
  ListMusic,
  Mail,
  Rss,
  WandSparkles,
} from "lucide-react";
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
                If Remote Transcription is unavailable, open Settings, choose
                Credits, and choose Try Again. Check your network connection
                and App Store sign-in if it still cannot connect.
              </p>
              <p>
                For a stuck job, missing credit, purchase, or refund issue,
                email support with your opencast version and an approximate
                time of the event. Do not send App Store credentials or signed
                transaction data.
              </p>
            </PolicySection>
            <PolicySection
              icon={<WandSparkles aria-hidden="true" />}
              title="Recap and Ask"
              wide
            >
              <p>
                Recap and Ask appear in the transcript&apos;s Transcript Options
                menu on devices that support Apple Intelligence, once an
                episode has a transcript. Passages from this episode&apos;s
                transcript are sent to Apple&apos;s Private Cloud Compute to
                answer. Apple does not store them. Your audio is never sent.
                Results stay on this device. No opencast server is involved,
                and neither feature uses transcription minutes.
              </p>
              <p>
                Apple&apos;s model may decline a passage; opencast shows a
                short notice and does not retry. Turning off Apple
                Intelligence in iOS Settings stops both features. The{" "}
                <Link
                  href="/privacy#recap-and-ask"
                  className="font-semibold text-foreground"
                >
                  privacy policy
                </Link>{" "}
                has the full data path.
              </p>
            </PolicySection>
            <PolicySection
              icon={<ListMusic aria-hidden="true" />}
              title="Make a Playlist"
              wide
            >
              <p>
                Make a Playlist drafts playlists from one show&apos;s episodes.
                Ask for a playlist in your own words, or let it suggest groups.
                You review the drafts first: rename, reorder, or remove
                playlists and episodes, then save the ones you want as ordinary
                playlists. To find it, open a show&apos;s page and open the
                Podcast Actions menu, or the Playlists screen&apos;s Add menu,
                and choose Make a Playlist… under Apple Intelligence · Beta;
                from the Playlists screen you then pick the show. It appears
                on devices that support Apple Intelligence.
              </p>
              <p>
                The show&apos;s name, its episode titles, dates, lengths and
                short descriptions, and your request are sent to Apple&apos;s
                Private Cloud Compute. Your audio and transcripts are never
                sent, and no opencast server is involved. The feature is
                labelled Beta. If Apple&apos;s model declines a request,
                opencast tries once more before telling you, and you can try
                again. The{" "}
                <Link
                  href="/privacy#ai-playlists"
                  className="font-semibold text-foreground"
                >
                  privacy policy
                </Link>{" "}
                has the full data path.
              </p>
            </PolicySection>
          </div>
        </div>
      </main>
      <SiteFooter variant="support" />
    </>
  );
}
