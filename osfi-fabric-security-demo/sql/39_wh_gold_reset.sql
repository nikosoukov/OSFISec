/* =====================================================================
   SYNTHETIC DATA · for training only · no real customer data
   ---------------------------------------------------------------------
   39_wh_gold_reset.sql  ->  run on: Warehouse  wh_gold  (as presenter / Admin)
   Removes everything 31_wh_gold_security.sql adds, so Demo 5 can be
   rerun from a clean state. Safe to run repeatedly.
   (Alternative full reset: rerun 30_wh_gold_build.sql.)
   ===================================================================== */

-- [reset 1] RLS: policy first, then the schema-bound function
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'province_policy' AND SCHEMA_NAME(schema_id) = 'sec')
    DROP SECURITY POLICY sec.province_policy;
GO
IF OBJECT_ID('sec.fn_province') IS NOT NULL
    DROP FUNCTION sec.fn_province;
GO

-- [reset 2] DDM: remove the email mask if present
IF EXISTS (SELECT 1 FROM sys.masked_columns
           WHERE object_id = OBJECT_ID('gold.dim_customer') AND name = 'email')
    ALTER TABLE gold.dim_customer ALTER COLUMN email DROP MASKED;
GO
REVOKE UNMASK FROM [sg-fgd-stewards];
GO

-- [reset 3] CLS
REVOKE SELECT ON gold.dim_customer(sin, date_of_birth) FROM [sg-fgd-analysts];
GO

-- [reset 4] OLS
REVOKE SELECT ON SCHEMA::sec  FROM [sg-fgd-analysts];
REVOKE SELECT ON SCHEMA::sec  FROM [sg-fgd-auditors];
REVOKE SELECT ON SCHEMA::gold FROM [sg-fgd-auditors];
GO

-- [reset 5] verify: all three result sets should be empty
SELECT name FROM sys.security_policies;
SELECT OBJECT_NAME(object_id) AS table_name, name AS column_name, masking_function FROM sys.masked_columns;
SELECT USER_NAME(grantee_principal_id) AS grantee, permission_name, state_desc, class_desc,
       OBJECT_NAME(major_id) AS object_name
FROM sys.database_permissions
WHERE state_desc = 'DENY' OR permission_name = 'UNMASK';
GO
