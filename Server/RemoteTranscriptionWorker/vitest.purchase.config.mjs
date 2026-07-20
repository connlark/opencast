import { defineConfig } from "vitest/config";
import { makePurchaseConfig } from "./vitest.purchase.shared.mjs";

export default defineConfig(() =>
  makePurchaseConfig({ include: ["test/purchase/*.spec.mjs"] }),
);
