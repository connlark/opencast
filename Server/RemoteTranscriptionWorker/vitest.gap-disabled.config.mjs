import { defineConfig } from "vitest/config";
import { workerTestConfig } from "./vitest.config.mjs";

export default defineConfig(() => workerTestConfig({
  include: ["test/gap-repair/disabled.spec.mjs"],
  bindings: {
    DEV_CREDIT_GRANT_SECONDS: "50000",
    WAITING_FOR_DEVICE_SOURCE_DEADLINE_SECONDS: "10",
    GAP_REPAIR_ENABLED: "false",
  },
}));
