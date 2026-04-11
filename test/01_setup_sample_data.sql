-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 1
-- Script: 01_setup_sample_data.sql
-- Purpose: Create sample tables with test data for exercising the analyzer
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED

-- ============================================================================
-- Drop existing sample tables (safe)
-- ============================================================================
BEGIN EXECUTE IMMEDIATE 'DROP TABLE order_items PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP TABLE orders PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP TABLE products PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP TABLE customers PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- ============================================================================
-- CUSTOMERS
-- ============================================================================
CREATE TABLE customers (
    customer_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name      VARCHAR2(100)   NOT NULL,
    last_name       VARCHAR2(100)   NOT NULL,
    email           VARCHAR2(200)   UNIQUE NOT NULL,
    city            VARCHAR2(100),
    country         VARCHAR2(50)    DEFAULT 'US',
    created_at      TIMESTAMP       DEFAULT CURRENT_TIMESTAMP
);

-- Index on city for filtered lookups
CREATE INDEX idx_customers_city ON customers (city);

-- ============================================================================
-- PRODUCTS
-- ============================================================================
CREATE TABLE products (
    product_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_name    VARCHAR2(200)   NOT NULL,
    category        VARCHAR2(100),
    price           NUMBER(10,2)    NOT NULL,
    stock_qty       NUMBER          DEFAULT 0,
    is_active       NUMBER(1)       DEFAULT 1
);

CREATE INDEX idx_products_category ON products (category);

-- ============================================================================
-- ORDERS
-- ============================================================================
CREATE TABLE orders (
    order_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     NUMBER          NOT NULL REFERENCES customers(customer_id),
    order_date      DATE            DEFAULT SYSDATE,
    total_amount    NUMBER(12,2),
    status          VARCHAR2(20)    DEFAULT 'PENDING',
    user_id         NUMBER
);

CREATE INDEX idx_orders_customer ON orders (customer_id);
CREATE INDEX idx_orders_date     ON orders (order_date);
-- Intentionally NO index on user_id — to demonstrate missing index detection

-- ============================================================================
-- ORDER_ITEMS
-- ============================================================================
CREATE TABLE order_items (
    item_id         NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id        NUMBER          NOT NULL REFERENCES orders(order_id),
    product_id      NUMBER          NOT NULL REFERENCES products(product_id),
    quantity        NUMBER          NOT NULL,
    unit_price      NUMBER(10,2)    NOT NULL,
    line_total      NUMBER(12,2)    GENERATED ALWAYS AS (quantity * unit_price) VIRTUAL
);

CREATE INDEX idx_oi_order   ON order_items (order_id);
CREATE INDEX idx_oi_product ON order_items (product_id);

PROMPT >> Sample tables created.

-- ============================================================================
-- INSERT TEST DATA
-- ============================================================================
PROMPT >> Inserting test data...

-- Customers (20 rows)
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('John',    'Doe',      'john.doe@email.com',       'New York',     'US');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Jane',    'Smith',    'jane.smith@email.com',     'London',       'UK');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Ahmed',   'Khan',     'ahmed.khan@email.com',     'Karachi',      'PK');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Maria',   'Garcia',   'maria.garcia@email.com',   'Madrid',       'ES');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Li',      'Wei',      'li.wei@email.com',         'Beijing',      'CN');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Sophie',  'Mueller',  'sophie.mueller@email.com', 'Berlin',       'DE');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Raj',     'Patel',    'raj.patel@email.com',      'Mumbai',       'IN');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Emily',   'Brown',    'emily.brown@email.com',    'Sydney',       'AU');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Omar',    'Hassan',   'omar.hassan@email.com',    'Dubai',        'AE');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Yuki',    'Tanaka',   'yuki.tanaka@email.com',    'Tokyo',        'JP');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Carlos',  'Silva',    'carlos.silva@email.com',   'Sao Paulo',    'BR');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Anna',    'Ivanova',  'anna.ivanova@email.com',   'Moscow',       'RU');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('David',   'Lee',      'david.lee@email.com',      'Toronto',      'CA');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Fatima',  'Ali',      'fatima.ali@email.com',     'Istanbul',     'TR');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Pierre',  'Dupont',   'pierre.dupont@email.com',  'Paris',        'FR');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Sarah',   'Johnson',  'sarah.johnson@email.com',  'Chicago',      'US');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Hassan',  'Mahmoud',  'hassan.mahmoud@email.com', 'Cairo',        'EG');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Min',     'Park',     'min.park@email.com',       'Seoul',        'KR');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Lisa',    'Anderson', 'lisa.anderson@email.com',  'New York',     'US');
INSERT INTO customers (first_name, last_name, email, city, country) VALUES ('Ali',     'Raza',     'ali.raza@email.com',       'Lahore',       'PK');

