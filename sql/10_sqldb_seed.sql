/* =====================================================================
   SYNTHETIC DATA · for training only · no real customer data
   ---------------------------------------------------------------------
   10_sqldb_seed.sql  ->  run on: SQL database in Fabric  sqldb_core_banking

   Creates and seeds the "core banking" OLTP tables:
       dbo.customers     ~5,000 rows
       dbo.accounts      ~8,000 rows   (chequing / savings / credit_card / mortgage)
       dbo.transactions  ~100,000 rows (12 months ending 2026-10-31)

   Every table has a PRIMARY KEY: SQL database in Fabric only replicates
   (mirrors) tables with a primary key into OneLake.

   Deterministic: no RAND()/NEWID(). Pseudo-random values come from
   ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT(<salt>, n))) % m) so every run
   (modulo before ABS avoids the ABS(INT_MIN) overflow)
   in every tenant produces the same data.

   SIN-like values are 9 digits whose last (check) digit is FORCED to be
   wrong, so every value FAILS the Luhn check (cannot be a real SIN).

   Idempotent: tables are created only if missing and seeded only if
   empty. To reseed, TRUNCATE the three tables (transactions first) and
   rerun. (Avoid DROP TABLE while mirroring is running.)
   Run as: workspace Admin/Contributor (Entra token). ~30-90 seconds.
   ===================================================================== */

SET NOCOUNT ON;

