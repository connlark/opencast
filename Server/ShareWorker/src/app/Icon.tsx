const PATHS = {
  play: "M8 5.14v13.72a1 1 0 0 0 1.52.85l10.9-6.86a1 1 0 0 0 0-1.7L9.52 4.29A1 1 0 0 0 8 5.14Z",
  pause: "M7 5h3.5v14H7zM13.5 5H17v14h-3.5z",
  back: "M12 5V2L7 6l5 4V7a6 6 0 1 1-6 6H4a8 8 0 1 0 8-8Z",
  forward: "M12 5V2l5 4-5 4V7a6 6 0 1 0 6 6h2a8 8 0 1 1-8-8Z",
  download: "M12 3v12m0 0 4.5-4.5M12 15l-4.5-4.5M4 17v3h16v-3",
  share: "M12 3v12M12 3 7.5 7.5M12 3l4.5 4.5M6 11H5v10h14V11h-1",
} as const;

const STROKED = new Set<keyof typeof PATHS>(["download", "share"]);

/** Decorative: every control that uses one also carries a text label. */
export function Icon({ name, size = 22 }: { name: keyof typeof PATHS; size?: number }) {
  const stroked = STROKED.has(name);
  return (
    <svg
      aria-hidden="true"
      focusable="false"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill={stroked ? "none" : "currentColor"}
      stroke={stroked ? "currentColor" : "none"}
      strokeWidth={stroked ? 2 : undefined}
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d={PATHS[name]} />
    </svg>
  );
}
