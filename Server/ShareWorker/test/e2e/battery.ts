// The layout battery: measurements taken in the page, turned into findings
// here. Screenshots will not show a 2px overflow or a 40px tap target; numbers
// do. Hidden, aria-hidden and screen-reader-only nodes are skipped but counted,
// so a jump in what was skipped is itself visible in the attached report.

export interface Measurements {
  viewport: { width: number; height: number };
  colorScheme: { prefersDark: boolean; bodyBackground: string; bodyBackgroundRGB: number[] };
  overflow: { documentScrollWidth: number; pageOverflowPx: number; pannablePx: number; offenders: Offender[] };
  gutters: { rows: { role: string; contentLeft: number; contentRight: number }[]; leftSpreadPx: number; rightSpreadPx: number };
  iconOnly: IconControl[];
  targets: { small: Target[]; zeroSize: Target[]; offscreen: Target[]; overlapping: [Target, Target][]; doubleTapZooms: Target[] };
  skipped: { notRendered: number; screenReaderOnly: number; inlineLinks: number };
  brokenImages: { selector: string; src: string; width: number; height: number }[];
}

interface Offender { selector: string; right: number; overshootPx: number; text: string }
interface Target { selector: string; label: string; left: number; top: number; width: number; height: number }
interface IconControl { selector: string; label: string; dxPx: number; dyPx: number; display: string }

export interface Finding { kind: string; summary: string; evidence: unknown }

