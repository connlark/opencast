"use client";

import { Button, Drawer, Surface, useOverlayState } from "@heroui/react";
import { buttonVariants } from "@heroui/styles";
import {
  ArrowUpRight,
  House,
  Images,
  LifeBuoy,
  Menu,
  ShieldCheck,
  Sparkles,
  X,
  type LucideIcon,
} from "lucide-react";
import NextLink from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { marketingURL, supportHost } from "@/lib/site";

type NavKey = "home" | "features" | "screens" | "support" | "privacy";

type NavItem = {
  description: string;
  href: string;
  icon: LucideIcon;
  key: NavKey;
  label: string;
};

const navItems: readonly NavItem[] = [
  {
    key: "home",
    label: "Home",
    description: "Meet opencast",
    href: marketingURL,
    icon: House,
  },
  {
    key: "features",
    label: "Features",
    description: "Built for listening",
    href: `${marketingURL}/#features`,
    icon: Sparkles,
  },
  {
    key: "screens",
    label: "Screens",
    description: "See the app",
    href: `${marketingURL}/#screens`,
    icon: Images,
  },
  {
    key: "support",
    label: "Support",
    description: "Get help",
    href: "/support",
    icon: LifeBuoy,
  },
  {
    key: "privacy",
    label: "Privacy",
    description: "Your data, clearly",
    href: "/privacy",
    icon: ShieldCheck,
  },
] as const;

const desktopNavItems = navItems.filter((item) => item.key !== "home");
const appStoreHref = `${marketingURL}/app-store`;

const desktopNavClass = buttonVariants({
  variant: "ghost",
  size: "sm",
  className: "site-nav__item px-3",
});

const mobileNavClass = buttonVariants({
  variant: "ghost",
  size: "lg",
  fullWidth: true,
  className: "site-mobile-nav__item h-auto min-h-16 justify-start px-3 py-2.5",
});

const desktopCTAClass = buttonVariants({
  variant: "primary",
  size: "md",
  className: "site-nav__cta px-4",
});

const mobileCTAClass = buttonVariants({
  variant: "primary",
  size: "lg",
  fullWidth: true,
  className: "site-nav__cta",
});

function currentAttribute(item: NavItem, isActive: boolean) {
  if (!isActive) {
    return undefined;
  }

  return item.key === "features" || item.key === "screens"
    ? ("location" as const)
    : ("page" as const);
}

function DesktopNavItem({
  item,
  isActive,
}: {
  item: NavItem;
  isActive: boolean;
}) {
  const Icon = item.icon;

  return (
    <NextLink
      href={item.href}
      className={desktopNavClass}
      aria-current={currentAttribute(item, isActive)}
      data-active={isActive || undefined}
    >
      <Icon aria-hidden="true" />
      <span>{item.label}</span>
    </NextLink>
  );
}

function MobileNavItem({
  item,
  isActive,
  onNavigate,
}: {
  item: NavItem;
  isActive: boolean;
  onNavigate: () => void;
}) {
  const Icon = item.icon;

  return (
    <NextLink
      href={item.href}
      className={mobileNavClass}
      aria-current={currentAttribute(item, isActive)}
      data-active={isActive || undefined}
      onClick={onNavigate}
    >
      <span className="site-mobile-nav__icon grid size-10 shrink-0 place-items-center rounded-2xl bg-default text-muted [&_svg]:size-5">
        <Icon aria-hidden="true" />
      </span>
      <span className="min-w-0 text-left">
        <span className="block text-sm font-semibold text-foreground">
          {item.label}
        </span>
        <span className="block text-xs font-normal text-muted">
          {item.description}
        </span>
      </span>
    </NextLink>
  );
}

