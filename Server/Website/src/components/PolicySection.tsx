import { Card } from "@heroui/react";
import type { ReactNode } from "react";

export function PolicySection({
  icon,
  title,
  wide = false,
  children,
}: {
  icon: ReactNode;
  title: string;
  wide?: boolean;
  children: ReactNode;
}) {
  return (
    <Card
      className={`border border-border p-0 ${
        wide ? "md:col-span-2" : ""
      }`}
    >
      <Card.Header className="flex-row items-center gap-3 px-6 pt-6 sm:px-7 sm:pt-7">
        <span className="grid size-10 shrink-0 place-items-center rounded-2xl bg-accent-soft text-accent-soft-foreground [&_svg]:size-[19px]">
          {icon}
        </span>
        <h2 className="card__title text-lg font-semibold text-foreground">
          {title}
        </h2>
      </Card.Header>
      <Card.Content className="grid gap-3 px-6 pb-6 pt-1 leading-relaxed text-muted sm:px-7 sm:pb-7">
        {children}
      </Card.Content>
    </Card>
  );
}
