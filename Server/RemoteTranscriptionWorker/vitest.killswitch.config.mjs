// Purchase kill switch (decision 12) + limiter daily spend cap: env-level
// flags need their own worker environment, so this config reruns the shared
// purchase harness with PURCHASES_ENABLED=false and a tiny AI spend cap.
import { defineConfig } from "vitest/config";
import { makePurchaseConfig } from "./vitest.purchase.shared.mjs";

export default defineConfig(() =>
  makePurchaseConfig({
    include: ["test/killswitch/*.spec.mjs"],
    extraBindings: {
      PURCHASES_ENABLED: "false",
      // 1000 micro-USD admits at most 120 s of audio: any real job trips
      // the limiter spend cap on its first chunk.
      DAILY_SPEND_CAP_USD_MICRO: "1000",
    },
  }),
);
