-- ====================================================================================
-- Project: NovaMart Global E-Commerce Analytics Platform
-- File: 04_views_and_procedures.sql
-- Description: Business Intelligence Views & Stored Procedures for Reporting & Dashboards
-- Target RDBMS: MySQL 8.0+
-- ====================================================================================

USE novamart_db;

-- Drop existing views and procedures if present
DROP VIEW IF EXISTS view_executive_monthly_kpis;
DROP VIEW IF EXISTS view_customer_lifetime_value;
DROP VIEW IF EXISTS view_product_performance_matrix;
DROP PROCEDURE IF EXISTS sp_get_customer_360;
DROP PROCEDURE IF EXISTS sp_monthly_executive_report;

-- ====================================================================================
-- 1. VIEW: Executive Monthly KPI Dashboard View
-- Ready for direct connection to Power BI, Tableau, or Looker Studio.
-- ====================================================================================
CREATE VIEW view_executive_monthly_kpis AS
SELECT
    DATE_FORMAT(o.order_date, '%Y-%m') AS report_month,
    YEAR(o.order_date) AS report_year,
    MONTH(o.order_date) AS report_month_num,
    COUNT(DISTINCT o.order_id) AS total_orders,
    COUNT(DISTINCT CASE WHEN o.order_status = 'Delivered' THEN o.order_id END) AS delivered_orders,
    COUNT(DISTINCT CASE WHEN o.order_status = 'Returned' THEN o.order_id END) AS returned_orders,
    COUNT(DISTINCT CASE WHEN o.order_status = 'Cancelled' THEN o.order_id END) AS cancelled_orders,
    COUNT(DISTINCT o.customer_id) AS active_purchasers,
    ROUND(SUM(o.total_amount), 2) AS gross_revenue,
    ROUND(SUM(CASE WHEN o.order_status = 'Returned' THEN o.total_amount ELSE 0 END), 2) AS refunded_amount,
    ROUND(SUM(CASE WHEN o.order_status NOT IN ('Cancelled', 'Returned') THEN o.total_amount ELSE 0 END), 2) AS net_revenue,
    ROUND(
        SUM(CASE WHEN o.order_status NOT IN ('Cancelled', 'Returned') THEN o.total_amount ELSE 0 END) 
        / NULLIF(COUNT(DISTINCT CASE WHEN o.order_status NOT IN ('Cancelled', 'Returned') THEN o.order_id END), 0), 
        2
    ) AS aov_delivered,
    ROUND(
        (COUNT(DISTINCT CASE WHEN o.order_status = 'Returned' THEN o.order_id END) 
        / NULLIF(COUNT(DISTINCT o.order_id), 0)) * 100, 
        2
    ) AS return_rate_pct
FROM fact_orders o
GROUP BY 
    DATE_FORMAT(o.order_date, '%Y-%m'),
    YEAR(o.order_date),
    MONTH(o.order_date);


-- ====================================================================================
-- 2. VIEW: Customer Lifetime Value (LTV) & Behavior Profile
-- ====================================================================================
CREATE VIEW view_customer_lifetime_value AS
WITH customer_aggregates AS (
    SELECT
        c.customer_id,
        CONCAT(c.first_name, ' ', c.last_name) AS full_name,
        c.email,
        c.acquisition_channel,
        c.city,
        c.state_province,
        c.country,
        c.signup_date,
        MIN(o.order_date) AS first_order_date,
        MAX(o.order_date) AS latest_order_date,
        COUNT(DISTINCT o.order_id) AS total_orders,
        ROUND(SUM(CASE WHEN o.order_status NOT IN ('Cancelled', 'Returned') THEN o.total_amount ELSE 0 END), 2) AS lifetime_net_spend,
        ROUND(AVG(CASE WHEN o.order_status NOT IN ('Cancelled', 'Returned') THEN o.total_amount END), 2) AS avg_order_value,
        DATEDIFF('2026-09-15', MAX(o.order_date)) AS days_since_last_order,
        DATEDIFF('2026-09-15', c.signup_date) AS customer_tenure_days
    FROM dim_customers c
    LEFT JOIN fact_orders o ON c.customer_id = o.customer_id
    GROUP BY 
        c.customer_id, c.first_name, c.last_name, c.email, 
        c.acquisition_channel, c.city, c.state_province, c.country, c.signup_date
)
SELECT
    *,
    CASE 
        WHEN lifetime_net_spend >= 1500 THEN 'Platinum Tier'
        WHEN lifetime_net_spend >= 800 THEN 'Gold Tier'
        WHEN lifetime_net_spend >= 300 THEN 'Silver Tier'
        ELSE 'Bronze Tier'
    END AS customer_value_tier
FROM customer_aggregates;


-- ====================================================================================
-- 3. VIEW: Product Performance & Profitability Matrix
-- ====================================================================================
CREATE VIEW view_product_performance_matrix AS
SELECT
    p.product_id,
    p.sku,
    p.product_name,
    c.department,
    c.category_name,
    p.cost_price,
    p.retail_price,
    ROUND(p.retail_price - p.cost_price, 2) AS unit_margin,
    ROUND(((p.retail_price - p.cost_price) / p.retail_price) * 100, 1) AS margin_percentage,
    COALESCE(SUM(oi.quantity), 0) AS total_units_sold,
    COALESCE(ROUND(SUM(oi.line_total), 2), 0.00) AS total_gross_revenue,
    COALESCE(ROUND(SUM(oi.quantity * p.cost_price), 2), 0.00) AS total_cogs,
    COALESCE(ROUND(SUM(oi.line_total) - SUM(oi.quantity * p.cost_price), 2), 0.00) AS total_gross_profit,
    p.stock_quantity AS current_warehouse_stock,
    COALESCE(ROUND(AVG(r.rating), 2), 0.0) AS avg_review_score,
    COUNT(DISTINCT r.review_id) AS total_reviews
