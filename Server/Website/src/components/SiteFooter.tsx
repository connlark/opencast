import { Link, Separator } from "@heroui/react";
import { githubURL, marketingURL } from "@/lib/site";

const linkClass =
  "text-sm font-medium text-muted no-underline transition-colors hover:text-foreground";

export function SiteFooter({ variant }: { variant: "marketing" | "support" }) {
  return (
    <footer className="mt-auto bg-background">
      <Separator variant="tertiary" />
      <div className="mx-auto flex w-full max-w-6xl flex-wrap items-center justify-between gap-4 px-4 py-9 sm:px-6">
        <p className="text-sm text-muted">opencast for iPhone and iPad.</p>
        <div className="flex flex-wrap gap-5 text-sm">
          {variant === "marketing" ? (
            <>
              <Link href="/app-store" className={linkClass}>
                App Store
              </Link>
              <Link href="/support" className={linkClass}>
                Support
              </Link>
              <Link href="/privacy" className={linkClass}>
                Privacy
              </Link>
              <Link href={githubURL} className={linkClass}>
                GitHub
              </Link>
            </>
          ) : (
            <>
              <Link href={marketingURL} className={linkClass}>
                App
              </Link>
              <Link href="/support" className={linkClass}>
                Support
              </Link>
              <Link href="/privacy" className={linkClass}>
                Privacy
              </Link>
            </>
          )}
        </div>
      </div>
    </footer>
  );
}
