import { ArrowUpRight } from "lucide-react";
import NextLink from "next/link";
import { marketingURL } from "@/lib/site";

const appStoreHref = `${marketingURL}/app-store`;

const navigation = [
  { href: `${marketingURL}/#features`, label: "Why opencast" },
  { href: `${marketingURL}/#screens`, label: "Inside the app" },
  { href: "/support", label: "Support" },
  { href: "/privacy", label: "Privacy" },
] as const;

export function SiteHeader() {
  return (
    <header className="site-header sticky top-0 z-30">
      <div className="site-header__primary mx-auto flex h-[68px] w-full max-w-7xl items-center gap-4 px-4 sm:px-6 lg:px-8">
        <NextLink
          href={marketingURL}
          className="site-brand flex min-w-0 items-center gap-2.5 rounded-xl outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2 focus-visible:ring-offset-background"
          aria-label="opencast home"
        >
          {/* The app icon's Default and Dark renditions, matched to the
              system appearance. Both come from `yarn sync-brand-assets`. */}
          <picture>
            <source
              srcSet="/brand/icon-dark-192.png"
              media="(prefers-color-scheme: dark)"
            />
            <img
              src="/brand/icon-light-192.png"
              alt=""
              width={42}
              height={42}
              className="site-brand__icon size-[42px] shrink-0 rounded-[13px]"
            />
          </picture>
          <span className="truncate text-base font-semibold tracking-[-0.025em] text-foreground">
            opencast
          </span>
        </NextLink>

        <nav
          className="site-header__desktop-nav ml-auto hidden items-center gap-1 min-[720px]:flex"
          aria-label="Primary navigation"
        >
          {navigation.map((item) => (
            <NextLink key={item.href} href={item.href} className="site-header__link">
              {item.label}
            </NextLink>
          ))}
        </nav>

        <a href={appStoreHref} className="site-header__cta ml-auto min-[720px]:ml-2">
          <span>Get the app</span>
          <ArrowUpRight aria-hidden="true" />
        </a>
      </div>

      <nav
        className="site-header__mobile-nav mx-auto flex h-11 w-full items-stretch overflow-x-auto px-2 min-[720px]:hidden"
        aria-label="Page navigation"
      >
        {navigation.slice(0, 3).map((item) => (
          <NextLink key={item.href} href={item.href} className="site-header__mobile-link">
            {item.label}
          </NextLink>
        ))}
      </nav>
    </header>
  );
}
