/* =====================================================================
   SYNTHETIC DATA · for training only · no real customer data
   ---------------------------------------------------------------------
   30_wh_gold_build.sql  ->  run on: Warehouse  wh_gold
   Builds the gold star schema from lh_silver (cross-database query,
   same workspace) and the security mapping table sec.user_province.

   SQLCMD variable:  $(TenantDomain)   e.g. contoso.onmicrosoft.com
     - scripts/02-Deploy-FgdWorkspace.ps1 passes it via Invoke-Sqlcmd -Variable
     - If you paste this into the Fabric SQL editor instead, first
       find/replace  $(TenantDomain)  with your tenant domain.

   Rerunnable: drops the RLS policy/function first (they are schema-bound
   to sec.user_province), then drops and recreates the gold tables.
   Running this RESETS any demo security applied by 31_wh_gold_security.sql
   on gold tables (masks/denies disappear with the dropped tables).
   ===================================================================== */

-- [step 0] remove schema-bound security objects so tables can be dropped
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'province_policy' AND SCHEMA_NAME(schema_id) = 'sec')
    DROP SECURITY POLICY sec.province_policy;
GO
IF OBJECT_ID('sec.fn_province') IS NOT NULL
    DROP FUNCTION sec.fn_province;
GO

-- [step 1] schemas
IF SCHEMA_ID('gold') IS NULL EXEC('CREATE SCHEMA gold');
GO
IF SCHEMA_ID('sec') IS NULL EXEC('CREATE SCHEMA sec');
GO

-- [step 2] gold.dim_customer  (CTAS from the lh_silver SQL analytics endpoint)
DROP TABLE IF EXISTS gold.dim_customer;
GO
CREATE TABLE gold.dim_customer AS
SELECT CAST(customer_id   AS int)           AS customer_id,
       CAST(first_name    AS varchar(50))   AS first_name,
       CAST(last_name     AS varchar(50))   AS last_name,
       CAST(email         AS varchar(120))  AS email,
       CAST(sin           AS varchar(11))   AS sin,
       CAST(date_of_birth AS date)          AS date_of_birth,
       CAST(province      AS varchar(2))    AS province,
       CAST(segment       AS varchar(20))   AS segment,
       CAST(created_at    AS datetime2(6))  AS created_at
FROM lh_silver.dbo.customer;
GO

-- [step 3] gold.dim_account
DROP TABLE IF EXISTS gold.dim_account;
GO
CREATE TABLE gold.dim_account AS
SELECT CAST(account_id   AS int)            AS account_id,
       CAST(customer_id  AS int)            AS customer_id,
       CAST(account_type AS varchar(20))    AS account_type,
       CAST(status       AS varchar(10))    AS status,
       CAST(opened_at    AS date)           AS opened_at,
       CAST(balance      AS decimal(18,2))  AS balance,
       CAST(currency     AS varchar(3))     AS currency,
       CAST(province     AS varchar(2))     AS province
FROM lh_silver.dbo.account;
GO

-- [step 4] gold.fact_loan
DROP TABLE IF EXISTS gold.fact_loan;
GO
CREATE TABLE gold.fact_loan AS
SELECT CAST(application_id AS varchar(20))   AS application_id,
       CAST(customer_id    AS int)           AS customer_id,
       CAST(province       AS varchar(2))    AS province,
       CAST(product        AS varchar(30))   AS product,
       CAST(amount         AS decimal(18,2)) AS amount,
       CAST(rate           AS decimal(6,3))  AS rate,
       CAST(status         AS varchar(20))   AS status,
       CAST(submitted_at   AS datetime2(6))  AS submitted_at,
       CAST(submitted_date AS date)          AS submitted_date
FROM lh_silver.dbo.loan;
GO

-- [step 5] gold.fact_transaction_monthly
DROP TABLE IF EXISTS gold.fact_transaction_monthly;
GO
CREATE TABLE gold.fact_transaction_monthly AS
SELECT CAST(month_start  AS date)           AS month_start,
       CAST(account_id   AS int)            AS account_id,
       CAST(customer_id  AS int)            AS customer_id,
       CAST(province     AS varchar(2))     AS province,
       CAST(txn_count    AS int)            AS txn_count,
       CAST(debit_total  AS decimal(18,2))  AS debit_total,
       CAST(credit_total AS decimal(18,2))  AS credit_total,
       CAST(net_amount   AS decimal(18,2))  AS net_amount
FROM lh_silver.dbo.transaction_monthly;
GO

-- [step 6] sec.user_province : who may see which province ('*' = all)
--   UPNs are stored lower-case; the RLS function compares LOWER(USER_NAME()).
DROP TABLE IF EXISTS sec.user_province;
GO
CREATE TABLE sec.user_province (
    upn      varchar(256) NOT NULL,
    province varchar(2)   NOT NULL
);
GO
INSERT INTO sec.user_province (upn, province)
SELECT LOWER('fgd.olivia.analyst@$(TenantDomain)'),  'ON' UNION ALL
SELECT LOWER('fgd.quentin.analyst@$(TenantDomain)'), 'QC' UNION ALL
SELECT LOWER('fgd.sam.steward@$(TenantDomain)'),     '*';
GO

-- [step 7] row counts (expect ~5,000 / ~8,000 / ~3,000 / ~80,000-95,000 / 3)
SELECT 'gold.dim_customer' AS table_name, COUNT_BIG(*) AS row_count FROM gold.dim_customer
UNION ALL SELECT 'gold.dim_account',             COUNT_BIG(*) FROM gold.dim_account
UNION ALL SELECT 'gold.fact_loan',               COUNT_BIG(*) FROM gold.fact_loan
UNION ALL SELECT 'gold.fact_transaction_monthly',COUNT_BIG(*) FROM gold.fact_transaction_monthly
UNION ALL SELECT 'sec.user_province',            COUNT_BIG(*) FROM sec.user_province;
GO
