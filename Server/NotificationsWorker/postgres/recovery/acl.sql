-- Privilege readback, read-only. Every privilege on this database, on schema
-- opencast and on every relation, column and function in it, as exploded ACL
-- entries: acl|<kind>|<object>|<grantee>|<grantor>|<privilege>|<grantable>.
-- An object whose ACL is NULL (owner defaults) prints aclnull|<kind>|<object>.
-- With psql variable runtime_role, also every object on which that role holds
-- a write privilege (writable|<kind>|<object>) and their count.
\pset format unaligned
\pset tuples_only on
SELECT x.line FROM (
  SELECT 'acl|database|' || d.datname || '|' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
         || '|' || pg_get_userbyid(a.grantor)::text || '|' || a.privilege_type || '|' || a.is_grantable::text AS line
  FROM pg_database d CROSS JOIN LATERAL aclexplode(d.datacl) AS a WHERE d.datname = current_database()
  UNION ALL
  SELECT 'acl|schema|' || n.nspname || '|' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
         || '|' || pg_get_userbyid(a.grantor)::text || '|' || a.privilege_type || '|' || a.is_grantable::text
  FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) AS a WHERE n.nspname = 'opencast'
  UNION ALL
  SELECT 'acl|' || CASE c.relkind WHEN 'S' THEN 'sequence' WHEN 'v' THEN 'view' WHEN 'm' THEN 'view' WHEN 'f' THEN 'table' ELSE 'table' END
         || '|' || c.relname || '|' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
         || '|' || pg_get_userbyid(a.grantor)::text || '|' || a.privilege_type || '|' || a.is_grantable::text
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN LATERAL aclexplode(c.relacl) AS a
  WHERE n.nspname = 'opencast' AND c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
  UNION ALL
  SELECT 'acl|column|' || c.relname || '.' || t.attname || '|' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
         || '|' || pg_get_userbyid(a.grantor)::text || '|' || a.privilege_type || '|' || a.is_grantable::text
  FROM pg_attribute t JOIN pg_class c ON c.oid = t.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
       CROSS JOIN LATERAL aclexplode(t.attacl) AS a
  WHERE n.nspname = 'opencast' AND c.relkind IN ('r', 'p', 'v', 'm', 'f') AND t.attnum > 0 AND NOT t.attisdropped
  UNION ALL
  SELECT 'acl|function|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' || '|'
         || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END
         || '|' || pg_get_userbyid(a.grantor)::text || '|' || a.privilege_type || '|' || a.is_grantable::text
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace CROSS JOIN LATERAL aclexplode(p.proacl) AS a
  WHERE n.nspname = 'opencast'
  UNION ALL
  SELECT 'aclnull|schema|' || n.nspname FROM pg_namespace n WHERE n.nspname = 'opencast' AND n.nspacl IS NULL
  UNION ALL
  SELECT 'aclnull|relation|' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'opencast' AND c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f') AND c.relacl IS NULL
  UNION ALL
  SELECT 'aclnull|function|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'opencast' AND p.proacl IS NULL
) AS x ORDER BY x.line COLLATE "C";
\if :{?runtime_role}
SELECT w.line FROM (
  SELECT 'writable|table|' || c.relname AS line
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'opencast' AND c.relkind IN ('r', 'p')
    AND (has_table_privilege(:'runtime_role', c.oid, 'INSERT') OR has_table_privilege(:'runtime_role', c.oid, 'UPDATE')
      OR has_table_privilege(:'runtime_role', c.oid, 'DELETE') OR has_table_privilege(:'runtime_role', c.oid, 'TRUNCATE')
      OR has_any_column_privilege(:'runtime_role', c.oid, 'INSERT') OR has_any_column_privilege(:'runtime_role', c.oid, 'UPDATE'))
  UNION ALL
  SELECT 'writable|sequence|' || c.relname
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'opencast' AND c.relkind = 'S'
    AND (has_sequence_privilege(:'runtime_role', c.oid, 'USAGE') OR has_sequence_privilege(:'runtime_role', c.oid, 'UPDATE'))
) AS w ORDER BY w.line COLLATE "C";
SELECT 'writable_count|' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'opencast'
  AND ((c.relkind IN ('r', 'p')
        AND (has_table_privilege(:'runtime_role', c.oid, 'INSERT') OR has_table_privilege(:'runtime_role', c.oid, 'UPDATE')
          OR has_table_privilege(:'runtime_role', c.oid, 'DELETE') OR has_table_privilege(:'runtime_role', c.oid, 'TRUNCATE')
          OR has_any_column_privilege(:'runtime_role', c.oid, 'INSERT') OR has_any_column_privilege(:'runtime_role', c.oid, 'UPDATE')))
    OR (c.relkind = 'S'
        AND (has_sequence_privilege(:'runtime_role', c.oid, 'USAGE') OR has_sequence_privilege(:'runtime_role', c.oid, 'UPDATE'))));
\endif
