#!/bin/bash
# Create the MTG database and user
# This runs as the POSTGRES_USER (bartender) which has superuser rights
# on first init of the PostgreSQL container

set -e

echo "Creating MTG database and user..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Create MTG user (if not exists)
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'mtg') THEN
            CREATE ROLE mtg WITH LOGIN PASSWORD '${MTG_DB_PASSWORD}';
        END IF;
    END
    \$\$;

    -- Create MTG database (if not exists)
    SELECT 'CREATE DATABASE mtg_collection OWNER mtg'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'mtg_collection')\gexec

    -- Grant privileges
    GRANT ALL PRIVILEGES ON DATABASE mtg_collection TO mtg;
EOSQL

echo "MTG database and user created successfully."

# Now init the MTG schema on the mtg_collection database
echo "Initializing MTG schema..."
psql -v ON_ERROR_STOP=1 --username "mtg" --dbname "mtg_collection" <<-'EOSQL'
    -- MTG Collection Tracker - Database Schema

    -- Create collection table
    CREATE TABLE IF NOT EXISTS collection (
        id SERIAL PRIMARY KEY,
        scryfall_id VARCHAR(36) NOT NULL,
        card_name VARCHAR(255) NOT NULL,
        set_code VARCHAR(10),
        set_name VARCHAR(255),
        collector_number VARCHAR(20),
        rarity VARCHAR(20),
        mana_cost VARCHAR(100),
        type_line VARCHAR(255),
        oracle_text TEXT,
        image_url TEXT,
        price_usd DECIMAL(10, 2),
        quantity INTEGER DEFAULT 1,
        foil BOOLEAN DEFAULT FALSE,
        condition VARCHAR(20) DEFAULT 'NM',
        notes TEXT,
        added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );

    -- Index for faster lookups
    CREATE INDEX IF NOT EXISTS idx_collection_scryfall_id ON collection(scryfall_id);
    CREATE INDEX IF NOT EXISTS idx_collection_card_name ON collection(card_name);
    CREATE INDEX IF NOT EXISTS idx_collection_set_code ON collection(set_code);

    -- Function to update timestamp
    CREATE OR REPLACE FUNCTION update_updated_at()
    RETURNS TRIGGER AS $$
    BEGIN
        NEW.updated_at = CURRENT_TIMESTAMP;
        RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    -- Trigger to auto-update timestamp
    DROP TRIGGER IF EXISTS trigger_collection_updated_at ON collection;
    CREATE TRIGGER trigger_collection_updated_at
        BEFORE UPDATE ON collection
        FOR EACH ROW
        EXECUTE FUNCTION update_updated_at();
EOSQL

echo "MTG schema initialized successfully."