-- Products (10 rows)
INSERT INTO products (product_name, category, price, stock_qty) VALUES ('Laptop Pro 15',       'Electronics',  1299.99,    50);
INSERT INTO products (product_name, category, price, stock_qty) VALUES ('Wireless Mouse',      'Electronics',  29.99,      200);
INSERT INTO products (product_name, category, price, stock_qty) VALUES ('USB-C Hub',           'Electronics',  49.99,      150);
INSERT INTO products (product_name, category, price, stock_qty) VALUES ('Standing Desk',       'Furniture',    599.99,     30);
INSERT INTO products (product_name, category, price, stock_qty) VALUES ('Ergonomic Chair',     'Furniture',    449.99,     45);
INSERT INTO products (product_name, category, price, stock_qty) VALUES ('Monitor 27"',         'Electronics',  399.99,     75);
INSERT INTO products (product_name, category, price, stock_qty) VALUES ('Keyboard Mechanical', 'Electronics',  89.99,      120);
INSERT INTO products (product_name, category, price, stock_qty) VALUES ('Webcam HD',           'Electronics',  79.99,      100);
INSERT INTO products (product_name, category, price, stock_qty) VALUES ('Desk Lamp LED',       'Furniture',    34.99,      180);
INSERT INTO products (product_name, category, price, stock_qty) VALUES ('Notebook A5',         'Stationery',   12.99,      500);

-- Orders (50 rows via PL/SQL loop for variety)
DECLARE
    v_cust_id   NUMBER;
    v_date      DATE;
    v_amount    NUMBER;
    v_status    VARCHAR2(20);
BEGIN
    FOR i IN 1..50 LOOP
        v_cust_id := MOD(i - 1, 20) + 1;
        v_date    := SYSDATE - MOD(i * 7, 365);
        v_amount  := ROUND(DBMS_RANDOM.VALUE(25, 2500), 2);

        CASE MOD(i, 4)
            WHEN 0 THEN v_status := 'COMPLETED';
            WHEN 1 THEN v_status := 'PENDING';
            WHEN 2 THEN v_status := 'SHIPPED';
            WHEN 3 THEN v_status := 'CANCELLED';
        END CASE;

        INSERT INTO orders (customer_id, order_date, total_amount, status, user_id)
        VALUES (v_cust_id, v_date, v_amount, v_status, MOD(i, 15) + 1);
    END LOOP;
END;
/

-- Order Items (100 rows)
DECLARE
    v_order_id  NUMBER;
    v_prod_id   NUMBER;
    v_qty       NUMBER;
    v_price     NUMBER;
BEGIN
    FOR i IN 1..100 LOOP
        v_order_id := MOD(i - 1, 50) + 1;
        v_prod_id  := MOD(i - 1, 10) + 1;
        v_qty      := MOD(i, 5) + 1;

        SELECT price INTO v_price
        FROM   products
        WHERE  product_id = v_prod_id;

        INSERT INTO order_items (order_id, product_id, quantity, unit_price)
        VALUES (v_order_id, v_prod_id, v_qty, v_price);
    END LOOP;
END;
/

COMMIT;

PROMPT >> Test data inserted successfully.
PROMPT >> Summary:
SELECT 'CUSTOMERS'   AS table_name, COUNT(*) AS row_count FROM customers   UNION ALL
SELECT 'PRODUCTS',                  COUNT(*)              FROM products    UNION ALL
SELECT 'ORDERS',                    COUNT(*)              FROM orders      UNION ALL
SELECT 'ORDER_ITEMS',               COUNT(*)              FROM order_items;
