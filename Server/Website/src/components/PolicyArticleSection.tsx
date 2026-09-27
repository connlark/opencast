import { Chip } from "@heroui/react";
import type { ReactNode } from "react";
import { SectionLink } from "@/components/SectionLink";

export type PolicyTag = {
  label: string;
  /** `accent` marks the user's own switch (opt-in); `default` names a processor. */
  tone?: "accent" | "default";
};

/**
 * One numbered section of the privacy policy: icon, index, the parties that
 * handle the data as chips, a linkable heading, and the body. The heading's
 * text stays clean for `aria-labelledby`; the permalink sits beside it.
 */
export function PolicyArticleSection({
  id,
  index,
  icon,
  title,
  tags,
  children,
}: {
  id: string;
  index: string;
  icon: ReactNode;
  title: string;
  tags?: readonly PolicyTag[];
  children: ReactNode;
}) {
  return (
    <section id={id} aria-labelledby={`${id}-heading`} className="policy-section">
      <div className="policy-section__head">
        <span className="policy-section__icon">{icon}</span>
        <p className="policy-section__index">{index}</p>
        {tags && tags.length > 0 ? (
          <ul className="policy-section__tags" aria-label="Who handles this data">
            {tags.map((tag) => (
              <li key={tag.label}>
                <Chip size="sm" variant="soft" color={tag.tone ?? "default"}>
                  <Chip.Label>{tag.label}</Chip.Label>
                </Chip>
              </li>
            ))}
          </ul>
        ) : null}
      </div>
      <div className="policy-section__title-row">
        <h2 id={`${id}-heading`} className="policy-section__title">
          {title}
        </h2>
        <SectionLink id={id} title={title} />
      </div>
      <div className="policy-section__body">{children}</div>
    </section>
  );
}
