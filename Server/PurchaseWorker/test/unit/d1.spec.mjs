import { describe, expect, it } from 'vitest';
import { purchaseAccountCount } from '../../src/d1';

describe('D1 query cost guards', () => {
  it('reads the maintained purchase-account counter instead of counting the account table', async () => {
    let preparedSql = '';
    const db = {
      prepare(sql) {
        preparedSql = sql;
        return {
          first: async () => ({ value: 42 }),
        };
      },
    };

    await expect(purchaseAccountCount(db)).resolves.toBe(42);
    expect(preparedSql).toContain('purchase_ops_counters');
    expect(preparedSql).toContain("name = 'purchase_account_count'");
    expect(preparedSql).not.toContain('COUNT(');
    expect(preparedSql).not.toContain('purchase_accounts');
  });
});