FROM dim_products p
JOIN dim_categories c ON p.category_id = c.category_id
LEFT JOIN fact_order_items oi ON p.product_id = oi.product_id
LEFT JOIN fact_orders o ON oi.order_id = o.order_id AND o.order_status NOT IN ('Cancelled')
LEFT JOIN fact_customer_reviews r ON p.product_id = r.product_id
GROUP BY 
    p.product_id, p.sku, p.product_name, c.department, c.category_name, 
    p.cost_price, p.retail_price, p.stock_quantity;


-- ====================================================================================
-- 4. STORED PROCEDURE: Customer 360 Lookup
-- Parameters: in_customer_id INT
-- Returns: Customer demographics, lifetime metrics, preferred category, and order history
-- ====================================================================================
DELIMITER //

CREATE PROCEDURE sp_get_customer_360(IN in_customer_id INT)
BEGIN
    -- Section 1: Customer Profile & Lifetime Value
    SELECT
        c.customer_id,
        CONCAT(c.first_name, ' ', c.last_name) AS full_name,
        c.email,
        c.gender,
        c.age_group,
        c.city,
        c.state_province,
        c.country,
        c.acquisition_channel,
        c.signup_date,
        COUNT(DISTINCT o.order_id) AS lifetime_orders,
        COALESCE(ROUND(SUM(CASE WHEN o.order_status NOT IN ('Cancelled', 'Returned') THEN o.total_amount ELSE 0 END), 2), 0.00) AS net_lifetime_spend,
        DATEDIFF('2026-09-15', MAX(o.order_date)) AS days_since_last_purchase
    FROM dim_customers c
    LEFT JOIN fact_orders o ON c.customer_id = o.customer_id
    WHERE c.customer_id = in_customer_id
    GROUP BY 
        c.customer_id, c.first_name, c.last_name, c.email, c.gender, 
        c.age_group, c.city, c.state_province, c.country, c.acquisition_channel, c.signup_date;

    -- Section 2: Recent Order History (up to 5 most recent orders)
    SELECT
        o.order_id,
        o.order_date,
        o.order_status,
        o.payment_method,
        o.total_amount,
        COUNT(oi.order_item_id) AS items_in_order
    FROM fact_orders o
    LEFT JOIN fact_order_items oi ON o.order_id = oi.order_id
    WHERE o.customer_id = in_customer_id
    GROUP BY o.order_id, o.order_date, o.order_status, o.payment_method, o.total_amount
    ORDER BY o.order_date DESC
    LIMIT 5;

    -- Section 3: Favorite Categories by Spend
    SELECT
        cat.category_name,
        COUNT(oi.order_item_id) AS items_purchased,
        ROUND(SUM(oi.line_total), 2) AS category_spend
    FROM fact_orders o
    JOIN fact_order_items oi ON o.order_id = oi.order_id
    JOIN dim_products p ON oi.product_id = p.product_id
    JOIN dim_categories cat ON p.category_id = cat.category_id
    WHERE o.customer_id = in_customer_id AND o.order_status NOT IN ('Cancelled')
    GROUP BY cat.category_name
    ORDER BY category_spend DESC
    LIMIT 3;
END //

DELIMITER ;


-- ====================================================================================
-- 5. STORED PROCEDURE: Monthly Executive Flash Report
-- Parameters: in_year INT, in_month INT
-- Returns: Summary metrics and top performing products for a given period
-- ====================================================================================
DELIMITER //

CREATE PROCEDURE sp_monthly_executive_report(IN in_year INT, IN in_month INT)
BEGIN
    -- Summary KPIs for the selected month
    SELECT
        CONCAT(in_year, '-', LPAD(in_month, 2, '0')) AS reporting_period,
        COUNT(DISTINCT o.order_id) AS total_orders,
        COUNT(DISTINCT o.customer_id) AS active_customers,
        ROUND(SUM(CASE WHEN o.order_status NOT IN ('Cancelled', 'Returned') THEN o.total_amount ELSE 0 END), 2) AS net_revenue,
        ROUND(AVG(CASE WHEN o.order_status NOT IN ('Cancelled', 'Returned') THEN o.total_amount END), 2) AS average_order_value,
        ROUND(
            (COUNT(DISTINCT CASE WHEN o.order_status = 'Returned' THEN o.order_id END) 
            / NULLIF(COUNT(DISTINCT o.order_id), 0)) * 100, 
            2
        ) AS return_rate_pct
    FROM fact_orders o
    WHERE YEAR(o.order_date) = in_year AND MONTH(o.order_date) = in_month;

    -- Top 5 Revenue-Driving Products for the month
    SELECT
        p.product_name,
        cat.category_name,
        SUM(oi.quantity) AS units_sold,
        ROUND(SUM(oi.line_total), 2) AS product_revenue
    FROM fact_orders o
    JOIN fact_order_items oi ON o.order_id = oi.order_id
    JOIN dim_products p ON oi.product_id = p.product_id
    JOIN dim_categories cat ON p.category_id = cat.category_id
    WHERE YEAR(o.order_date) = in_year 
      AND MONTH(o.order_date) = in_month
      AND o.order_status NOT IN ('Cancelled', 'Returned')
    GROUP BY p.product_name, cat.category_name
    ORDER BY product_revenue DESC
    LIMIT 5;
END //

DELIMITER ;