/* ---------- [step 1] tables ---------- */
IF OBJECT_ID(N'dbo.customers', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.customers (
        customer_id    int           NOT NULL CONSTRAINT pk_customers PRIMARY KEY,
        first_name     varchar(50)   NOT NULL,
        last_name      varchar(50)   NOT NULL,
        email          varchar(120)  NOT NULL,
        sin            varchar(11)   NOT NULL,   -- synthetic, Luhn-INVALID, format 999-999-999
        date_of_birth  date          NOT NULL,
        province       char(2)       NOT NULL,
        segment        varchar(20)   NOT NULL,   -- Retail / Small Business / Wealth
        created_at     datetime2(0)  NOT NULL
    );
END;

IF OBJECT_ID(N'dbo.accounts', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.accounts (
        account_id     int            NOT NULL CONSTRAINT pk_accounts PRIMARY KEY,
        customer_id    int            NOT NULL,
        account_type   varchar(20)    NOT NULL,  -- chequing / savings / credit_card / mortgage
        status         varchar(10)    NOT NULL,  -- Open / Closed
        opened_at      date           NOT NULL,
        balance        decimal(18,2)  NOT NULL,
        currency       char(3)        NOT NULL
    );
END;

IF OBJECT_ID(N'dbo.transactions', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.transactions (
        transaction_id    bigint         NOT NULL CONSTRAINT pk_transactions PRIMARY KEY,
        account_id        int            NOT NULL,
        txn_ts            datetime2(0)   NOT NULL,
        amount            decimal(18,2)  NOT NULL,
        direction         varchar(6)     NOT NULL,  -- DEBIT / CREDIT
        channel           varchar(10)    NOT NULL,
        merchant_category varchar(30)    NOT NULL
    );
END;

/* ---------- [step 2] deterministic numbers 1..100000 ---------- */
IF OBJECT_ID(N'tempdb..#nums') IS NOT NULL DROP TABLE #nums;

WITH d AS (SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS v(n))
SELECT n = d1.n + d2.n*10 + d3.n*100 + d4.n*1000 + d5.n*10000 + 1
INTO #nums
FROM d d1 CROSS JOIN d d2 CROSS JOIN d d3 CROSS JOIN d d4 CROSS JOIN d d5;   -- 100,000 rows

CREATE UNIQUE CLUSTERED INDEX ix_nums ON #nums(n);

/* ---------- [step 3] customers (5,000) ---------- */
IF NOT EXISTS (SELECT 1 FROM dbo.customers)
BEGIN
    WITH r AS (
        SELECT n,
               r_prov  = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('prov#',  n))) % 1000),
               r_first = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('first#', n))) % 20),
               r_last  = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('last#',  n))) % 20),
               r_sin   = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('sin#',   n))) % 90000000) + 10000000, -- 8 digits
               r_dob   = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('dob#',   n))) % 21900),   -- ~60 years
               r_seg   = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('seg#',   n))) % 100),
               r_new   = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('new#',   n))) % 3650)     -- 10 years
        FROM #nums WHERE n <= 5000
    ),
    s AS (
        SELECT r.*,
               -- Luhn sum over the first 8 digits (positions 2,4,6,8 doubled; subtract 9 if > 9)
               luhn8 =  (r_sin / 10000000) % 10
                      + CASE WHEN 2*((r_sin / 1000000) % 10) > 9 THEN 2*((r_sin / 1000000) % 10) - 9 ELSE 2*((r_sin / 1000000) % 10) END
                      + (r_sin / 100000) % 10
                      + CASE WHEN 2*((r_sin / 10000) % 10) > 9 THEN 2*((r_sin / 10000) % 10) - 9 ELSE 2*((r_sin / 10000) % 10) END
                      + (r_sin / 1000) % 10
                      + CASE WHEN 2*((r_sin / 100) % 10) > 9 THEN 2*((r_sin / 100) % 10) - 9 ELSE 2*((r_sin / 100) % 10) END
                      + (r_sin / 10) % 10
                      + CASE WHEN 2*(r_sin % 10) > 9 THEN 2*(r_sin % 10) - 9 ELSE 2*(r_sin % 10) END
        FROM r
    ),
    c AS (
        SELECT n,
               first_name = CHOOSE(r_first + 1, 'Alex','Sam','Jordan','Taylor','Morgan','Casey','Riley','Jamie','Avery','Quinn',
                                                'Emma','Liam','Olivia','Noah','Chloe','Lucas','Maya','Ethan','Zoe','Felix'),
               last_name  = CHOOSE(r_last + 1,  'Tremblay','Gagnon','Roy','Cote','Bouchard','Gauthier','Morin','Lavoie','Fortin','Gagne',
                                                'Smith','Brown','Wilson','MacDonald','Taylor','Campbell','Anderson','Lee','Martin','Clark'),
               -- 9th digit = valid Luhn check digit + 1 (mod 10)  =>  always Luhn-INVALID
               sin9       = CAST(r_sin AS bigint) * 10 + (((10 - luhn8 % 10) % 10) + 1) % 10,
               dob        = DATEADD(DAY, -r_dob, CAST('2008-01-01' AS date)),
               province   = CASE WHEN r_prov < 385 THEN 'ON'   -- .385
                                 WHEN r_prov < 607 THEN 'QC'   -- .222
                                 WHEN r_prov < 744 THEN 'BC'   -- .137
                                 WHEN r_prov < 862 THEN 'AB'   -- .118
                                 WHEN r_prov < 898 THEN 'MB'   -- .036
                                 WHEN r_prov < 928 THEN 'SK'   -- .030
                                 WHEN r_prov < 955 THEN 'NS'   -- .027
                                 WHEN r_prov < 976 THEN 'NB'   -- .021
                                 WHEN r_prov < 990 THEN 'NL'   -- .014
                                 WHEN r_prov < 994 THEN 'PE'   -- .004
                                 WHEN r_prov < 996 THEN 'YT'   -- .002
                                 WHEN r_prov < 998 THEN 'NT'   -- .002
                                 ELSE                    'NU'  -- .002
                            END,
               segment    = CASE WHEN r_seg < 70 THEN 'Retail' WHEN r_seg < 90 THEN 'Small Business' ELSE 'Wealth' END,
               created_at = DATEADD(MINUTE, -(r_new * 1440 + n % 1440), CAST('2026-10-01T00:00:00' AS datetime2(0)))
        FROM s
    )
    INSERT INTO dbo.customers (customer_id, first_name, last_name, email, sin, date_of_birth, province, segment, created_at)
    SELECT n,
           first_name,
           last_name,
           LOWER(CONCAT(first_name, '.', last_name, '.', n, '@example.com')),
           STUFF(STUFF(RIGHT(CONCAT('000000000', sin9), 9), 7, 0, '-'), 4, 0, '-'),
           dob, province, segment, created_at
    FROM c;
    PRINT '[step 3] customers inserted';
END
ELSE PRINT '[step 3] customers already seeded - skipped';

/* ---------- [step 4] accounts (8,000) ---------- */
IF NOT EXISTS (SELECT 1 FROM dbo.accounts)
BEGIN
    WITH r AS (
        SELECT n,
               -- first 5,000 accounts: one per customer; remaining 3,000 spread pseudo-randomly
               cust   = CASE WHEN n <= 5000 THEN n
                             ELSE ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('acust#', n))) % 5000) + 1 END,
               r_type = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('atype#', n))) % 100),
               r_bal  = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('abal#',  n))) % 1000000),
               r_open = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('aopen#', n))) % 5475),  -- 15 years
               r_stat = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('astat#', n))) % 100)
        FROM #nums WHERE n <= 8000
    ),
    t AS (
        SELECT r.*,
               account_type = CASE WHEN n <= 5000 THEN 'chequing'        -- everyone has a chequing account
                                   WHEN r_type < 45 THEN 'savings'
                                   WHEN r_type < 80 THEN 'credit_card'
                                   ELSE 'mortgage' END
        FROM r
    )
    INSERT INTO dbo.accounts (account_id, customer_id, account_type, status, opened_at, balance, currency)
    SELECT n,
           cust,
           account_type,
           CASE WHEN r_stat < 94 THEN 'Open' ELSE 'Closed' END,
           DATEADD(DAY, -r_open, CAST('2026-10-01' AS date)),
           CAST(CASE account_type
                    WHEN 'chequing'    THEN  r_bal % 25000      + (r_bal % 100) / 100.0
                    WHEN 'savings'     THEN  r_bal % 150000     + (r_bal % 100) / 100.0
                    WHEN 'credit_card' THEN  r_bal % 12000      + (r_bal % 100) / 100.0
                    ELSE                     r_bal % 650000 + 50000 + (r_bal % 100) / 100.0
                END AS decimal(18,2)),
           'CAD'
    FROM t;
    PRINT '[step 4] accounts inserted';
