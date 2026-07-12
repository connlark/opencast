import { Card, Chip, Link, Separator, Typography } from "@heroui/react";
import {
  ArrowRight,
  AudioWaveform,
  BadgeCheck,
  BookOpen,
  Cloud,
  Headphones,
  Lock,
  Mail,
  Rss,
  Search,
  ShieldCheck,
  Sparkles,
  Zap,
} from "lucide-react";
import { ActionLink } from "@/components/ActionLink";
import { AppStoreBadge } from "@/components/AppStoreBadge";
import { CheckList } from "@/components/CheckList";
import { FeatureCard } from "@/components/FeatureCard";
import { ScreenshotStrip } from "@/components/ScreenshotStrip";
import { SiteFooter } from "@/components/SiteFooter";
import { githubURL, supportEmail } from "@/lib/site";

export default function HomePage() {
  return (
    <>
      <main>
        <section id="home" className="relative isolate overflow-hidden">
          <div
            aria-hidden="true"
            className="ambient-orb pointer-events-none absolute left-1/2 top-[-300px] -z-10 h-[680px] w-[min(1120px,150vw)] -translate-x-1/2 rounded-full"
          />
          <div className="mx-auto flex w-full max-w-5xl flex-col items-center px-4 pb-20 pt-24 text-center sm:px-6 sm:pb-28 sm:pt-32">
            <Chip color="accent" variant="soft" size="lg">
              <Sparkles className="size-4" aria-hidden="true" />
              <Chip.Label>Native iPhone and iPad podcasting</Chip.Label>
            </Chip>
            <Typography.Heading
              level={1}
              align="center"
              className="mt-7 text-7xl font-semibold leading-[0.92] tracking-[-0.07em] sm:text-9xl"
            >
              opencast
            </Typography.Heading>
            <Typography.Paragraph
              color="muted"
              align="center"
              className="mt-7 max-w-2xl text-lg leading-relaxed sm:text-xl"
            >
              A focused podcast client for RSS subscriptions, clean queues,
              streaming playback, private sync, and local listening progress.
            </Typography.Paragraph>
            <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
              <AppStoreBadge />
              <ActionLink href="#screens" variant="outline">
                <Search aria-hidden="true" /> See the app
              </ActionLink>
            </div>
            <div
              className="mt-9 flex flex-wrap justify-center gap-2"
              aria-label="Highlights"
            >
              <Chip color="default" variant="soft" size="lg">
                <BadgeCheck className="size-4" aria-hidden="true" />
                <Chip.Label>Native SwiftUI app</Chip.Label>
              </Chip>
              <Chip color="default" variant="soft" size="lg">
                <Cloud className="size-4" aria-hidden="true" />
                <Chip.Label>Private iCloud sync</Chip.Label>
              </Chip>
              <Chip color="default" variant="soft" size="lg">
                <Rss className="size-4" aria-hidden="true" />
                <Chip.Label>RSS-first listening</Chip.Label>
              </Chip>
            </div>
          </div>
        </section>

        <Separator variant="tertiary" />

        <section id="features" className="bg-background-secondary/70">
          <div className="mx-auto w-full max-w-6xl px-4 py-16 sm:px-6 sm:py-24">
            <div className="grid items-end gap-6 md:grid-cols-[1fr_minmax(260px,0.6fr)] md:gap-16">
              <Typography.Heading
                level={2}
                className="max-w-[13ch] text-4xl font-semibold leading-none tracking-tight sm:text-6xl"
              >
                Built for real <span className="text-accent">listening.</span>
              </Typography.Heading>
              <Typography.Paragraph color="muted" className="leading-relaxed">
                opencast keeps the daily podcast loop fast: add feeds by RSS
                URL, scan new episodes, start playback, and pick up where you
                left off.
              </Typography.Paragraph>
            </div>
            <div className="mt-10 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
              <FeatureCard
                icon={<BookOpen aria-hidden="true" />}
                title="Library and Inbox"
              >
                Subscribe to podcasts, cache episode metadata, and keep new
                releases easy to scan.
              </FeatureCard>
              <FeatureCard
                icon={<Headphones aria-hidden="true" />}
                title="Streaming playback"
              >
                Play episodes directly from the feed with native controls,
                seeking, and resume.
              </FeatureCard>
              <FeatureCard
                icon={<AudioWaveform aria-hidden="true" />}
                title="Sound Lab"
              >
                Dial in the listening surface with artwork, queues, and
                controls that feel at home on iOS.
              </FeatureCard>
              <FeatureCard
                icon={<ShieldCheck aria-hidden="true" />}
                title="Privacy-aware data"
              >
                Subscriptions and progress can sync privately while caches and
                downloads stay local.
              </FeatureCard>
            </div>
          </div>
        </section>

        <Separator variant="tertiary" />

        <section id="screens" className="relative isolate overflow-hidden">
          <div
            aria-hidden="true"
            className="ambient-orb pointer-events-none absolute right-[-220px] top-1/4 -z-10 h-[520px] w-[680px] rounded-full opacity-70"
          />
          <div className="mx-auto w-full max-w-6xl px-4 py-16 sm:px-6 sm:py-24">
            <div className="max-w-2xl">
              <Typography.Heading
                level={2}
                className="text-4xl font-semibold leading-none tracking-tight sm:text-6xl"
              >
                RSS without the <span className="text-accent">clutter.</span>
              </Typography.Heading>
              <Typography.Paragraph
                color="muted"
                className="mt-5 leading-relaxed"
              >
                opencast is intentionally native-first. It uses the system
                media stack, respects your sync choices, and keeps the
                interface centered on subscriptions and episodes.
              </Typography.Paragraph>
              <CheckList
                items={[
                  "Add podcasts by RSS URL and keep stable podcast identities.",
                  "Resume from locally persisted listening progress.",
                  "Use downloaded playback only when you explicitly choose it.",
                ]}
              />
              <div className="mt-8 flex flex-wrap gap-3">
                <ActionLink href="/app-store">
                  <ArrowRight aria-hidden="true" /> Download on the App Store
                </ActionLink>
                <ActionLink href={githubURL} variant="outline">
                  <Zap aria-hidden="true" /> View source
                </ActionLink>
              </div>
            </div>
            <div className="mt-14">
              <ScreenshotStrip />
            </div>
          </div>
        </section>

        <Separator variant="tertiary" />

        <section id="support-privacy" className="bg-background-secondary/70">
          <div className="mx-auto grid w-full max-w-6xl gap-4 px-4 py-16 sm:px-6 sm:py-24 md:grid-cols-2">
            <Card className="h-full border border-border p-0">
              <Card.Header className="flex-row items-center gap-3 px-7 pt-7 sm:px-9 sm:pt-9">
                <span className="grid size-11 shrink-0 place-items-center rounded-2xl bg-accent-soft text-accent-soft-foreground">
                  <Mail className="size-5" aria-hidden="true" />
                </span>
                <Typography.Heading
                  level={2}
                  className="text-2xl font-semibold tracking-tight sm:text-3xl"
                >
                  Support
                </Typography.Heading>
              </Card.Header>
              <Card.Content className="gap-0 px-7 pb-4 pt-2 sm:px-9">
                <Typography.Paragraph color="muted" className="leading-relaxed">
                  Need help with a feed, playback, progress sync, or a crash
                  report? Email{" "}
                  <Link
                    href={`mailto:${supportEmail}`}
                    className="font-semibold text-foreground"
                  >
                    {supportEmail}
                  </Link>{" "}
                  and include the podcast feed URL, your device model, and the
                  opencast version if you have it handy.
                </Typography.Paragraph>
              </Card.Content>
              <Card.Footer className="flex-wrap gap-3 px-7 pb-7 sm:px-9 sm:pb-9">
                <ActionLink href={`mailto:${supportEmail}`} variant="outline">
                  <Mail aria-hidden="true" /> Email support
                </ActionLink>
                <ActionLink href={`${githubURL}/issues`} variant="ghost">
                  <ArrowRight aria-hidden="true" /> Report an issue
                </ActionLink>
              </Card.Footer>
            </Card>

            <Card className="h-full border border-border p-0">
              <Card.Header className="flex-row items-center gap-3 px-7 pt-7 sm:px-9 sm:pt-9">
                <span className="grid size-11 shrink-0 place-items-center rounded-2xl bg-accent-soft text-accent-soft-foreground">
                  <Lock className="size-5" aria-hidden="true" />
                </span>
                <Typography.Heading
                  level={2}
                  className="text-2xl font-semibold tracking-tight sm:text-3xl"
                >
                  Privacy Policy
                </Typography.Heading>
              </Card.Header>
              <Card.Content className="gap-3 px-7 pb-4 pt-2 sm:px-9">
                <Typography.Paragraph color="muted" className="leading-relaxed">
                  opencast is designed around RSS feeds, device-local caches,
                  and private iCloud sync for subscriptions and listening
                  progress when enabled. The app does not need an opencast
                  account, and local downloads remain on your device.
                </Typography.Paragraph>
                <Typography.Paragraph color="muted" className="leading-relaxed">
                  Read the full policy at{" "}
                  <Link href="/privacy" className="font-semibold text-foreground">
                    support.opencast.mobile/privacy
                  </Link>
                  .
                </Typography.Paragraph>
              </Card.Content>
              <Card.Footer className="px-7 pb-7 sm:px-9 sm:pb-9">
                <ActionLink href="/privacy" variant="outline">
                  <ShieldCheck aria-hidden="true" /> Privacy policy
                </ActionLink>
              </Card.Footer>
            </Card>
          </div>
        </section>
      </main>
      <SiteFooter variant="marketing" />
    </>
  );
}
