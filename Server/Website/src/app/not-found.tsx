import { Link, Typography } from "@heroui/react";
import { ArrowRight } from "lucide-react";
import { ActionLink } from "@/components/ActionLink";
import { SiteFooter } from "@/components/SiteFooter";

export default function NotFound() {
  return (
    <>
      <main className="relative isolate flex flex-1 items-center overflow-hidden">
        <div
          aria-hidden="true"
          className="ambient-orb pointer-events-none absolute left-1/2 top-[-260px] -z-10 h-[560px] w-[920px] -translate-x-1/2 rounded-full"
        />
        <div className="mx-auto flex w-full max-w-3xl flex-col items-center px-4 py-24 text-center sm:px-6">
          <p className="text-8xl font-semibold tracking-tight text-accent">404</p>
          <Typography.Heading
            level={1}
            align="center"
            className="mt-4 text-3xl font-semibold tracking-tight sm:text-4xl"
          >
            This page drifted out of the feed.
          </Typography.Heading>
          <Typography.Paragraph
            color="muted"
            align="center"
            className="mt-4 max-w-md leading-relaxed"
          >
            The page you were looking for does not exist. Head back to the
            opencast home page, or check{" "}
            <Link href="/support" className="font-semibold text-foreground">
              support
            </Link>
            .
          </Typography.Paragraph>
          <div className="mt-8">
            <ActionLink href="/">
              <ArrowRight aria-hidden="true" /> Back to opencast
            </ActionLink>
          </div>
        </div>
      </main>
      <SiteFooter variant="marketing" />
    </>
  );
}
