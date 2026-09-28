#!/bin/bash
# Create the Cash-a-lot database and user
# This runs as the POSTGRES_USER (bartender) which has superuser rights
# on first init of the PostgreSQL container

set -e

echo "Creating Cash-a-lot database and user..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Create cashalot user (if not exists)
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'cashalot') THEN
            CREATE ROLE cashalot WITH LOGIN PASSWORD '${CASHALOT_DB_PASSWORD}';
        END IF;
    END
    \$\$;

    -- Create cashalot database (if not exists)
    SELECT 'CREATE DATABASE cashalot OWNER cashalot'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'cashalot')\gexec

    -- Grant privileges
    GRANT ALL PRIVILEGES ON DATABASE cashalot TO cashalot;
EOSQL

echo "Cash-a-lot database and user created successfully."

# Now init the schema on the cashalot database
echo "Initializing Cash-a-lot schema..."
psql -v ON_ERROR_STOP=1 --username "cashalot" --dbname "cashalot" <<-'EOSQL'
    -- Cash-a-lot - Autonomous AI Crypto Trading Agent - Database Schema

    -- Budget tracking
    CREATE TABLE IF NOT EXISTS budget (
        id SERIAL PRIMARY KEY,
        initial_total_eur DECIMAL(10,4) NOT NULL,
        total_deposited_eur DECIMAL(10,4) NOT NULL DEFAULT 0,
        ai_budget_total DECIMAL(10,6) NOT NULL,
        ai_budget_remaining DECIMAL(10,6) NOT NULL,
        trade_budget_initial_eur DECIMAL(10,4) NOT NULL,
        status VARCHAR(20) DEFAULT 'ACTIVE',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    -- Trade history
    CREATE TABLE IF NOT EXISTS trades (
        id SERIAL PRIMARY KEY,
        coin VARCHAR(20) NOT NULL,
        action VARCHAR(10) NOT NULL,
        amount_usdt DECIMAL(12,4) NOT NULL,
        price DECIMAL(16,8) NOT NULL,
        quantity DECIMAL(16,8) NOT NULL,
        fee_usdt DECIMAL(10,6) DEFAULT 0,
        ai_reasoning TEXT,
        ai_confidence DECIMAL(3,2),
        is_simulated BOOLEAN DEFAULT TRUE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    CREATE INDEX IF NOT EXISTS idx_trades_coin ON trades(coin);
    CREATE INDEX IF NOT EXISTS idx_trades_created ON trades(created_at DESC);

    -- Current positions
    CREATE TABLE IF NOT EXISTS positions (
        id SERIAL PRIMARY KEY,
        coin VARCHAR(20) NOT NULL UNIQUE,
        quantity DECIMAL(16,8) DEFAULT 0,
        avg_entry_price DECIMAL(16,8) DEFAULT 0,
        total_invested_usdt DECIMAL(12,4) DEFAULT 0,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    -- AI call log (cost tracking)
    CREATE TABLE IF NOT EXISTS ai_calls (
        id SERIAL PRIMARY KEY,
        input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        cost_usd DECIMAL(10,6) NOT NULL,
        response_summary TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    -- Budget snapshots (for dashboard chart)
    CREATE TABLE IF NOT EXISTS budget_snapshots (
        id SERIAL PRIMARY KEY,
        total_value_eur DECIMAL(10,4) NOT NULL,
        portfolio_value_usdt DECIMAL(12,4) NOT NULL,
        cash_usdt DECIMAL(12,4) NOT NULL,
        ai_budget_remaining DECIMAL(10,6) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    -- Retraits intelligents (vente auto + conversion USDT→EUR)
    CREATE TABLE IF NOT EXISTS withdrawals (
        id SERIAL PRIMARY KEY,
        amount_eur_requested DECIMAL(12,4) NOT NULL,
        amount_usdt_sold DECIMAL(12,4) DEFAULT 0,
        amount_eur_received DECIMAL(12,4) DEFAULT 0,
        eurusdt_rate DECIMAL(12,6),
        positions_sold JSONB DEFAULT '[]',
        status VARCHAR(20) DEFAULT 'COMPLETED',
        note TEXT,
        is_simulated BOOLEAN DEFAULT TRUE,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    -- Migration manuelle pour DB existante (dépôts) :
    -- ALTER TABLE budget ADD COLUMN IF NOT EXISTS total_deposited_eur DECIMAL(10,4) NOT NULL DEFAULT 0;
    -- UPDATE budget SET total_deposited_eur = initial_total_eur;

    -- Migration manuelle pour DB existante :
    -- ALTER TABLE withdrawals RENAME COLUMN amount_usdt TO amount_eur_requested;
    -- ALTER TABLE withdrawals ADD COLUMN amount_usdt_sold DECIMAL(12,4) DEFAULT 0;
    -- ALTER TABLE withdrawals ADD COLUMN amount_eur_received DECIMAL(12,4) DEFAULT 0;
    -- ALTER TABLE withdrawals ADD COLUMN eurusdt_rate DECIMAL(12,6);
    -- ALTER TABLE withdrawals ADD COLUMN positions_sold JSONB DEFAULT '[]';
    -- ALTER TABLE withdrawals ADD COLUMN status VARCHAR(20) DEFAULT 'COMPLETED';
    -- ALTER TABLE withdrawals ADD COLUMN is_simulated BOOLEAN DEFAULT TRUE;

    -- Auto-update updated_at trigger
    CREATE OR REPLACE FUNCTION update_updated_at()
    RETURNS TRIGGER AS $$
    BEGIN
        NEW.updated_at = CURRENT_TIMESTAMP;
        RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    DROP TRIGGER IF EXISTS trigger_budget_updated_at ON budget;
    CREATE TRIGGER trigger_budget_updated_at
        BEFORE UPDATE ON budget FOR EACH ROW
        EXECUTE FUNCTION update_updated_at();

    DROP TRIGGER IF EXISTS trigger_positions_updated_at ON positions;
    CREATE TRIGGER trigger_positions_updated_at
        BEFORE UPDATE ON positions FOR EACH ROW
        EXECUTE FUNCTION update_updated_at();
EOSQL

echo "Cash-a-lot schema initialized successfully."
