import { BadgeCheck } from "lucide-react";

export function CheckList({ items }: { items: readonly string[] }) {
  return (
    <ul className="mt-6 grid gap-3.5">
      {items.map((item) => (
        <li key={item} className="flex items-start gap-3 leading-relaxed">
          <span className="mt-0.5 grid size-6 shrink-0 place-items-center rounded-full bg-accent-soft text-accent-soft-foreground">
            <BadgeCheck className="size-4" aria-hidden="true" />
          </span>
          <span className="text-foreground">{item}</span>
        </li>
      ))}
    </ul>
  );
}
