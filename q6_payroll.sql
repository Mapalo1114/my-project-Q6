-- ICT371 Question 6: Monthly Payroll Processing (PostgreSQL)
DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path TO q6, public;

-- (a) TABLES -------------------------------------------------------------
CREATE TABLE employees (
  employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
  payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL,
  gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
  net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
  CONSTRAINT chk_month_start CHECK (EXTRACT(DAY FROM pay_month) = 1),   -- first day of month
  CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- (b) FUNCTION -----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC AS $$
DECLARE
  v_net NUMERIC;
BEGIN
  SELECT basic_salary + allowance - deduction INTO v_net
  FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
  END IF;

  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;

  RETURN v_net;
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) PROCEDURE ----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
AS $$
DECLARE
  r     RECORD;
  v_net NUMERIC;
BEGIN
  IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
    RAISE EXCEPTION 'Pay month must be the first day of a month, got %', p_month;
  END IF;

  FOR r IN SELECT employee_id, basic_salary, allowance FROM employees WHERE active ORDER BY employee_id
  LOOP
    v_net := fn_net_pay(r.employee_id);     -- raises on an invalid calculation: whole CALL fails

    INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- (d) TRIGGER ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO salary_audit (employee_id, old_salary, new_salary)
  VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- (a) SEED DATA ----------------------------------------------------------
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
  ('Anna Mutale',   8000.00, 1500.00, 1200.00, TRUE),
  ('Bwalya Chanda', 6500.00, 1000.00,  900.00, TRUE),
  ('Charles Sinkala', 5000.00, 500.00, 600.00, TRUE),
  ('Doreen Kasonde',  7000.00, 800.00, 950.00, TRUE);

CALL pr_process_payroll(DATE '2026-09-01');            -- all four employees paid

UPDATE employees SET active = FALSE WHERE employee_id = 4;   -- Doreen leaves
CALL pr_process_payroll(DATE '2026-10-01');            -- only active employees

CALL pr_process_payroll(DATE '2026-10-01');            -- rerun: no duplicates, no changes

UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;   -- audited
UPDATE employees SET allowance = 1600.00   WHERE employee_id = 1;    -- NOT audited

SELECT * FROM payroll ORDER BY pay_month, employee_id;   -- 4 rows (Sep) + 3 rows (Oct)
SELECT * FROM salary_audit;

-- tests (each should raise an error)
-- SELECT fn_net_pay(99);                               -- Unknown employee
-- CALL pr_process_payroll(DATE '2026-10-15');          -- not a month start
-- To test negative net: UPDATE employees SET deduction = 99999 WHERE employee_id = 2;
--   then CALL pr_process_payroll(DATE '2026-11-01');   -- fails and inserts nothing

-- (e) VIEW ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id, e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;   -- no active filter: history kept

SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;

-- (f) INDEX --------------------------------------------------------------
-- The unique index starts with employee_id, so it cannot efficiently serve
-- a search on pay_month alone. A single-column index on pay_month can.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) SCHEDULE: 02:00 on the 1st of each month, for the previous month ----
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q6_process_payroll', '0 2 1 * *',
  $$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 10;
