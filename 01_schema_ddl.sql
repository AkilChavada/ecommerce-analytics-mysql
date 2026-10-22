-- ====================================================================================
-- Project: NovaMart Global E-Commerce Analytics Platform
-- File: 01_schema_ddl.sql
-- Description: Database Schema Definition (DDL) with Star/Snowflake hybrid architecture
-- Target RDBMS: MySQL 8.0+
-- Author: Data Analytics Portfolio Project
-- ====================================================================================

-- 1. Database Creation
CREATE DATABASE IF NOT EXISTS novamart_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE novamart_db;

-- Disable Foreign Key checks for clean teardown and build
SET FOREIGN_KEY_CHECKS = 0;

DROP TABLE IF EXISTS fact_customer_reviews;
DROP TABLE IF EXISTS fact_order_items;
DROP TABLE IF EXISTS fact_orders;
DROP TABLE IF EXISTS dim_marketing_campaigns;
DROP TABLE IF EXISTS dim_products;
DROP TABLE IF EXISTS dim_categories;
DROP TABLE IF EXISTS dim_customers;

SET FOREIGN_KEY_CHECKS = 1;

-- ====================================================================================
-- 2. Dimension Tables
-- ====================================================================================

-- Category Dimension
CREATE TABLE dim_categories (
    category_id         INT AUTO_INCREMENT PRIMARY KEY,
    category_name       VARCHAR(60) NOT NULL,
    department          VARCHAR(60) NOT NULL,
    description         VARCHAR(255),
    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_category_name UNIQUE (category_name)
) ENGINE=InnoDB COMMENT='Product categories and department hierarchy';

-- Product Dimension
CREATE TABLE dim_products (
    product_id          INT AUTO_INCREMENT PRIMARY KEY,
    sku                 VARCHAR(30) NOT NULL,
    product_name        VARCHAR(150) NOT NULL,
    category_id         INT NOT NULL,
    cost_price          DECIMAL(10,2) NOT NULL COMMENT 'Unit acquisition / manufacturing cost',
    retail_price        DECIMAL(10,2) NOT NULL COMMENT 'MSRP / standard selling price',
    stock_quantity      INT NOT NULL DEFAULT 0 COMMENT 'Current units available in fulfillment centers',
    reorder_threshold   INT NOT NULL DEFAULT 15 COMMENT 'Minimum inventory before restock trigger',
    is_active           TINYINT(1) NOT NULL DEFAULT 1,
    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_product_sku UNIQUE (sku),
    CONSTRAINT fk_products_category FOREIGN KEY (category_id) 
        REFERENCES dim_categories(category_id) 
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_prices CHECK (retail_price >= cost_price AND cost_price >= 0),
    CONSTRAINT chk_stock CHECK (stock_quantity >= 0)
) ENGINE=InnoDB COMMENT='Master product catalog and inventory health';

-- Customer Dimension
CREATE TABLE dim_customers (
    customer_id         INT AUTO_INCREMENT PRIMARY KEY,
    first_name          VARCHAR(50) NOT NULL,
    last_name           VARCHAR(50) NOT NULL,
    email               VARCHAR(120) NOT NULL,
    gender              ENUM('Male', 'Female', 'Non-Binary', 'Not Specified') DEFAULT 'Not Specified',
    age_group           ENUM('18-24', '25-34', '35-44', '45-54', '55+') NOT NULL,
    city                VARCHAR(60) NOT NULL,
    state_province      VARCHAR(60) NOT NULL,
    country             VARCHAR(60) NOT NULL DEFAULT 'United States',
    acquisition_channel VARCHAR(40) NOT NULL COMMENT 'e.g., Organic, Google Ads, Meta Ads, Email, Affiliate',
    signup_date         DATE NOT NULL,
    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_customer_email UNIQUE (email)
) ENGINE=InnoDB COMMENT='Customer demographics and acquisition channels';

-- Marketing Campaigns Dimension
CREATE TABLE dim_marketing_campaigns (
    campaign_id         INT AUTO_INCREMENT PRIMARY KEY,
    campaign_name       VARCHAR(100) NOT NULL,
    channel             VARCHAR(50) NOT NULL COMMENT 'e.g., Search, Social, Email, Influencer, Display',
    budget              DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    start_date          DATE NOT NULL,
    end_date            DATE NOT NULL,
    target_audience     VARCHAR(100),
    CONSTRAINT chk_campaign_dates CHECK (end_date >= start_date)
) ENGINE=InnoDB COMMENT='Marketing initiatives for attribution and ROI analysis';