END
ELSE PRINT '[step 4] accounts already seeded - skipped';

/* ---------- [step 5] transactions (100,000 over 12 months) ---------- */
IF NOT EXISTS (SELECT 1 FROM dbo.transactions)
BEGIN
    WITH r AS (
        SELECT n,
               r_acct = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('tacct#', n))) % 8000) + 1,
               r_ts   = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('tts#',   n))) % 31536000),  -- seconds in 365 days
               r_amt  = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('tamt#',  n))) % 250000),
               r_dir  = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('tdir#',  n))) % 100),
               r_ch   = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('tch#',   n))) % 5),
               r_mcc  = ABS(CHECKSUM(HASHBYTES('SHA2_256', CONCAT('tmcc#',  n))) % 8)
        FROM #nums
    )
    INSERT INTO dbo.transactions (transaction_id, account_id, txn_ts, amount, direction, channel, merchant_category)
    SELECT CAST(n AS bigint),
           r_acct,
           DATEADD(SECOND, -r_ts, CAST('2026-11-01T00:00:00' AS datetime2(0))),
           CAST(1 + r_amt / 100.0 AS decimal(18,2)),
           CASE WHEN r_dir < 65 THEN 'DEBIT' ELSE 'CREDIT' END,
           CHOOSE(r_ch + 1, 'Branch','Online','Mobile','ATM','POS'),
           CASE WHEN r_dir >= 65 THEN 'Payroll / Transfer'
                ELSE CHOOSE(r_mcc + 1, 'Groceries','Fuel','Restaurants','Utilities','Travel','Retail','Healthcare','Telecom') END
    FROM r;
    PRINT '[step 5] transactions inserted';
END
ELSE PRINT '[step 5] transactions already seeded - skipped';

DROP TABLE IF EXISTS #nums;

/* ---------- [step 6] sanity checks ---------- */
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM dbo.customers
UNION ALL SELECT 'accounts',     COUNT(*) FROM dbo.accounts
UNION ALL SELECT 'transactions', COUNT(*) FROM dbo.transactions;

-- Province distribution (expect ON ~38%, QC ~22%, BC ~14% ...)
SELECT province, COUNT(*) AS customers, CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(5,1)) AS pct
FROM dbo.customers GROUP BY province ORDER BY customers DESC;

-- Luhn self-check: expect luhn_valid_sins = 0
WITH d AS (
    SELECT CAST(REPLACE(sin, '-', '') AS char(9)) AS s FROM dbo.customers
), x AS (
    SELECT s,
        v = CAST(SUBSTRING(s,1,1) AS int)
          + CASE WHEN 2*CAST(SUBSTRING(s,2,1) AS int) > 9 THEN 2*CAST(SUBSTRING(s,2,1) AS int) - 9 ELSE 2*CAST(SUBSTRING(s,2,1) AS int) END
          + CAST(SUBSTRING(s,3,1) AS int)
          + CASE WHEN 2*CAST(SUBSTRING(s,4,1) AS int) > 9 THEN 2*CAST(SUBSTRING(s,4,1) AS int) - 9 ELSE 2*CAST(SUBSTRING(s,4,1) AS int) END
          + CAST(SUBSTRING(s,5,1) AS int)
          + CASE WHEN 2*CAST(SUBSTRING(s,6,1) AS int) > 9 THEN 2*CAST(SUBSTRING(s,6,1) AS int) - 9 ELSE 2*CAST(SUBSTRING(s,6,1) AS int) END
          + CAST(SUBSTRING(s,7,1) AS int)
          + CASE WHEN 2*CAST(SUBSTRING(s,8,1) AS int) > 9 THEN 2*CAST(SUBSTRING(s,8,1) AS int) - 9 ELSE 2*CAST(SUBSTRING(s,8,1) AS int) END
          + CAST(SUBSTRING(s,9,1) AS int)
    FROM d
)
SELECT SUM(CASE WHEN v % 10 = 0 THEN 1 ELSE 0 END) AS luhn_valid_sins,   -- must be 0
       COUNT(*)                                     AS total_sins
FROM x;
