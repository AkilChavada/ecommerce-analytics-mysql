-- ====================================================================================
-- Project: NovaMart Global E-Commerce Analytics Platform
-- File: 03_analytical_queries.sql
-- Description: 10 Comprehensive Portfolio SQL Queries for Data Analysts
-- Target RDBMS: MySQL 8.0+
-- Concepts: CTEs, Window Functions (LAG, LEAD, NTILE, SUM/AVG OVER), Cohorts, RFM,
--           Market Basket Self-Joins, Marketing Attribution, Inventory Health
-- ====================================================================================

USE novamart_db;

-- ====================================================================================
-- QUERY 1: Executive Monthly Financial Performance & MoM Growth Trends
-- ------------------------------------------------------------------------------------
-- Business Question:
-- How has NovaMart's net revenue, order volume, and Average Order Value (AOV) trended
-- month-over-month? What is our 3-month smoothed revenue run-rate?
--
-- SQL Concepts Used:
-- Chained CTEs, Window Functions (LAG, AVG OVER with ROWS frame), Date formatting.
-- ====================================================================================

WITH monthly_sales AS (
    SELECT
        DATE_FORMAT(order_date, '%Y-%m') AS sales_month,
        COUNT(DISTINCT order_id) AS total_orders,
        COUNT(DISTINCT customer_id) AS active_customers,
        ROUND(SUM(total_amount), 2) AS gross_revenue,
        ROUND(SUM(CASE WHEN order_status = 'Returned' THEN total_amount ELSE 0 END), 2) AS returned_revenue,
        ROUND(SUM(CASE WHEN order_status NOT IN ('Cancelled', 'Returned') THEN total_amount ELSE 0 END), 2) AS net_revenue
    FROM fact_orders
    GROUP BY DATE_FORMAT(order_date, '%Y-%m')
),
sales_metrics AS (
    SELECT
        sales_month,
        total_orders,
        active_customers,
        net_revenue,
        ROUND(net_revenue / NULLIF(total_orders, 0), 2) AS average_order_value,
        LAG(net_revenue, 1) OVER (ORDER BY sales_month) AS prev_month_net_revenue,
        -- 3-Month Moving Average (Smoothed trendline)
        ROUND(AVG(net_revenue) OVER (
            ORDER BY sales_month 
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ), 2) AS rolling_3mo_avg_revenue
    FROM monthly_sales
)
SELECT
    sales_month,
    total_orders,
    active_customers,
    net_revenue,
    average_order_value,
    prev_month_net_revenue,
    ROUND(
        ((net_revenue - prev_month_net_revenue) / NULLIF(prev_month_net_revenue, 0)) * 100, 
        2
    ) AS mom_growth_pct,
    rolling_3mo_avg_revenue
FROM sales_metrics
ORDER BY sales_month ASC;


-- ====================================================================================
-- QUERY 2: Year-over-Year (YoY) Department Performance & Revenue Contribution
-- ------------------------------------------------------------------------------------
-- Business Question:
-- Which product departments are driving growth year-over-year (2024 vs 2025)?
-- What percentage of company revenue does each department represent?
--
-- SQL Concepts Used:
-- Window Functions (SUM() OVER(PARTITION BY Year)), Multi-table joins, Aggregations.
-- ====================================================================================

WITH dept_yearly AS (
    SELECT
        YEAR(o.order_date) AS order_year,
        c.department,
        ROUND(SUM(oi.line_total), 2) AS department_revenue,
        SUM(oi.quantity) AS total_units_sold
    FROM fact_order_items oi
    JOIN fact_orders o ON oi.order_id = o.order_id
    JOIN dim_products p ON oi.product_id = p.product_id
    JOIN dim_categories c ON p.category_id = c.category_id
    WHERE o.order_status NOT IN ('Cancelled', 'Returned')
      AND YEAR(o.order_date) IN (2024, 2025)
    GROUP BY YEAR(o.order_date), c.department
)
SELECT
    order_year,
    department,
    department_revenue,
    total_units_sold,
    -- Calculate % share of annual revenue
    ROUND(
        (department_revenue / SUM(department_revenue) OVER (PARTITION BY order_year)) * 100, 
        2
    ) AS pct_of_annual_revenue,
    -- YoY Growth Calculation
    LAG(department_revenue, 1) OVER (PARTITION BY department ORDER BY order_year) AS prev_year_revenue,
    ROUND(
        ((department_revenue - LAG(department_revenue, 1) OVER (PARTITION BY department ORDER BY order_year)) 
        / NULLIF(LAG(department_revenue, 1) OVER (PARTITION BY department ORDER BY order_year), 0)) * 100,
        2
    ) AS yoy_growth_pct