-- ====================================================================================
-- 3. Fact Tables
-- ====================================================================================

-- Orders Fact Table
CREATE TABLE fact_orders (
    order_id            INT AUTO_INCREMENT PRIMARY KEY,
    customer_id         INT NOT NULL,
    campaign_id         INT NULL COMMENT 'Nullable: Organic or direct purchases have no campaign tag',
    order_date          DATETIME NOT NULL,
    order_status        ENUM('Delivered', 'Shipped', 'Processing', 'Cancelled', 'Returned') NOT NULL DEFAULT 'Delivered',
    payment_method      VARCHAR(40) NOT NULL COMMENT 'e.g., Credit Card, PayPal, Apple Pay, BNPL',
    shipping_fee        DECIMAL(6,2) NOT NULL DEFAULT 0.00,
    tax_amount          DECIMAL(8,2) NOT NULL DEFAULT 0.00,
    total_amount        DECIMAL(12,2) NOT NULL DEFAULT 0.00 COMMENT 'Order grand total',
    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id)
        REFERENCES dim_customers(customer_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_orders_campaign FOREIGN KEY (campaign_id)
        REFERENCES dim_marketing_campaigns(campaign_id)
        ON UPDATE CASCADE ON DELETE SET NULL
) ENGINE=InnoDB COMMENT='Transaction header records';

-- Order Line Items Fact Table
CREATE TABLE fact_order_items (
    order_item_id       INT AUTO_INCREMENT PRIMARY KEY,
    order_id            INT NOT NULL,
    product_id          INT NOT NULL,
    quantity            INT NOT NULL DEFAULT 1,
    unit_price          DECIMAL(10,2) NOT NULL COMMENT 'Unit selling price at transaction time',
    discount_amount     DECIMAL(10,2) NOT NULL DEFAULT 0.00 COMMENT 'Promotional coupon or line discount',
    line_total          DECIMAL(10,2) GENERATED ALWAYS AS (ROUND((quantity * unit_price) - discount_amount, 2)) STORED,
    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_items_order FOREIGN KEY (order_id)
        REFERENCES fact_orders(order_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_items_product FOREIGN KEY (product_id)
        REFERENCES dim_products(product_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT chk_item_quantity CHECK (quantity > 0),
    CONSTRAINT chk_item_price CHECK (unit_price >= 0),
    CONSTRAINT chk_item_discount CHECK (discount_amount >= 0)
) ENGINE=InnoDB COMMENT='Granular line item purchases per order';

-- Customer Product Reviews Fact Table
CREATE TABLE fact_customer_reviews (
    review_id           INT AUTO_INCREMENT PRIMARY KEY,
    product_id          INT NOT NULL,
    customer_id         INT NOT NULL,
    order_id            INT NULL,
    rating              TINYINT NOT NULL COMMENT 'Customer rating from 1 (poor) to 5 (excellent)',
    review_title        VARCHAR(120),
    review_text         TEXT,
    sentiment_tag       ENUM('Positive', 'Neutral', 'Negative') NOT NULL,
    review_date         DATETIME NOT NULL,
    CONSTRAINT fk_reviews_product FOREIGN KEY (product_id)
        REFERENCES dim_products(product_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_reviews_customer FOREIGN KEY (customer_id)
        REFERENCES dim_customers(customer_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_reviews_order FOREIGN KEY (order_id)
        REFERENCES fact_orders(order_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT chk_review_rating CHECK (rating BETWEEN 1 AND 5)
) ENGINE=InnoDB COMMENT='Customer sentiment and product satisfaction metrics';

-- ====================================================================================
-- 4. Analytical Performance Indexing
-- ====================================================================================

-- Composite index for temporal slicing and customer cohort analysis
CREATE INDEX idx_orders_customer_date ON fact_orders (customer_id, order_date);

-- Index for executive revenue reporting filtered by status and date
CREATE INDEX idx_orders_date_status ON fact_orders (order_date, order_status);

-- Foreign key lookup optimization for basket affinity joins
CREATE INDEX idx_order_items_product_order ON fact_order_items (product_id, order_id);

-- Customer acquisition cohort indexing
CREATE INDEX idx_customers_signup ON dim_customers (signup_date, acquisition_channel);

-- Inventory and pricing lookups
CREATE INDEX idx_products_cat_price ON dim_products (category_id, retail_price);
