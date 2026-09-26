import { defineConfig } from "vitest/config";

// Plain node environment: parsing, classification and alerting are pure
// functions over injected fetch/AI stubs, and the email() handler is driven
// with a fake ForwardableEmailMessage. No workerd pool is needed.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
  },
});
