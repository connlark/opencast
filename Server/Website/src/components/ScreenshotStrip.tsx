import { screenshots } from "@/lib/site";

export function ScreenshotStrip() {
  return (
    <div className="screenshot-strip" aria-label="opencast app screenshots">
      {screenshots.map((shot, index) => (
        <figure className="screenshot-card" key={shot.id}>
          <picture>
            <source
              type="image/avif"
              srcSet={shot.avifSrcSet}
              sizes="(min-width: 900px) 276px, (min-width: 480px) 260px, 72vw"
            />
            <source
              type="image/webp"
              srcSet={shot.webpSrcSet}
              sizes="(min-width: 900px) 276px, (min-width: 480px) 260px, 72vw"
            />
            <img
              src={shot.src}
              alt={shot.alt}
              width={shot.width}
              height={shot.height}
              loading={index < 2 ? "eager" : "lazy"}
              decoding="async"
              className="block h-auto w-full"
            />
          </picture>
        </figure>
      ))}
    </div>
  );
}
