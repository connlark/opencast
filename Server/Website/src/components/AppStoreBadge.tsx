/**
 * Official Apple App Store badge. Apple's guidelines call for the black lockup
 * on light backgrounds and the white lockup on dark ones, so the badge follows
 * the system appearance alongside the rest of the page. Both files are copied
 * verbatim from `vendor/apple-app-store-badges/US/` — the artwork is untouched
 * and keeps clear space around it.
 */
export function AppStoreBadge() {
  return (
    <a href="/app-store" className="app-store-badge">
      <picture>
        <source
          srcSet="/badges/app-store-badge-white.svg"
          media="(prefers-color-scheme: dark)"
        />
        <img
          src="/badges/app-store-badge-black.svg"
          alt="Download on the App Store"
          width={156}
          height={52}
          className="h-[52px] w-auto"
        />
      </picture>
    </a>
  );
}