export function SiteHeader() {
  const pathname = usePathname();
  const drawerState = useOverlayState();
  const [activeItem, setActiveItem] = useState<NavKey | null>(null);

  useEffect(() => {
    function resolveActiveItem() {
      const isSupportHost = window.location.hostname === supportHost;
      const hash = window.location.hash;

      if (pathname === "/privacy") {
        setActiveItem("privacy");
      } else if (pathname === "/support" || isSupportHost) {
        setActiveItem("support");
      } else if (pathname === "/" && hash === "#features") {
        setActiveItem("features");
      } else if (pathname === "/" && hash === "#screens") {
        setActiveItem("screens");
      } else if (pathname === "/") {
        setActiveItem("home");
      } else {
        setActiveItem(null);
      }
    }

    resolveActiveItem();
    window.addEventListener("hashchange", resolveActiveItem);

    return () => window.removeEventListener("hashchange", resolveActiveItem);
  }, [pathname]);

  return (
    <header className="site-header sticky top-0 z-30 px-3 pt-3 sm:px-4">
      <Surface
        variant="default"
        className="site-header__shell mx-auto h-16 w-full max-w-6xl rounded-3xl border border-border px-3 sm:px-4"
      >
        <nav
          className="grid h-full w-full grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-3"
          aria-label="Primary navigation"
        >
          <NextLink
            href={marketingURL}
            className="site-brand flex w-fit min-w-0 items-center gap-2.5 rounded-2xl outline-none focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2 focus-visible:ring-offset-background"
            aria-label="opencast home"
            aria-current={activeItem === "home" ? "page" : undefined}
            data-active={activeItem === "home" || undefined}
          >
            {/* eslint-disable-next-line @next/next/no-img-element -- static export serves plain assets */}
            <img
              src="/app-icon.png"
              alt=""
              width={40}
              height={40}
              className="site-brand__icon size-10 rounded-2xl border border-border"
            />
            <span className="min-w-0 leading-none">
              <span className="block truncate text-sm font-semibold tracking-tight text-foreground sm:text-base">
                opencast
              </span>
              <span className="mt-1 hidden text-[10px] font-medium tracking-[0.08em] text-muted uppercase sm:block">
                iPhone + iPad
              </span>
            </span>
          </NextLink>

          <Surface
            variant="secondary"
            className="site-nav__rail hidden h-11 items-center gap-0.5 rounded-3xl border border-border p-1 min-[820px]:flex"
          >
            {desktopNavItems.map((item) => (
              <DesktopNavItem
                key={item.key}
                item={item}
                isActive={activeItem === item.key}
              />
            ))}
          </Surface>

          <div className="flex items-center justify-self-end">
            <a
              href={appStoreHref}
              className={`${desktopCTAClass} hidden min-[820px]:inline-flex`}
            >
              Get the app
              <ArrowUpRight aria-hidden="true" />
            </a>

            <div className="min-[820px]:hidden">
              <Drawer state={drawerState}>
                <Button
                  aria-label="Open navigation"
                  className="site-mobile-trigger"
                  isIconOnly
                  size="lg"
                  variant="secondary"
                >
                  <Menu aria-hidden="true" />
                </Button>

                <Drawer.Backdrop variant="blur">
                  <Drawer.Content placement="right">
                    <Drawer.Dialog className="site-nav-drawer border-l border-border p-0">
                      <Drawer.CloseTrigger
                        aria-label="Close navigation"
                        className="min-h-11 min-w-11 rounded-2xl"
                      >
                        <X aria-hidden="true" />
                      </Drawer.CloseTrigger>
                      <Drawer.Header className="border-b border-separator px-6 py-5 pr-16">
                        <Drawer.Heading className="text-lg font-semibold tracking-tight">
                          Explore opencast
                        </Drawer.Heading>
                        <p className="text-sm leading-relaxed text-muted">
                          Native podcasting, without the clutter.
                        </p>
                      </Drawer.Header>
                      <Drawer.Body className="px-3 py-4">
                        <nav
                          className="grid gap-1.5"
                          aria-label="Mobile navigation"
                        >
                          {navItems.map((item) => (
                            <MobileNavItem
                              key={item.key}
                              item={item}
                              isActive={activeItem === item.key}
                              onNavigate={drawerState.close}
                            />
                          ))}
                        </nav>
                      </Drawer.Body>
                      <Drawer.Footer className="border-t border-separator p-4">
                        <a
                          href={appStoreHref}
                          className={mobileCTAClass}
                          onClick={drawerState.close}
                        >
                          Get opencast
                          <ArrowUpRight aria-hidden="true" />
                        </a>
                      </Drawer.Footer>
                    </Drawer.Dialog>
                  </Drawer.Content>
                </Drawer.Backdrop>
              </Drawer>
            </div>
          </div>
        </nav>
      </Surface>
    </header>
  );
}
