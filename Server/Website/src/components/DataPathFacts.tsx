import type { ReactNode } from "react";

/**
 * The three questions every cloud section answers at a glance. The prose
 * carries the detail; this keeps the answers scannable and comparable from
 * one section to the next.
 */
export function DataPathFacts({
  leaves,
  receiver,
  kept,
}: {
  leaves: ReactNode;
  receiver: ReactNode;
  kept: ReactNode;
}) {
  return (
    <dl className="policy-facts">
      <div className="policy-facts__item">
        <dt>What leaves your device</dt>
        <dd>{leaves}</dd>
      </div>
      <div className="policy-facts__item">
        <dt>Who receives it</dt>
        <dd>{receiver}</dd>
      </div>
      <div className="policy-facts__item">
        <dt>How long it is kept</dt>
        <dd>{kept}</dd>
      </div>
    </dl>
  );
}