FROM dept_yearly
ORDER BY department, order_year;


-- ====================================================================================
-- QUERY 3: Customer RFM Segmentation (Recency, Frequency, Monetary)
-- ------------------------------------------------------------------------------------
-- Business Question:
-- How are our customers distributed across RFM quartiles? Who are our 'Champions',
-- 'Loyal Customers', 'At Risk', and 'Lost' buyers for targeted CRM marketing?
--
-- SQL Concepts Used:
-- NTILE(4) Window Function, DATEDIFF, CASE statements, Complex behavioral modeling.
-- ====================================================================================

WITH customer_rfm_raw AS (
    SELECT
        c.customer_id,
        CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
        c.acquisition_channel,
        -- Recency: Days between reference date (latest order in db: 2026-09-15) and last purchase
        DATEDIFF('2026-09-15', MAX(o.order_date)) AS recency_days,
        -- Frequency: Count of completed orders
        COUNT(DISTINCT o.order_id) AS frequency_orders,
        -- Monetary: Total spend on completed orders
        ROUND(SUM(o.total_amount), 2) AS monetary_spend
    FROM dim_customers c
    JOIN fact_orders o ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('Cancelled')
    GROUP BY c.customer_id, c.first_name, c.last_name, c.acquisition_channel
),
rfm_scores AS (
    SELECT
        customer_id,
        customer_name,
        acquisition_channel,
        recency_days,
        frequency_orders,
        monetary_spend,
        -- Lower recency days = better score (4 is highest/best)
        NTILE(4) OVER (ORDER BY recency_days DESC) AS r_score,
        -- Higher frequency = better score
        NTILE(4) OVER (ORDER BY frequency_orders ASC) AS f_score,
        -- Higher monetary = better score
        NTILE(4) OVER (ORDER BY monetary_spend ASC) AS m_score
    FROM customer_rfm_raw
),
rfm_segmented AS (
    SELECT
        customer_id,
        customer_name,
        acquisition_channel,
        recency_days,
        frequency_orders,
        monetary_spend,
        CONCAT(r_score, f_score, m_score) AS rfm_combined,
        ROUND((r_score + f_score + m_score) / 3.0, 1) AS rfm_avg,
        CASE
            WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3 THEN 'Champions / VIP'
            WHEN r_score >= 3 AND f_score >= 2 THEN 'Loyal Customers'
            WHEN r_score >= 3 AND f_score = 1 THEN 'Recent New Customers'
            WHEN r_score <= 2 AND f_score >= 3 THEN 'At Risk / Need Attention'
            WHEN r_score = 1 AND f_score >= 2 THEN 'Lapsed Repeat Customers'
            ELSE 'Hibernating / Inactive'
        END AS customer_segment
    FROM rfm_scores
)
-- Display customer segment summary with marketing recommendations
SELECT
    customer_segment,
    COUNT(*) AS total_customers,
    ROUND(AVG(recency_days), 0) AS avg_recency_days,
    ROUND(AVG(frequency_orders), 1) AS avg_orders,
    ROUND(AVG(monetary_spend), 2) AS avg_customer_spend,
    ROUND(SUM(monetary_spend), 2) AS total_segment_revenue,
    ROUND((SUM(monetary_spend) / (SELECT SUM(monetary_spend) FROM rfm_segmented)) * 100, 2) AS pct_total_revenue
FROM rfm_segmented
GROUP BY customer_segment
ORDER BY total_segment_revenue DESC;


