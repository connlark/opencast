import { Chip, Link, Typography } from "@heroui/react";
import type { Metadata } from "next";
import {
  ArrowUpRight,
  Check,
  FlaskConical,
  Mail,
  Smartphone,
} from "lucide-react";
import { ActionLink } from "@/components/ActionLink";
import { PolicySection } from "@/components/PolicySection";
import { SiteFooter } from "@/components/SiteFooter";
import { createPageMetadata } from "@/lib/metadata";
import {
  marketingURL,
  supportEmail,
  testFlightURL,
} from "@/lib/site";

export const metadata: Metadata = createPageMetadata({
  title: "opencast TestFlight beta",
  description:
    "Join the opencast TestFlight beta and try upcoming podcast features on iPhone and iPad.",
  url: `${marketingURL}/testflight`,
});

export default function TestFlightPage() {
  return (
    <>
      <main className="relative isolate overflow-hidden">
        <div
          aria-hidden="true"
          className="ambient-orb pointer-events-none absolute left-[-180px] top-[-240px] -z-10 h-[560px] w-[760px] rounded-full"
        />
        <div className="mx-auto w-full max-w-4xl px-4 pb-20 pt-14 sm:px-6 sm:pt-20">
          <Chip color="accent" variant="soft" size="lg">
            <FlaskConical className="size-4" aria-hidden="true" />
            <Chip.Label>TestFlight beta</Chip.Label>
          </Chip>
          <Typography.Heading
            level={1}
            className="mt-6 max-w-[12ch] text-5xl font-semibold leading-[0.95] tracking-tight sm:text-7xl"
          >
            Help shape the next <span className="text-accent">opencast</span>
          </Typography.Heading>
          <Typography.Paragraph
            color="muted"
            className="mt-5 max-w-2xl text-lg leading-relaxed"
          >
            Try upcoming features on your iPhone or iPad and send feedback
            before they reach the App Store.
          </Typography.Paragraph>
          <div className="mt-7">
            <ActionLink href={testFlightURL}>
              Join the beta <ArrowUpRight aria-hidden="true" />
            </ActionLink>
          </div>
          <Typography.Paragraph
            color="muted"
            className="mt-3 text-sm"
          >
            Opens the TestFlight invitation.
          </Typography.Paragraph>

          <div className="mt-12 grid gap-4 md:grid-cols-2">
            <PolicySection
              icon={<Smartphone aria-hidden="true" />}
              title="Install in a few taps"
            >
              <ol className="grid list-none gap-3 p-0">
                <li className="flex gap-3">
                  <Check
                    className="mt-0.5 size-5 shrink-0 text-accent"
                    aria-hidden="true"
                  />
                  Open the invitation on the iPhone or iPad where you want to
                  test opencast.
                </li>
                <li className="flex gap-3">
                  <Check
                    className="mt-0.5 size-5 shrink-0 text-accent"
                    aria-hidden="true"
                  />
                  Install Apple&apos;s TestFlight app if you do not already
                  have it.
                </li>
                <li className="flex gap-3">
                  <Check
                    className="mt-0.5 size-5 shrink-0 text-accent"
                    aria-hidden="true"
                  />
                  Accept the invitation, then tap Install in TestFlight.
                </li>
              </ol>
            </PolicySection>
            <PolicySection
              icon={<Mail aria-hidden="true" />}
              title="Share what you find"
            >
              <p>
                Beta builds may contain unfinished features or rough edges.
                Send feedback through TestFlight or email{" "}
                <Link
                  href={`mailto:${supportEmail}`}
                  className="font-semibold text-foreground"
                >
                  {supportEmail}
                </Link>
                .
              </p>
            </PolicySection>
          </div>
        </div>
      </main>
      <SiteFooter variant="marketing" />
    </>
  );
}
