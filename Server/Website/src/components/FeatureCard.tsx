import { Card } from "@heroui/react";
import type { ReactNode } from "react";

export function FeatureCard({
  icon,
  title,
  children,
}: {
  icon: ReactNode;
  title: string;
  children: ReactNode;
}) {
  return (
    <Card
      role="article"
      className="h-full border border-border p-0 transition-colors hover:border-accent/40 hover:bg-surface-secondary"
    >
      <Card.Header className="gap-0 p-6">
        <span className="mb-5 grid size-11 place-items-center rounded-2xl bg-accent-soft text-accent-soft-foreground [&_svg]:size-5">
          {icon}
        </span>
        <Card.Title className="text-lg font-semibold text-foreground">
          {title}
        </Card.Title>
        <Card.Description className="mt-2.5 text-base leading-relaxed text-muted">
          {children}
        </Card.Description>
      </Card.Header>
    </Card>
  );
}