-- ====================================================================================
-- QUERY 4: Monthly Cohort Retention Analysis (Cohort Matrix / Heatmap Data)
-- ------------------------------------------------------------------------------------
-- Business Question:
-- What percentage of customers acquired in a given month return to make repeat purchases
-- in month 1, month 2, and subsequent months?
--
-- SQL Concepts Used:
-- Multi-level CTEs, TIMESTAMPDIFF(MONTH), Self-joins, Pivot logic using CASE / Conditional Aggregation.
-- ====================================================================================

WITH customer_first_purchase AS (
    -- Identify the inception month (Cohort) for every customer
    SELECT
        customer_id,
        DATE_FORMAT(MIN(order_date), '%Y-%m-01') AS cohort_month
    FROM fact_orders
    WHERE order_status NOT IN ('Cancelled')
    GROUP BY customer_id
),
cohort_activity AS (
    -- Map all customer purchases back to their cohort month
    SELECT
        fp.cohort_month,
        o.customer_id,
        TIMESTAMPDIFF(MONTH, fp.cohort_month, DATE_FORMAT(o.order_date, '%Y-%m-01')) AS month_number
    FROM fact_orders o
    JOIN customer_first_purchase fp ON o.customer_id = fp.customer_id
    WHERE o.order_status NOT IN ('Cancelled')
),
cohort_size AS (
    -- Size of each cohort at Month 0
    SELECT
        cohort_month,
        COUNT(DISTINCT customer_id) AS total_cohort_users
    FROM customer_first_purchase
    GROUP BY cohort_month
),
retention_matrix AS (
    SELECT
        ca.cohort_month,
        cs.total_cohort_users,
        ca.month_number,
        COUNT(DISTINCT ca.customer_id) AS active_users
    FROM cohort_activity ca
    JOIN cohort_size cs ON ca.cohort_month = cs.cohort_month
    GROUP BY ca.cohort_month, cs.total_cohort_users, ca.month_number
)
-- Pivot the first 4 months into tabular cohort format
SELECT
    cohort_month,
    total_cohort_users AS m0_cohort_size,
    ROUND(MAX(CASE WHEN month_number = 1 THEN active_users ELSE 0 END) / total_cohort_users * 100, 1) AS m1_retention_pct,
    ROUND(MAX(CASE WHEN month_number = 2 THEN active_users ELSE 0 END) / total_cohort_users * 100, 1) AS m2_retention_pct,
    ROUND(MAX(CASE WHEN month_number = 3 THEN active_users ELSE 0 END) / total_cohort_users * 100, 1) AS m3_retention_pct,
    ROUND(MAX(CASE WHEN month_number = 4 THEN active_users ELSE 0 END) / total_cohort_users * 100, 1) AS m4_retention_pct
FROM retention_matrix
GROUP BY cohort_month, total_cohort_users
ORDER BY cohort_month ASC;


-- ====================================================================================
-- QUERY 5: Market Basket Analysis (Item Affinity & Product Bundling)
-- ------------------------------------------------------------------------------------
-- Business Question:
-- Which product combinations are most frequently purchased together in the same order?
-- What bundles can we promote on product display pages to increase AOV?
--
-- SQL Concepts Used:
-- Non-equi Self-Join (`a.product_id < b.product_id`), DENSE_RANK() window function.
-- ====================================================================================

