// `react-dom/client` resolves here in the build (alias.ts). preact/compat's
// hydrate reconciles the container's existing children, which is what
// React's hydrateRoot does for a body root.
import type { ReactNode } from "react";
import { hydrate } from "preact/compat";

export function hydrateRoot(container: Element, children: ReactNode): void {
  hydrate(children as Parameters<typeof hydrate>[0], container);
}
