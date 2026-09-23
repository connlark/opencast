import { BRAND_ICON_DARK, BRAND_ICON_LIGHT } from "../shared/urls.ts";

// Server/Website/src/app/globals.css --background, light and dark.
export const THEME_COLOR_LIGHT = "#fbf7f2";
export const THEME_COLOR_DARK = "#0a0e18";

/** The app icon from opencast.mobile, following the system appearance. Decorative. */
export function BrandMark({ size, className }: { size: number; className?: string }) {
  return (
    <picture>
      <source media="(prefers-color-scheme: dark)" srcSet={BRAND_ICON_DARK} />
      <img src={BRAND_ICON_LIGHT} alt="" width={size} height={size} className={className ? `rounded-[22%] ${className}` : "rounded-[22%]"} />
    </picture>
  );
}