WITH co_purchased_pairs AS (
    SELECT
        oi1.product_id AS product_a_id,
        p1.product_name AS product_a_name,
        oi2.product_id AS product_b_id,
        p2.product_name AS product_b_name,
        COUNT(DISTINCT oi1.order_id) AS co_purchase_count
    FROM fact_order_items oi1
    JOIN fact_order_items oi2 
        ON oi1.order_id = oi2.order_id 
        AND oi1.product_id < oi2.product_id -- Prevents duplicate symmetrical pairs (A-B and B-A)
    JOIN dim_products p1 ON oi1.product_id = p1.product_id
    JOIN dim_products p2 ON oi2.product_id = p2.product_id
    JOIN fact_orders o ON oi1.order_id = o.order_id
    WHERE o.order_status NOT IN ('Cancelled')
    GROUP BY oi1.product_id, p1.product_name, oi2.product_id, p2.product_name
)
SELECT
    product_a_name,
    product_b_name,
    co_purchase_count,
    DENSE_RANK() OVER (ORDER BY co_purchase_count DESC) AS affinity_rank,
    -- Recommendation strategy based on pairing
    CASE
        WHEN co_purchase_count >= 5 THEN 'Strong Affinity: Create 10% Discounted Bundle'
        WHEN co_purchase_count >= 3 THEN 'Moderate Affinity: Add to Checkout Cross-Sell'
        ELSE 'Emerging Pair: Test in Email Campaigns'
    END AS cross_sell_recommendation
FROM co_purchased_pairs
ORDER BY co_purchase_count DESC
LIMIT 10;


-- ====================================================================================
-- QUERY 6: Customer Inactivity & Churn Risk Predictor
-- ------------------------------------------------------------------------------------
-- Business Question:
-- Which repeat customers are exhibiting churn risk (no orders in over 90 days,
-- despite previously purchasing consistently)?
--
-- SQL Concepts Used:
-- Window Functions (LAG with PARTITION BY), AVG(), DATEDIFF, Risk Tier Categorization.
-- ====================================================================================

WITH customer_order_timeline AS (
    SELECT
        customer_id,
        order_id,
        order_date,
        LAG(order_date, 1) OVER (
            PARTITION BY customer_id 
            ORDER BY order_date
        ) AS prev_order_date
    FROM fact_orders
    WHERE order_status NOT IN ('Cancelled')
),
customer_cadence AS (
    SELECT
        customer_id,
        COUNT(order_id) AS total_orders,
        MAX(order_date) AS last_order_date,
        DATEDIFF('2026-09-15', MAX(order_date)) AS days_since_last_order,
        ROUND(AVG(DATEDIFF(order_date, prev_order_date)), 1) AS avg_days_between_orders
    FROM customer_order_timeline
    GROUP BY customer_id
    HAVING COUNT(order_id) >= 2 -- Focus on customers with an established purchase habit
)
SELECT
    c.customer_id,
    CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
    c.email,
    cc.total_orders,
    cc.last_order_date,
    cc.avg_days_between_orders,
    cc.days_since_last_order,
    -- Ratio of inactivity relative to expected buying cadence
    ROUND(cc.days_since_last_order / NULLIF(cc.avg_days_between_orders, 0), 2) AS churn_cadence_ratio,
    CASE
        WHEN cc.days_since_last_order > (cc.avg_days_between_orders * 2.5) THEN 'High Risk: Send Urgent Win-Back Promo'
        WHEN cc.days_since_last_order > (cc.avg_days_between_orders * 1.5) THEN 'Medium Risk: Send Product Recommendations'
        ELSE 'Healthy / On Cadence'
    END AS churn_risk_status
FROM customer_cadence cc
JOIN dim_customers c ON cc.customer_id = c.customer_id
WHERE cc.days_since_last_order > cc.avg_days_between_orders
ORDER BY churn_cadence_ratio DESC;


-- ====================================================================================
-- QUERY 7: Marketing Campaign Return on Ad Spend (ROAS) & Channel Efficiency
-- ------------------------------------------------------------------------------------
-- Business Question:
-- What is the ROAS and customer acquisition efficiency for each promotional campaign?
-- Which marketing channels generate the highest net profit?
--
-- SQL Concepts Used:
-- Aggregation across Fact & Dimension, ROAS calculation, Profit Margin analysis.
-- ====================================================================================