/** Runs in the page; must stay self-contained. */
export function measure(): Measurements {
  const round = (n: number) => Math.round(n * 100) / 100;
  const vw = document.documentElement.clientWidth;
  const describe = (el: Element) => {
    const parts: string[] = [];
    let node: Element | null = el;
    for (let i = 0; node && i < 4; i += 1) {
      let part = node.tagName.toLowerCase();
      if (node.id) {
        parts.unshift(`${part}#${node.id}`);
        break;
      }
      const label = node.getAttribute("aria-label");
      if (label) part += `[aria-label="${label}"]`;
      const cls = (node.getAttribute("class") ?? "").split(/\s+/).filter(Boolean).slice(0, 2).join(".");
      if (cls) part += `.${cls}`;
      parts.unshift(part);
      node = node.parentElement;
    }
    return parts.join(" > ");
  };
  const isRendered = (el: Element) => el.checkVisibility({ checkVisibilityCSS: true } as CheckVisibilityOptions);
  const isInert = (el: Element) => {
    for (let a: Element | null = el; a; a = a.parentElement) {
      if (a.getAttribute("aria-hidden") === "true" || a.hasAttribute("inert")) return true;
    }
    return false;
  };
  // Tailwind's sr-only: 1px box, clipped.
  const isScreenReaderOnly = (el: Element) => {
    const cs = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    return (cs.clip !== "auto" && cs.clip !== "" && r.width <= 1) || (cs.clipPath.includes("inset(50%)") && r.width <= 1);
  };
  // Inside a box that scrolls or clips on x (an sr-only label clips its own text).
  const clippedFrom = (start: Element | null) => {
    for (let a = start; a && a !== document.body; a = a.parentElement) {
      if (["auto", "scroll", "hidden", "clip"].includes(getComputedStyle(a).overflowX)) return true;
    }
    return false;
  };
  const scrollsX = (el: Element) => clippedFrom(el.parentElement);
  const label = (el: Element) =>
    (el.getAttribute("aria-label") ?? (el.textContent ?? "").replace(/\s+/g, " ").trim()).slice(0, 50);

  const de = document.documentElement;
  // The document's own width, not body's: a clipping body still reports the
  // overflow it clips in its scrollWidth.
  const scroller = document.scrollingElement ?? de;
  const documentScrollWidth = scroller.scrollWidth;
  // body's overflow clips body itself only when html's is not visible;
  // otherwise it moves to the viewport and the document still grows.
  const bodyClips =
    getComputedStyle(de).overflowX !== "visible" && ["hidden", "clip"].includes(getComputedStyle(document.body).overflowX);
  // What a thumb can actually do: can the document be panned sideways?
  const { scrollLeft: savedLeft, scrollTop: savedTop } = scroller;
  scroller.scrollLeft = 100_000;
  const pannablePx = scroller.scrollLeft;
  scroller.scrollTo(savedLeft, savedTop);
  const offenders: Offender[] = [];
  for (const el of document.querySelectorAll("body *")) {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0 || r.right <= vw + 1) continue;
    // aria-hidden decoration still widens the page, so it is not skipped here.
    if (getComputedStyle(el).position === "fixed" || scrollsX(el) || bodyClips) continue;
    offenders.push({
      selector: describe(el),
      right: round(r.right),
      overshootPx: round(r.right - vw),
      text: (el.textContent ?? "").trim().slice(0, 60),
    });
  }

  // Text that spills out of its box (an unbreakable title) widens the page
  // without widening any element's own rect, so text is measured separately.
  // A clipping body does not excuse it: the words are cut off at the edge.
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const parent = node.parentElement;
    if (!parent || !(node.textContent ?? "").trim() || !isRendered(parent) || clippedFrom(parent)) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    const r = range.getBoundingClientRect();
    if (r.width === 0 || (r.right <= vw + 1 && r.left >= -1)) continue;
    offenders.push({
      selector: `${describe(parent)} (text)`,
      right: round(r.right),
      overshootPx: round(Math.max(r.right - vw, -r.left)),
      text: (node.textContent ?? "").trim().slice(0, 60),
    });
  }

  // header, main and footer share one gutter: their content edges line up.
  const rows = ["body > header", "main#app", "body > footer"]
    .map((selector) => [selector, document.querySelector(selector)] as const)
    .filter((entry): entry is readonly [string, Element] => entry[1] !== null && isRendered(entry[1]))
    .map(([role, el]) => {
      const r = el.getBoundingClientRect();
      const cs = getComputedStyle(el);
      return {
        role,
        contentLeft: round(r.left + parseFloat(cs.paddingLeft)),
        contentRight: round(r.right - parseFloat(cs.paddingRight)),
      };
    });
  // Computed colours come back as oklch(); a 1px canvas converts to sRGB.
  const toRGB = (color: string) => {
    const canvas = document.createElement("canvas");
    canvas.width = 1;
    canvas.height = 1;
    const context = canvas.getContext("2d")!;
    context.fillStyle = color;
    context.fillRect(0, 0, 1, 1);
    return [...context.getImageData(0, 0, 1, 1).data].slice(0, 3);
  };
  const spread = (values: number[]) => (values.length ? round(Math.max(...values) - Math.min(...values)) : 0);

  const iconOnly: IconControl[] = [];
  const small: Target[] = [];
  const zeroSize: Target[] = [];
  const offscreen: Target[] = [];
  const measured: { el: Element; target: Target }[] = [];
  // iOS Safari turns two quick taps into a zoom unless some box from the
  // control up to the root sets a touch-action other than auto.
  const doubleTapZooms: Target[] = [];
  const guardsDoubleTap = (el: Element) => {
    for (let a: Element | null = el; a; a = a.parentElement) {
      if (getComputedStyle(a).touchAction !== "auto") return true;
    }
    return false;
  };
  const skipped = { notRendered: 0, screenReaderOnly: 0, inlineLinks: 0 };
  const interactive = document.querySelectorAll(
    'a[href], button, input:not([type="hidden"]), select, textarea, summary, [role="button"], [tabindex]:not([tabindex="-1"])',
  );
  for (const el of interactive) {
    if (!isRendered(el) || isInert(el)) {
      skipped.notRendered += 1;
      continue;
    }
    if (isScreenReaderOnly(el)) {
      skipped.screenReaderOnly += 1;
      continue;
    }
    const r = el.getBoundingClientRect();
    const target: Target = {
      selector: describe(el),
      label: label(el),
      left: round(r.left),
      top: round(r.top),
      width: round(r.width),
      height: round(r.height),
    };
    if (r.width === 0 || r.height === 0) {
      zeroSize.push(target);
      continue;
    }
    if ((r.right < 0 || r.left > vw) && !scrollsX(el)) offscreen.push(target);
    // WCAG 2.5.8 exempts a link inline in a sentence.
    if (el.tagName === "A" && getComputedStyle(el).display === "inline") {
      skipped.inlineLinks += 1;
    } else if (r.width < 43.5 || r.height < 43.5) {
      small.push(target);
    }
    measured.push({ el, target });
    if (!guardsDoubleTap(el)) doubleTapZooms.push(target);

    // An icon-only control paints its one glyph at its own centre. Text in
    // an sr-only child is a label, not content.
    const svgs = [...el.querySelectorAll("svg")].filter(isRendered);
    const visibleText = [...el.querySelectorAll("*")]
      .filter((child) => child.children.length === 0 && child.tagName !== "svg" && !child.closest("svg"))
      .filter((child) => isRendered(child) && !isScreenReaderOnly(child))
      .map((child) => (child.textContent ?? "").trim())
      .join("");
    const ownText = [...el.childNodes]
      .filter((node) => node.nodeType === Node.TEXT_NODE)
      .map((node) => (node.textContent ?? "").trim())
      .join("");
    if (svgs.length === 1 && visibleText === "" && ownText === "") {
      const s = svgs[0]!.getBoundingClientRect();
      iconOnly.push({
        selector: target.selector,
        label: target.label,
        dxPx: round(s.left + s.width / 2 - (r.left + r.width / 2)),
        dyPx: round(s.top + s.height / 2 - (r.top + r.height / 2)),
        display: getComputedStyle(el).display,
      });
    }
  }

  // Two controls whose boxes intersect: a tap lands on whichever is on top.
  const overlapping: [Target, Target][] = [];
  for (let i = 0; i < measured.length; i += 1) {
    for (let j = i + 1; j < measured.length; j += 1) {
      const a = measured[i]!;
      const b = measured[j]!;
      if (a.el.contains(b.el) || b.el.contains(a.el)) continue;
      const ra = a.el.getBoundingClientRect();
      const rb = b.el.getBoundingClientRect();
      const w = Math.min(ra.right, rb.right) - Math.max(ra.left, rb.left);
      const h = Math.min(ra.bottom, rb.bottom) - Math.max(ra.top, rb.top);
      if (w > 1 && h > 1) overlapping.push([a.target, b.target]);
    }
  }

  const brokenImages = [...document.images]
    .filter((img) => isRendered(img) && img.complete && img.naturalWidth === 0 && img.getBoundingClientRect().width > 0)
    .map((img) => {
      const r = img.getBoundingClientRect();
      return { selector: describe(img), src: img.currentSrc || img.src, width: round(r.width), height: round(r.height) };
    });

  return {
    viewport: { width: vw, height: window.innerHeight },
    colorScheme: {
      prefersDark: matchMedia("(prefers-color-scheme: dark)").matches,
      bodyBackground: getComputedStyle(document.body).backgroundColor,
      bodyBackgroundRGB: toRGB(getComputedStyle(document.body).backgroundColor),
    },
    overflow: {
      documentScrollWidth,
      pageOverflowPx: round(documentScrollWidth - vw),
      pannablePx: round(pannablePx),
      offenders: offenders.slice(0, 20),
    },
    gutters: {
      rows,
      leftSpreadPx: spread(rows.map((row) => row.contentLeft)),
      rightSpreadPx: spread(rows.map((row) => row.contentRight)),
    },
    iconOnly,
    targets: { small, zeroSize, offscreen, overlapping, doubleTapZooms },
    skipped,
    brokenImages,
  };
}

