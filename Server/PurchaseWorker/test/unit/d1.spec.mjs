import { describe, expect, it } from 'vitest';
import { purchaseAccountCount, purchaseAccountIdsAfter, reconciliationDue } from '../../src/d1';

// Records every prepared statement and its bound values; `results` feeds `all()`.
function recordingDb(results) {
  const statements = [];
  return {
    statements,
    prepare(sql) {
      const statement = { sql, values: [] };
      statements.push(statement);
      return {
        bind(...values) {
          statement.values = values;
          return this;
        },
        first: async () => ({ value: 42 }),
        all: async () => ({ results }),
      };
    },
  };
}

describe('D1 query cost guards', () => {
  it('joins the due account rows into the reconciliation query instead of re-reading each account', async () => {
    const db = recordingDb([
      {
        app_tx_hmac: 'hmac-1',
        account_id: 'pacct-1',
        app_transaction_id_encrypted: 'enc-1',
        environment: 'Sandbox',
        status: 'active',
        revision_cursor: 'rev-3',
      },
    ]);

    const due = await reconciliationDue(db, 1_700_000_000, 20);
    expect(db.statements).toHaveLength(1);
    expect(db.statements[0].sql).toContain('JOIN purchase_accounts');
    expect(db.statements[0].sql).toContain('LIMIT ?2');
    expect(db.statements[0].values).toEqual([1_700_000_000, 20]);
    expect(due).toEqual([
      {
        account: {
          app_tx_hmac: 'hmac-1',
          account_id: 'pacct-1',
          app_transaction_id_encrypted: 'enc-1',
          environment: 'Sandbox',
          status: 'active',
        },
        revision_cursor: 'rev-3',
      },
    ]);
  });

  it('pages the liability sweep by account_id cursor rather than reading every account', async () => {
    const db = recordingDb([{ account_id: 'pacct-b' }, { account_id: 'pacct-c' }]);

    await expect(purchaseAccountIdsAfter(db, null, 200)).resolves.toEqual(['pacct-b', 'pacct-c']);
    expect(db.statements[0].sql).not.toContain('WHERE');
    expect(db.statements[0].sql).toContain('ORDER BY account_id ASC LIMIT ?1');
    expect(db.statements[0].values).toEqual([200]);

    await purchaseAccountIdsAfter(db, 'pacct-a', 200);
    expect(db.statements[1].sql).toContain('WHERE account_id > ?1');
    expect(db.statements[1].sql).toContain('LIMIT ?2');
    expect(db.statements[1].values).toEqual(['pacct-a', 200]);
  });

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
