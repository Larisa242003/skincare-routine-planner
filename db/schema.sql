-- =====================================================================
-- Skincare app: PostgreSQL schema
-- Requires PostgreSQL 13+ (gen_random_uuid() is built in).
-- Run with:  psql -d your_database -f schema.sql
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------
CREATE TYPE user_role        AS ENUM ('user', 'admin');
CREATE TYPE skin_type        AS ENUM ('dry', 'oily', 'combination', 'normal', 'sensitive');
CREATE TYPE product_category AS ENUM ('cleanser', 'toner', 'serum', 'treatment',
                                      'moisturizer', 'sunscreen', 'mask', 'other');
CREATE TYPE routine_period   AS ENUM ('morning', 'evening');
CREATE TYPE conflict_severity AS ENUM ('avoid', 'caution', 'note');
CREATE TYPE conflict_scope   AS ENUM ('same_routine', 'same_day');

-- ---------------------------------------------------------------------
-- Users and devices
-- ---------------------------------------------------------------------
CREATE TABLE users (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email          text        NOT NULL,
    password_hash  text        NOT NULL,
    role           user_role   NOT NULL DEFAULT 'user',
    skin_type      skin_type,
    concerns       text[]      NOT NULL DEFAULT '{}',
    morning_at     time        NOT NULL DEFAULT '08:00',
    evening_at     time        NOT NULL DEFAULT '21:00',
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_email_uq ON users (lower(email));

CREATE TABLE push_tokens (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token       text        NOT NULL UNIQUE,
    platform    text        NOT NULL CHECK (platform IN ('ios', 'android', 'web')),
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX push_tokens_user_idx ON push_tokens (user_id);

-- ---------------------------------------------------------------------
-- Catalog: products, ingredients, ingredient groups
-- ---------------------------------------------------------------------
CREATE TABLE products (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text             NOT NULL,
    brand       text,
    category    product_category NOT NULL DEFAULT 'other',
    barcode     text UNIQUE,
    created_by  uuid REFERENCES users(id) ON DELETE SET NULL,
    is_verified boolean          NOT NULL DEFAULT false,
    created_at  timestamptz      NOT NULL DEFAULT now()
);
CREATE INDEX products_name_idx ON products (lower(name));

CREATE TABLE ingredients (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inci_name    text NOT NULL UNIQUE,
    common_name  text,
    function     text,
    description  text
);

-- Ingredient order matters: INCI lists run from highest to lowest concentration.
CREATE TABLE product_ingredients (
    product_id    uuid NOT NULL REFERENCES products(id)    ON DELETE CASCADE,
    ingredient_id uuid NOT NULL REFERENCES ingredients(id) ON DELETE RESTRICT,
    position      int  NOT NULL CHECK (position > 0),
    PRIMARY KEY (product_id, ingredient_id),
    UNIQUE (product_id, position)
);
CREATE INDEX product_ingredients_ingredient_idx ON product_ingredients (ingredient_id);

CREATE TABLE ingredient_groups (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name         text NOT NULL UNIQUE,
    description  text
);

CREATE TABLE ingredient_group_members (
    ingredient_id uuid NOT NULL REFERENCES ingredients(id)       ON DELETE CASCADE,
    group_id      uuid NOT NULL REFERENCES ingredient_groups(id) ON DELETE CASCADE,
    PRIMARY KEY (ingredient_id, group_id)
);
CREATE INDEX ingredient_group_members_group_idx ON ingredient_group_members (group_id);

-- ---------------------------------------------------------------------
-- Conflict rules between ingredient groups
-- ---------------------------------------------------------------------
CREATE TABLE conflict_rules (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_a_id  uuid              NOT NULL REFERENCES ingredient_groups(id) ON DELETE CASCADE,
    group_b_id  uuid              NOT NULL REFERENCES ingredient_groups(id) ON DELETE CASCADE,
    severity    conflict_severity NOT NULL,
    scope       conflict_scope    NOT NULL DEFAULT 'same_routine',
    explanation text              NOT NULL,
    source_ref  text              -- citation for the rule (important for a thesis)
);
-- One rule per unordered pair of groups and scope: (A,B) and (B,A) count as the same.
CREATE UNIQUE INDEX conflict_rules_pair_uq
    ON conflict_rules (LEAST(group_a_id, group_b_id), GREATEST(group_a_id, group_b_id), scope);

-- ---------------------------------------------------------------------
-- A user's shelf and routines
-- ---------------------------------------------------------------------
CREATE TABLE user_products (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
    product_id  uuid NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    opened_on   date,
    added_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, product_id)
);

CREATE TABLE routines (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid           NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    period      routine_period NOT NULL,
    name        text           NOT NULL DEFAULT 'My routine',
    created_at  timestamptz    NOT NULL DEFAULT now()
);
CREATE INDEX routines_user_idx ON routines (user_id);

-- days: 0 = Monday ... 6 = Sunday. Defaults to every day.
CREATE TABLE routine_steps (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    routine_id       uuid NOT NULL REFERENCES routines(id)      ON DELETE CASCADE,
    user_product_id  uuid NOT NULL REFERENCES user_products(id) ON DELETE CASCADE,
    position         int  NOT NULL CHECK (position > 0),
    days             smallint[] NOT NULL DEFAULT '{0,1,2,3,4,5,6}'::smallint[],
    wait_minutes     int  NOT NULL DEFAULT 0 CHECK (wait_minutes >= 0),
    CHECK (cardinality(days) > 0 AND days <@ ARRAY[0,1,2,3,4,5,6]::smallint[]),
    -- Deferred so steps can be reordered inside one transaction.
    UNIQUE (routine_id, position) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX routine_steps_user_product_idx ON routine_steps (user_product_id);

-- One row per step per day it was ticked off on the Today screen.
CREATE TABLE step_logs (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    step_id   uuid NOT NULL REFERENCES routine_steps(id) ON DELETE CASCADE,
    done_on   date NOT NULL DEFAULT current_date,
    UNIQUE (step_id, done_on)
);

-- ---------------------------------------------------------------------
-- Skin diary
-- ---------------------------------------------------------------------
CREATE TABLE diary_entries (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    entry_date  date NOT NULL DEFAULT current_date,
    photo_key   text,                      -- key of the file in image storage
    tags        text[] NOT NULL DEFAULT '{}',
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX diary_entries_user_date_idx ON diary_entries (user_id, entry_date DESC);

-- ---------------------------------------------------------------------
-- View: conflicts inside each routine (same routine, overlapping days)
-- ---------------------------------------------------------------------
CREATE VIEW routine_conflicts AS
SELECT DISTINCT
       s1.routine_id,
       s1.id        AS step_a_id,
       s2.id        AS step_b_id,
       p1.name      AS product_a,
       p2.name      AS product_b,
       cr.severity,
       cr.explanation,
       cr.source_ref
FROM routine_steps s1
JOIN routine_steps s2
  ON s2.routine_id = s1.routine_id
 AND s1.id < s2.id
 AND s1.days && s2.days
JOIN user_products up1 ON up1.id = s1.user_product_id
JOIN user_products up2 ON up2.id = s2.user_product_id
JOIN products p1 ON p1.id = up1.product_id
JOIN products p2 ON p2.id = up2.product_id
JOIN product_ingredients pi1 ON pi1.product_id = p1.id
JOIN product_ingredients pi2 ON pi2.product_id = p2.id
JOIN ingredient_group_members m1 ON m1.ingredient_id = pi1.ingredient_id
JOIN ingredient_group_members m2 ON m2.ingredient_id = pi2.ingredient_id
JOIN conflict_rules cr
  ON cr.scope = 'same_routine'
 AND ((cr.group_a_id = m1.group_id AND cr.group_b_id = m2.group_id)
   OR (cr.group_a_id = m2.group_id AND cr.group_b_id = m1.group_id));

COMMIT;

-- =====================================================================
-- OPTIONAL SEED: a few ingredient groups and one example rule.
-- Replace the placeholder citation with a real source before relying on it.
-- =====================================================================
BEGIN;

INSERT INTO ingredient_groups (name, description) VALUES
  ('Retinoids',  'Vitamin A derivatives used for texture and fine lines'),
  ('AHAs',       'Alpha hydroxy acids, chemical exfoliants'),
  ('BHAs',       'Beta hydroxy acids, chemical exfoliants'),
  ('Vitamin C',  'Vitamin C forms used as antioxidants');

INSERT INTO ingredients (inci_name, common_name, function) VALUES
  ('Retinol',       'Retinol',        'Retinoid active'),
  ('Glycolic Acid', 'Glycolic acid',  'AHA exfoliant'),
  ('Salicylic Acid','Salicylic acid', 'BHA exfoliant'),
  ('Ascorbic Acid', 'Vitamin C',      'Antioxidant');

INSERT INTO ingredient_group_members (ingredient_id, group_id)
SELECT i.id, g.id
FROM (VALUES
  ('Retinol',        'Retinoids'),
  ('Glycolic Acid',  'AHAs'),
  ('Salicylic Acid', 'BHAs'),
  ('Ascorbic Acid',  'Vitamin C')
) AS v(ingredient, grp)
JOIN ingredients i       ON i.inci_name = v.ingredient
JOIN ingredient_groups g ON g.name = v.grp;

INSERT INTO conflict_rules (group_a_id, group_b_id, severity, scope, explanation, source_ref)
SELECT a.id, b.id,
       'caution'::conflict_severity,
       'same_routine'::conflict_scope,
       'Both can irritate the skin. Using them in the same routine raises the risk of dryness and redness.',
       '[ADD CITATION BEFORE USE]'
FROM ingredient_groups a
JOIN ingredient_groups b ON b.name IN ('AHAs', 'BHAs')
WHERE a.name = 'Retinoids';

COMMIT;