export function judge(m: Measurements): Finding[] {
  const findings: Finding[] = [];
  const add = (kind: string, summary: string, evidence: unknown) => findings.push({ kind, summary, evidence });

  if (m.overflow.pageOverflowPx > 1 || m.overflow.pannablePx > 1 || m.overflow.offenders.length > 0) {
    add(
      "horizontal-overflow",
      `page is ${m.overflow.pageOverflowPx}px wider than the viewport and pans ${m.overflow.pannablePx}px sideways`,
      m.overflow.offenders,
    );
  }
  if (m.gutters.leftSpreadPx > 1 || m.gutters.rightSpreadPx > 1) {
    add("gutter-misalignment", `header/main/footer content edges differ by ${m.gutters.leftSpreadPx}/${m.gutters.rightSpreadPx}px`, m.gutters.rows);
  }
  for (const c of m.iconOnly) {
    if (Math.abs(c.dxPx) > 1 || Math.abs(c.dyPx) > 1) {
      add("icon-not-centred", `icon in "${c.label}" is off centre by ${c.dxPx}x/${c.dyPx}y px (display: ${c.display})`, c);
    }
  }
  for (const t of m.targets.zeroSize) add("zero-size-control", `"${t.label}" has no painted box`, t);
  for (const t of m.targets.offscreen) add("offscreen-control", `"${t.label}" sits outside the viewport`, t);
  for (const t of m.targets.small) add("small-tap-target", `"${t.label}" is ${t.width}x${t.height}, under 44x44`, t);
  for (const [a, b] of m.targets.overlapping) add("overlapping-controls", `"${a.label}" overlaps "${b.label}"`, [a, b]);
  if (m.targets.doubleTapZooms.length > 0) {
    add("double-tap-zoom", `${m.targets.doubleTapZooms.length} controls let a quick double tap zoom the page`, m.targets.doubleTapZooms.map((t) => t.label));
  }
  for (const img of m.brokenImages) add("broken-image", `a broken image is painted at ${img.width}x${img.height}`, img);
  return findings;
}
