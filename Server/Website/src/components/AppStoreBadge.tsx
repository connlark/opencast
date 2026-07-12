import { buttonVariants } from "@heroui/styles";

/**
 * Official Apple App Store badge (white lockup). Per Apple's badge
 * guidelines the artwork is untouched and gets clear space of at least
 * one-quarter of the badge height on all sides.
 */
export function AppStoreBadge() {
  return (
    <a
      href="/app-store"
      className={buttonVariants({
        variant: "ghost",
        size: "lg",
        className: "h-auto p-[13px]",
      })}
    >
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
