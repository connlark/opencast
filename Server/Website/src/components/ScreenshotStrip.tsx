import { Card, ScrollShadow } from "@heroui/react";
import { screenshots } from "@/lib/site";

const offsets = [
  "",
  "sm:translate-y-7",
  "sm:translate-y-2",
  "sm:translate-y-9",
  "sm:translate-y-4",
];

export function ScreenshotStrip() {
  return (
    <ScrollShadow
      orientation="horizontal"
      hideScrollBar
      className="-mx-4 flex snap-x snap-mandatory gap-4 px-4 pb-12 pt-3 sm:-mx-6 sm:px-6"
      aria-label="opencast app screenshots"
    >
      {screenshots.map((shot, index) => (
        <Card
          key={shot.src}
          variant="secondary"
          className={`w-[min(58vw,232px)] shrink-0 snap-start overflow-hidden border border-border p-0 shadow-surface ${offsets[index % offsets.length]}`}
        >
          {/* eslint-disable-next-line @next/next/no-img-element -- static export serves plain assets */}
          <img
            src={shot.src}
            alt={shot.alt}
            loading={index < 2 ? "eager" : "lazy"}
            decoding="async"
            className="w-full"
          />
        </Card>
      ))}
    </ScrollShadow>
  );
}