SELECT
    mc.campaign_id,
    mc.campaign_name,
    mc.channel,
    mc.budget,
    COUNT(DISTINCT o.order_id) AS attributed_orders,
    COUNT(DISTINCT o.customer_id) AS unique_purchasers,
    ROUND(SUM(oi.line_total), 2) AS attributed_revenue,
    ROUND(SUM(oi.quantity * p.cost_price), 2) AS cost_of_goods_sold,
    -- Gross Margin = Attributed Revenue - COGS
    ROUND(SUM(oi.line_total) - SUM(oi.quantity * p.cost_price), 2) AS gross_profit,
    -- ROAS (Return On Ad Spend) = Revenue / Budget
    ROUND(SUM(oi.line_total) / NULLIF(mc.budget, 0), 2) AS roas_multiple,
    -- Net Marketing ROI = (Gross Profit - Budget) / Budget * 100
    ROUND(((SUM(oi.line_total) - SUM(oi.quantity * p.cost_price) - mc.budget) / NULLIF(mc.budget, 0)) * 100, 2) AS marketing_roi_pct
FROM dim_marketing_campaigns mc
LEFT JOIN fact_orders o ON mc.campaign_id = o.campaign_id AND o.order_status NOT IN ('Cancelled', 'Returned')
LEFT JOIN fact_order_items oi ON o.order_id = oi.order_id
LEFT JOIN dim_products p ON oi.product_id = p.product_id
GROUP BY mc.campaign_id, mc.campaign_name, mc.channel, mc.budget
ORDER BY roas_multiple DESC;


-- ====================================================================================
-- QUERY 8: Inventory Velocity, Stockout Alert & Days of Supply
-- ------------------------------------------------------------------------------------
-- Business Question:
-- Which products are at imminent risk of stocking out based on recent 90-day run rates?
-- Which products have excess capital trapped in overstocked inventory?
--
-- SQL Concepts Used:
-- Date boundary filtering, Daily sales velocity run-rate, Inventory turnover calculations.
-- ====================================================================================

WITH recent_velocity AS (
    SELECT
        oi.product_id,
        SUM(oi.quantity) AS units_sold_last_90d,
        ROUND(SUM(oi.quantity) / 90.0, 2) AS daily_run_rate
    FROM fact_order_items oi
    JOIN fact_orders o ON oi.order_id = o.order_id
    WHERE o.order_date >= '2026-06-15' -- Last 90 days relative to dataset horizon
      AND o.order_status NOT IN ('Cancelled', 'Returned')
    GROUP BY oi.product_id
)
SELECT
    p.product_id,
    p.sku,
    p.product_name,
    c.category_name,
    p.stock_quantity AS current_stock,
    p.reorder_threshold,
    COALESCE(rv.daily_run_rate, 0.00) AS daily_sales_velocity,
    -- Days of Inventory Remaining (DOI)
    CASE 
        WHEN COALESCE(rv.daily_run_rate, 0) = 0 THEN 999
        ELSE ROUND(p.stock_quantity / rv.daily_run_rate, 0)
    END AS estimated_days_of_supply,
    -- Restock Urgency Classification
    CASE
        WHEN p.stock_quantity <= p.reorder_threshold THEN 'CRITICAL: Below Reorder Point'
        WHEN (p.stock_quantity / NULLIF(rv.daily_run_rate, 0)) <= 15 THEN 'URGENT: Stockout within 15 Days'
        WHEN (p.stock_quantity / NULLIF(rv.daily_run_rate, 0)) > 120 THEN 'OVERSTOCKED: Capital Inefficient'
        ELSE 'HEALTHY: Optimal Stock Level'
    END AS inventory_health_status
FROM dim_products p
JOIN dim_categories c ON p.category_id = c.category_id
LEFT JOIN recent_velocity rv ON p.product_id = rv.product_id
ORDER BY estimated_days_of_supply ASC;


-- ====================================================================================
-- QUERY 9: Product Return Rate & Financial Margin Drag Analysis
-- ------------------------------------------------------------------------------------
-- Business Question:
-- What are the return rates per product category? How much revenue is eroded by returns?
-- Does customer review sentiment correlate with return frequency?
--
-- SQL Concepts Used:
-- Correlated subqueries / joins, Return rate ratios, Aggregation by sentiment.
-- ====================================================================================

