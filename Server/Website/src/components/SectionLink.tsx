"use client";

import { Link, Tooltip } from "@heroui/react";
import { Check, Link as LinkIcon } from "lucide-react";
import { useEffect, useRef, useState } from "react";

const copiedDurationMs = 1800;

async function writeToClipboard(text: string) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // Insecure contexts and some embedded browsers have no async clipboard.
    // The legacy path still works on a user gesture.
    const scratch = document.createElement("textarea");
    scratch.value = text;
    scratch.setAttribute("readonly", "");
    scratch.style.position = "fixed";
    scratch.style.opacity = "0";
    document.body.append(scratch);
    scratch.select();
    let copied = false;
    try {
      copied = document.execCommand("copy");
    } catch {
      copied = false;
    }
    scratch.remove();
    return copied;
  }
}

/**
 * The per-section permalink on long-form pages. It is a real anchor, so a
 * plain click or keyboard activation updates the address bar and scrolls the
 * section under the sticky header; the click also puts the absolute URL on
 * the clipboard so the link can be pasted straight away. React Aria closes
 * the tooltip on press, so copy feedback is an inline label and an icon swap
 * for everyone, plus a live region for screen readers.
 */
export function SectionLink({ id, title }: { id: string; title: string }) {
  const [copied, setCopied] = useState(false);
  const resetTimer = useRef<number | undefined>(undefined);

  useEffect(() => () => window.clearTimeout(resetTimer.current), []);

  const copyLink = async () => {
    const url = new URL(`#${id}`, window.location.href).toString();
    if (!(await writeToClipboard(url))) {
      // The anchor still navigated, so the address bar carries the link.
      return;
    }
    setCopied(true);
    window.clearTimeout(resetTimer.current);
    resetTimer.current = window.setTimeout(() => setCopied(false), copiedDurationMs);
  };

  return (
    <span className="policy-section__link-slot" data-copied={copied ? "true" : undefined}>
      <Tooltip delay={350} closeDelay={80}>
        <Link
          href={`#${id}`}
          onPress={copyLink}
          aria-label={`Copy link to ${title}`}
          className="policy-section__link no-underline"
        >
          {copied ? <Check aria-hidden="true" /> : <LinkIcon aria-hidden="true" />}
        </Link>
        <Tooltip.Content placement="top" className="policy-section__tooltip">
          Copy link to this section
        </Tooltip.Content>
      </Tooltip>
      <span className="policy-section__copied" aria-hidden="true">
        Copied
      </span>
      <span role="status" aria-live="polite" className="sr-only">
        {copied ? "Link copied" : ""}
      </span>
    </span>
  );
}
