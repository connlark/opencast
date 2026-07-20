/**
 * Official Apple App Store badge (white lockup). Per Apple's badge
 * guidelines the artwork is untouched and keeps clear space around it.
 */
export function AppStoreBadge() {
  return (
    <a href="/app-store" className="app-store-badge">
      {/* eslint-disable-next-line @next/next/no-img-element -- official badge asset, no processing */}
      <img
        src="/badges/app-store-badge.svg"
        alt="Download on the App Store"
        width={156}
        height={52}
        className="h-[52px] w-auto"
      />
    </a>
  );
}
