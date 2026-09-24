import { useRef, useState, type MouseEvent, type PointerEvent, type ReactNode } from "react";
import { Icon } from "./Icon.tsx";

export const SPEEDS = [0.75, 1, 1.25, 1.5, 1.75, 2];

// Thresholds from the app's Sound Lab artwork (NowPlayingSoundLabArtwork).
const DRAG_DISTANCE = 0.54;
const OPEN_AT = 0.22;
const OPEN_PREDICTED_AT = 0.3;
const CLOSE_BELOW = 0.52;
const CLOSE_PREDICTED_BELOW = 0.36;
// How far a flick carries past the release point, in milliseconds of velocity.
const FLICK_MS = 150;

interface Drag {
  pointer: number;
  x: number;
  y: number;
  base: number;
  tracking: boolean;
  lastX: number;
  lastTime: number;
  velocity: number;
}

interface ArtworkStageProps {
  /** The artwork image, or the fallback tile. */
  children: ReactNode;
  open: boolean;
  onOpenChange(open: boolean): void;
  rate: number;
  onRate(rate: number): void;
  panelID: string;
}

/**
 * The artwork square, which opens like the app's Sound Lab: a tap or a left
 * drag slides the art aside to a rail and reveals the speed panel on the
 * square; a tap on the rail or a right drag closes it. `--reveal` (0 to 1)
 * drives every transform in styles.css, so a drag follows the finger and a
 * release springs by transition.
 */
export function ArtworkStage({ children, open, onOpenChange, rate, onRate, panelID }: ArtworkStageProps) {
  const stageRef = useRef<HTMLDivElement>(null);
  const drag = useRef<Drag | null>(null);
  const draggedRecently = useRef(false);
  const [dragProgress, setDragProgress] = useState<number | null>(null);
  const reveal = dragProgress ?? (open ? 1 : 0);

  const width = () => (stageRef.current?.clientWidth ?? 288) * DRAG_DISTANCE;

  const onPointerDown = (event: PointerEvent) => {
    // A mouse drag is followed by a click, a touch drag is not: clear the
    // guard at the start of every gesture so it never eats the next tap.
    draggedRecently.current = false;
    if (event.button !== 0) {
      return;
    }
    drag.current = {
      pointer: event.pointerId,
      x: event.clientX,
      y: event.clientY,
      base: open ? 1 : 0,
      tracking: false,
      lastX: event.clientX,
      lastTime: event.timeStamp,
      velocity: 0,
    };
  };

  const onPointerMove = (event: PointerEvent) => {
    const current = drag.current;
    if (!current || current.pointer !== event.pointerId) {
      return;
    }
    const dx = event.clientX - current.x;
    const dy = event.clientY - current.y;
    if (!current.tracking) {
      // Vertical movement belongs to the page (touch-action: pan-y).
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) {
        drag.current = null;
        return;
      }
      if (Math.abs(dx) < 6) {
        return;
      }
      current.tracking = true;
      stageRef.current?.setPointerCapture(event.pointerId);
    }
    const elapsed = event.timeStamp - current.lastTime;
    if (elapsed > 0) {
      current.velocity = (event.clientX - current.lastX) / elapsed;
    }
    current.lastX = event.clientX;
    current.lastTime = event.timeStamp;
    setDragProgress(clamp01(current.base - dx / width()));
  };

  const onPointerUp = (event: PointerEvent) => {
    const current = drag.current;
    drag.current = null;
    if (!current || current.pointer !== event.pointerId || !current.tracking) {
      return;
    }
    draggedRecently.current = true;
    const progress = clamp01(current.base - (event.clientX - current.x) / width());
    const predicted = clamp01(progress - (current.velocity * FLICK_MS) / width());
    const shouldOpen =
      current.base === 1
        ? !(progress < CLOSE_BELOW || predicted < CLOSE_PREDICTED_BELOW)
        : progress > OPEN_AT || predicted > OPEN_PREDICTED_AT;
    setDragProgress(null);
    onOpenChange(shouldOpen);
  };

  // A scroll or system gesture took the pointer: settle where it started.
  const onPointerCancel = () => {
    drag.current = null;
    setDragProgress(null);
  };

  const onClick = (event: MouseEvent) => {
    if (draggedRecently.current) {
      draggedRecently.current = false;
      return;
    }
    if (!open) {
      onOpenChange(true);
      return;
    }
    // Open: only the visible strip of art closes it; the panel keeps its taps.
    const stage = stageRef.current;
    const panelTap = (event.target as Element).closest?.("button");
    if (stage && !panelTap && event.clientX - stage.getBoundingClientRect().left < railWidth(stage)) {
      onOpenChange(false);
    }
  };

  return (
    <div
      ref={stageRef}
      className="art-stage relative aspect-square w-72 max-w-[80vw] overflow-hidden rounded-2xl shadow-2xl ring-1 ring-black/10 md:w-80"
      data-dragging={dragProgress === null ? undefined : ""}
      style={{ "--reveal": String(reveal) } as Record<string, string>}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerCancel}
      onClick={onClick}
    >
      <div id={panelID} role="group" aria-label="Playback speed" inert={!open} className="art-stage__panel absolute inset-0">
        <div aria-hidden="true" className="art-stage__grip absolute inset-y-0 left-0 flex flex-col items-center justify-center gap-2">
          {Array.from({ length: 12 }, (_, index) => (
            <span key={index} className="block h-[11px] w-[3px] rounded-full bg-current opacity-15" />
          ))}
        </div>
        <div className="art-stage__content flex h-full flex-col justify-center gap-3">
          <p className="flex items-center gap-2 text-sm font-semibold">
            <span className="art-stage__icon text-amber-400">
              <Icon name="gauge" size={18} />
            </span>
            Playback speed
          </p>
          <div className="grid grid-cols-3 gap-1.5">
            {SPEEDS.map((speed) => (
              <button
                key={speed}
                type="button"
                aria-pressed={speed === rate}
                onClick={() => onRate(speed)}
                className={`flex min-h-11 items-center justify-center rounded-full text-sm font-semibold tabular-nums ${
                  speed === rate ? "bg-cta text-cta-ink" : "bg-surface/60 ring-1 ring-border"
                }`}
              >
                {speed}×
              </button>
            ))}
          </div>
        </div>
      </div>
      <div className="art-stage__art absolute inset-0">{children}</div>
    </div>
  );
}

function railWidth(stage: HTMLElement): number {
  return Math.min(54, Math.max(40, stage.clientWidth * 0.18));
}

function clamp01(value: number): number {
  return Math.min(1, Math.max(0, value));
}
