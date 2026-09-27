"use client";

import { useEffect, useState } from "react";

export type PolicyTocItem = { readonly id: string; readonly label: string };

/**
 * Which section is "current" while reading: the last section whose top has
 * passed a marker a little below the sticky header. Near the end of the page
 * the final section wins even when it is too short to reach the marker.
 */
function useCurrentSection(items: readonly PolicyTocItem[]) {
  const [currentId, setCurrentId] = useState<string | null>(null);

  useEffect(() => {
    const sections = items
      .map((item) => document.getElementById(item.id))
      .filter((element): element is HTMLElement => element !== null);
    if (sections.length === 0) return;

    let frame = 0;
    const update = () => {
      frame = 0;
      const marker = window.innerHeight * 0.3;
      let current: string | null = null;
      for (const section of sections) {
        if (section.getBoundingClientRect().top <= marker) {
          current = section.id;
        } else {
          break;
        }
      }
      const atBottom =
        window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
      if (atBottom) current = sections[sections.length - 1].id;
      setCurrentId(current);
    };
    const schedule = () => {
      if (frame === 0) frame = window.requestAnimationFrame(update);
    };

    update();
    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    return () => {
      window.cancelAnimationFrame(frame);
      window.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
    };
  }, [items]);

  return currentId;
}

/** The sticky sidebar table of contents, with the section being read marked. */
export function PolicyTocSidebar({ items }: { items: readonly PolicyTocItem[] }) {
  const currentId = useCurrentSection(items);

  return (
    <nav aria-label="On this page" className="policy-toc hidden lg:block">
      <p className="policy-toc__eyebrow">On this page</p>
      <ul className="policy-toc__list">
        {items.map((item) => (
          <li key={item.id}>
            <a
              href={`#${item.id}`}
              className="policy-toc__link"
              aria-current={item.id === currentId ? "location" : undefined}
            >
              {item.label}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  );
}
