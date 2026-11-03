/* =====================================================================
   SYNTHETIC DATA · for training only · no real customer data
   ---------------------------------------------------------------------
   31_wh_gold_security.sql  ->  LIVE DEMO 5 on Warehouse  wh_gold

   HOW TO USE LIVE
     * Presenter browser profile (workspace Admin): open wh_gold > New SQL query,
       paste this file, then highlight ONE block at a time and "Run" (runs the selection).
     * Persona browser profiles (olivia / quentin / sam / aaron): open wh_gold
       > New SQL query and run only the TEST queries in BLOCK 5.
     * Reset afterwards with 39_wh_gold_reset.sql (or rerun 30_wh_gold_build.sql).

   Group names assume prefix "fgd". If you changed the prefix, find/replace sg-fgd-.
   Fabric workspace roles: Admin / Member / Contributor are effectively db_owner
   and bypass these controls (lead finding: least privilege starts at workspace roles).
   Viewers get ReadData on the warehouse; the controls below narrow that.
   ===================================================================== */


/* ---------------------------------------------------------------------
   BLOCK 0 · Who am I?  (run in every profile)
   --------------------------------------------------------------------- */
SELECT USER_NAME()                 AS user_name,      -- UPN of the caller
       IS_ROLEMEMBER('db_owner')   AS is_db_owner;     -- 1 for Admin/Member/Contributor
SELECT * FROM sec.user_province;                     -- presenter only: the mapping table
GO


/* ---------------------------------------------------------------------
   BLOCK 1 · OLS (object-level security): hide the security schema
   Analysts and auditors cannot read sec.* (the mapping table).
   --------------------------------------------------------------------- */
DENY SELECT ON SCHEMA::sec TO [sg-fgd-analysts];
DENY SELECT ON SCHEMA::sec TO [sg-fgd-auditors];
-- 1b · Auditor = metadata/audit only: may see object names (sys.tables) but no rows.
DENY SELECT ON SCHEMA::gold TO [sg-fgd-auditors];
GO


/* ---------------------------------------------------------------------
   BLOCK 2a · RLS predicate function  (must run as its own batch)
   Returns a row when the caller is mapped to the row's province, or to '*',
   or is db_owner (workspace Admin/Member/Contributor).
   Ownership chaining lets the function read sec.user_province even though
   analysts are DENIED on schema sec.
   --------------------------------------------------------------------- */
CREATE FUNCTION sec.fn_province (@province AS varchar(2))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS allowed
    FROM sec.user_province AS u
    WHERE (LOWER(u.upn) = LOWER(USER_NAME()) AND u.province IN (@province, '*'))
       OR IS_ROLEMEMBER('db_owner') = 1;
GO

/* ---------------------------------------------------------------------
   BLOCK 2b · RLS security policy on the customer dimension and loan fact
   --------------------------------------------------------------------- */
CREATE SECURITY POLICY sec.province_policy
    ADD FILTER PREDICATE sec.fn_province(province) ON gold.dim_customer,
    ADD FILTER PREDICATE sec.fn_province(province) ON gold.fact_loan
    -- Teaching point: warehouse RLS is PER TABLE (no propagation through joins).
    -- gold.dim_account and gold.fact_transaction_monthly stay unfiltered until you add:
    -- , ADD FILTER PREDICATE sec.fn_province(province) ON gold.dim_account
    -- , ADD FILTER PREDICATE sec.fn_province(province) ON gold.fact_transaction_monthly
WITH (STATE = ON);
GO


/* ---------------------------------------------------------------------
   BLOCK 3 · CLS (column-level security): analysts cannot read SIN or DOB
   --------------------------------------------------------------------- */
DENY SELECT ON gold.dim_customer (sin, date_of_birth) TO [sg-fgd-analysts];
GO


/* ---------------------------------------------------------------------
   BLOCK 4 · DDM (dynamic data masking): mask email; stewards may unmask
   (Admin/Member/Contributor always see unmasked data.)
   --------------------------------------------------------------------- */
ALTER TABLE gold.dim_customer
    ALTER COLUMN email ADD MASKED WITH (FUNCTION = 'email()');
GRANT UNMASK TO [sg-fgd-stewards];
GO


/* ---------------------------------------------------------------------
   BLOCK 5 · TESTS  (run in each persona profile)
   ---------------------------------------------------------------------
   Persona                 5a provinces          5b email           5c SIN              5d sec.*      5e loans
   olivia (ON analyst)     ON only (~1,900)      aXX@XXXX.com       ERROR (denied)      ERROR         ON only
   quentin (QC analyst)    QC only (~1,100)      masked             ERROR (denied)      ERROR         QC only
   sam (steward)           all 13 (~5,000)       real email         visible             visible*      all
   aaron (auditor)         ERROR (denied)        ERROR              ERROR               ERROR         ERROR
   dana / presenter        all 13 (db_owner)     real email         visible             visible       all
   (*sam is not denied on sec; deny it too if you want stewards blind to the mapping.)
   --------------------------------------------------------------------- */

-- 5a · RLS: which provinces can I see?
SELECT province, COUNT(*) AS customers
FROM gold.dim_customer
GROUP BY province
ORDER BY customers DESC;

-- 5b · DDM: is email masked for me?  (explicit column list avoids the CLS deny)
SELECT TOP (5) customer_id, first_name, last_name, email, province
FROM gold.dim_customer
ORDER BY customer_id;

-- 5c · CLS: can I read SIN / date of birth?  (analysts: "The SELECT permission was denied ...")
SELECT TOP (5) customer_id, sin, date_of_birth
FROM gold.dim_customer
ORDER BY customer_id;

-- 5c' · SELECT * also fails for analysts because it touches denied columns
-- SELECT TOP (5) * FROM gold.dim_customer;

-- 5d · OLS: can I read the security mapping?
SELECT * FROM sec.user_province;

-- 5e · RLS on the fact table
SELECT province, COUNT(*) AS loans, SUM(amount) AS loan_amount
FROM gold.fact_loan
GROUP BY province
ORDER BY loan_amount DESC;

-- 5f · Teaching point: dim_account has NO policy -> analysts still see every province here
SELECT province, COUNT(*) AS accounts
FROM gold.dim_account
GROUP BY province
ORDER BY accounts DESC;
GO


/* ---------------------------------------------------------------------
   BLOCK 6 · Inspect what is in place (presenter)
   --------------------------------------------------------------------- */
SELECT p.name AS policy_name, p.is_enabled, OBJECT_NAME(pr.target_object_id) AS target_table, pr.predicate_definition
FROM sys.security_policies AS p
JOIN sys.security_predicates AS pr ON pr.object_id = p.object_id;

SELECT OBJECT_NAME(object_id) AS table_name, name AS column_name, masking_function
FROM sys.masked_columns;

SELECT USER_NAME(dp.grantee_principal_id) AS grantee, dp.state_desc, dp.permission_name, dp.class_desc,
       CASE dp.class_desc WHEN 'SCHEMA' THEN SCHEMA_NAME(dp.major_id)
                          WHEN 'OBJECT_OR_COLUMN' THEN OBJECT_NAME(dp.major_id)
                          ELSE 'DATABASE' END AS securable,
       CASE WHEN dp.class_desc = 'OBJECT_OR_COLUMN' THEN COL_NAME(dp.major_id, dp.minor_id) END AS column_name
FROM sys.database_permissions AS dp
WHERE dp.state_desc = 'DENY' OR dp.permission_name = 'UNMASK'
ORDER BY grantee;
GO
