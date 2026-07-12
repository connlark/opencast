import { buttonVariants, type ButtonVariants } from "@heroui/styles";
import type { ComponentPropsWithoutRef, ReactNode } from "react";

type ActionLinkProps = Omit<
  ComponentPropsWithoutRef<"a">,
  "children" | "className" | "href"
> & {
  children: ReactNode;
  className?: string;
  href: string;
  size?: NonNullable<ButtonVariants["size"]>;
  variant?: NonNullable<ButtonVariants["variant"]>;
};

export function ActionLink({
  children,
  className,
  href,
  size = "lg",
  variant = "primary",
  ...props
}: ActionLinkProps) {
  return (
    <a
      href={href}
      className={buttonVariants({ className, size, variant })}
      {...props}
    >
      {children}
    </a>
  );
}