WITH product_returns AS (
    SELECT
        p.product_id,
        p.product_name,
        c.category_name,
        COUNT(DISTINCT oi.order_item_id) AS total_units_ordered,
        COUNT(DISTINCT CASE WHEN o.order_status = 'Returned' THEN oi.order_item_id END) AS units_returned,
        ROUND(SUM(oi.line_total), 2) AS gross_sales,
        ROUND(SUM(CASE WHEN o.order_status = 'Returned' THEN oi.line_total ELSE 0 END), 2) AS refunded_revenue
    FROM dim_products p
    JOIN dim_categories c ON p.category_id = c.category_id
    JOIN fact_order_items oi ON p.product_id = oi.product_id
    JOIN fact_orders o ON oi.order_id = o.order_id
    WHERE o.order_status != 'Cancelled'
    GROUP BY p.product_id, p.product_name, c.category_name
),
product_ratings AS (
    SELECT
        product_id,
        ROUND(AVG(rating), 2) AS avg_review_rating,
        COUNT(review_id) AS review_count
    FROM fact_customer_reviews
    GROUP BY product_id
)
SELECT
    pr.category_name,
    pr.product_name,
    pr.total_units_ordered,
    pr.units_returned,
    ROUND((pr.units_returned / NULLIF(pr.total_units_ordered, 0)) * 100, 2) AS return_rate_pct,
    pr.refunded_revenue AS revenue_lost_to_returns,
    COALESCE(rt.avg_review_rating, 0.0) AS avg_rating,
    CASE
        WHEN (pr.units_returned / NULLIF(pr.total_units_ordered, 0)) > 0.12 THEN 'High Return Problem: Inspect QA & Description'
        WHEN (pr.units_returned / NULLIF(pr.total_units_ordered, 0)) > 0.06 THEN 'Moderate Return Rate: Monitor'
        ELSE 'Acceptable Return Rate'
    END AS quality_action_flag
FROM product_returns pr
LEFT JOIN product_ratings rt ON pr.product_id = rt.product_id
ORDER BY return_rate_pct DESC
LIMIT 15;


-- ====================================================================================
-- QUERY 10: Pareto Distribution Analysis (80/20 Rule) & Customer Concentration
-- ------------------------------------------------------------------------------------
-- Business Question:
-- Does the Pareto Principle apply to NovaMart? What percentage of our total revenue
-- is generated by the top 20% of our customer base?
--
-- SQL Concepts Used:
-- Window Functions (SUM() OVER unbounded preceding), CUME_DIST() / PERCENT_RANK(), CTEs.
-- ====================================================================================

WITH customer_spend AS (
    SELECT
        c.customer_id,
        CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
        ROUND(SUM(o.total_amount), 2) AS customer_revenue
    FROM dim_customers c
    JOIN fact_orders o ON c.customer_id = o.customer_id
    WHERE o.order_status NOT IN ('Cancelled', 'Returned')
    GROUP BY c.customer_id, c.first_name, c.last_name
),
pareto_calc AS (
    SELECT
        customer_id,
        customer_name,
        customer_revenue,
        -- Cumulative running total of revenue ordered by top spenders
        ROUND(SUM(customer_revenue) OVER (ORDER BY customer_revenue DESC), 2) AS running_cumulative_revenue,
        -- Total company net revenue
        ROUND(SUM(customer_revenue) OVER (), 2) AS total_revenue,
        -- Percentile rank of customers (0.00 to 1.00)
        ROUND(CUME_DIST() OVER (ORDER BY customer_revenue DESC) * 100, 2) AS customer_percentile
    FROM customer_spend
)
SELECT
    customer_id,
    customer_name,
    customer_revenue,
    running_cumulative_revenue,
    -- Cumulative % of revenue accounted for
    ROUND((running_cumulative_revenue / total_revenue) * 100, 2) AS cumulative_revenue_pct,
    customer_percentile,
    CASE 
        WHEN customer_percentile <= 20.00 THEN 'Top 20% VIP Tier'
        WHEN customer_percentile <= 50.00 THEN 'Core 21-50% Mid Tier'
        ELSE 'Tail 51-100% General Tier'
    END AS pareto_tier
FROM pareto_calc
ORDER BY customer_revenue DESC;
