--
-- PostgreSQL database dump
--

-- Dumped from database version 14.13
-- Dumped by pg_dump version 14.13

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: fn_auditoria_generica(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_auditoria_generica() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $_$
            DECLARE
                v_datos_antes JSONB := NULL;
                v_datos_despues JSONB := NULL;
                v_tabla_auditoria TEXT;
            BEGIN
                v_tabla_auditoria := TG_TABLE_NAME || '_auditoria';

                IF TG_OP = 'DELETE' THEN
                    v_datos_antes := to_jsonb(OLD);
                ELSIF TG_OP = 'UPDATE' THEN
                    v_datos_antes   := to_jsonb(OLD);
                    v_datos_despues := to_jsonb(NEW);
                ELSE
                    v_datos_despues := to_jsonb(NEW);
                END IF;

                EXECUTE format(
                    'INSERT INTO %I (operacion, registro_id, datos_antes, datos_despues, app_user_id, ip_address)
                     VALUES ($1, $2, $3, $4,
                             NULLIF(current_setting(''app.current_user_id'', true), '''')::BIGINT,
                             NULLIF(current_setting(''app.current_ip'', true), ''''))',
                    v_tabla_auditoria
                ) USING TG_OP,
                    CASE TG_OP WHEN 'DELETE' THEN OLD.id ELSE NEW.id END,
                    v_datos_antes,
                    v_datos_despues;

                RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
            END;
            $_$;


--
-- Name: fn_empresa_condicion_ventas_get(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_empresa_condicion_ventas_get(p_empresa_id integer) RETURNS TABLE(codigo character varying, activo boolean, es_default boolean)
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    ecv.codigo,
    ecv.activo,
    ecv.es_default
  FROM empresa_condicion_ventas ecv
  WHERE ecv.empresa_id = p_empresa_id
  ORDER BY ecv.codigo;
END;
$$;


--
-- Name: sp_bodega_create(bigint, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_create(p_empresa_id bigint, p_name character varying, p_description text DEFAULT NULL::text) RETURNS TABLE(id bigint, name character varying, is_default boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_is_default BOOLEAN;
                v_bodega_id  BIGINT;
                v_bodega_name VARCHAR;
            BEGIN
                -- Primera bodega → es la principal
                SELECT NOT EXISTS (
                    SELECT 1 FROM bodegas WHERE empresa_id = p_empresa_id AND deleted_at IS NULL
                ) INTO v_is_default;

                INSERT INTO bodegas (empresa_id, name, description, is_default)
                VALUES (p_empresa_id, p_name, p_description, v_is_default)
                RETURNING bodegas.id, bodegas.name INTO v_bodega_id, v_bodega_name;

                -- Heredar todos los productos existentes de la empresa con stock 0
                INSERT INTO bodega_productos (bodega_id, producto_id, stock, stock_min)
                SELECT v_bodega_id, p.id, 0, 0
                FROM productos p
                WHERE p.empresa_id = p_empresa_id AND p.deleted_at IS NULL
                ON CONFLICT (bodega_id, producto_id) DO NOTHING;

                RETURN QUERY SELECT v_bodega_id, v_bodega_name, v_is_default;
            END; $$;


--
-- Name: sp_bodega_create(bigint, character varying, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_create(p_empresa_id bigint, p_name character varying, p_description text DEFAULT NULL::text, p_permite_stock_negativo boolean DEFAULT false) RETURNS TABLE(id bigint, name character varying, is_default boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_is_default BOOLEAN;
    v_bodega_id  BIGINT;
    v_bodega_name VARCHAR;
BEGIN
    SELECT NOT EXISTS (
        SELECT 1 FROM bodegas WHERE empresa_id = p_empresa_id AND deleted_at IS NULL
    ) INTO v_is_default;

    INSERT INTO bodegas (empresa_id, name, description, is_default, permite_stock_negativo)
    VALUES (p_empresa_id, p_name, p_description, v_is_default, p_permite_stock_negativo)
    RETURNING bodegas.id, bodegas.name INTO v_bodega_id, v_bodega_name;

    INSERT INTO bodega_productos (bodega_id, producto_id, stock, stock_min)
    SELECT v_bodega_id, p.id, 0, 0
    FROM productos p
    WHERE p.empresa_id = p_empresa_id AND p.deleted_at IS NULL
    ON CONFLICT (bodega_id, producto_id) DO NOTHING;

    RETURN QUERY SELECT v_bodega_id, v_bodega_name, v_is_default;
END;
$$;


--
-- Name: sp_bodega_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_list(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, description text, is_default boolean, is_active boolean, total_productos bigint, permite_stock_negativo boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT b.id, b.empresa_id, b.name, b.description, b.is_default, b.is_active,
           COUNT(bp.id) FILTER (WHERE bp.is_active),
           b.permite_stock_negativo
    FROM bodegas b
    LEFT JOIN bodega_productos bp ON bp.bodega_id = b.id
    WHERE b.empresa_id = p_empresa_id AND b.deleted_at IS NULL
    GROUP BY b.id
    ORDER BY b.is_default DESC, b.name;
END;
$$;


--
-- Name: sp_bodega_producto_ajustar_stock(bigint, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_producto_ajustar_stock(p_bodega_id bigint, p_producto_id bigint, p_delta numeric) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_permite_negativo boolean;
BEGIN
    SELECT permite_stock_negativo INTO v_permite_negativo
    FROM bodegas WHERE id = p_bodega_id;

    UPDATE bodega_productos
       SET stock = CASE
                      WHEN v_permite_negativo THEN stock + p_delta
                      ELSE GREATEST(stock + p_delta, 0)
                  END,
           updated_at = NOW()
    WHERE bodega_id = p_bodega_id AND producto_id = p_producto_id;
END;
$$;


--
-- Name: sp_bodega_producto_stock(bigint, bigint, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_producto_stock(p_bodega_id bigint, p_producto_id bigint, p_stock numeric, p_stock_min numeric) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE bodega_productos SET stock=p_stock, stock_min=p_stock_min, updated_at=NOW()
                WHERE bodega_id=p_bodega_id AND producto_id=p_producto_id;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_bodega_producto_toggle(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_producto_toggle(p_bodega_id bigint, p_producto_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE bodega_productos SET is_active = NOT is_active, updated_at = NOW()
                WHERE bodega_id = p_bodega_id AND producto_id = p_producto_id;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_bodega_set_default(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_set_default(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE bodegas SET is_default=FALSE, updated_at=NOW()
                WHERE empresa_id=p_empresa_id AND is_default=TRUE;
                UPDATE bodegas SET is_default=TRUE, updated_at=NOW()
                WHERE id=p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_bodega_soft_delete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_soft_delete(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                -- No se puede eliminar la bodega principal
                IF EXISTS (SELECT 1 FROM bodegas WHERE id=p_id AND is_default=TRUE) THEN
                    RAISE EXCEPTION 'No se puede eliminar la bodega principal.';
                END IF;
                UPDATE bodegas SET is_active=FALSE, deleted_at=NOW(), updated_at=NOW()
                WHERE id=p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_bodega_update(bigint, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_update(p_id bigint, p_name character varying, p_description text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE bodegas SET name=p_name, description=p_description, updated_at=NOW()
                WHERE id=p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_bodega_update(bigint, character varying, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_update(p_id bigint, p_name character varying, p_description text DEFAULT NULL::text, p_permite_stock_negativo boolean DEFAULT false) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE v_rows INTEGER;
BEGIN
    UPDATE bodegas
       SET name = p_name, description = p_description,
           permite_stock_negativo = p_permite_stock_negativo,
           updated_at = NOW()
    WHERE id = p_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows > 0;
END;
$$;


--
-- Name: sp_categoria_create(bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_categoria_create(p_empresa_id bigint, p_name character varying) RETURNS TABLE(id bigint, name character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                INSERT INTO categorias_producto (empresa_id, name)
                VALUES (p_empresa_id, p_name)
                RETURNING categorias_producto.id, categorias_producto.name;
            END; $$;


--
-- Name: sp_categoria_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_categoria_list(p_empresa_id bigint) RETURNS TABLE(id bigint, name character varying, is_active boolean, total_productos bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT c.id, c.name, c.is_active,
                       COUNT(p.id) FILTER (WHERE p.deleted_at IS NULL)
                FROM categorias_producto c
                LEFT JOIN productos p ON p.categoria_id = c.id
                WHERE c.empresa_id = p_empresa_id AND c.deleted_at IS NULL
                GROUP BY c.id ORDER BY c.name;
            END; $$;


--
-- Name: sp_categoria_soft_delete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_categoria_soft_delete(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE categorias_producto SET is_active=FALSE, deleted_at=NOW(), updated_at=NOW()
                WHERE id=p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_categoria_update(bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_categoria_update(p_id bigint, p_name character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE categorias_producto SET name=p_name, updated_at=NOW()
                WHERE id=p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_client_create(bigint, character varying, character varying, character varying, character varying, character varying, character varying, text, text, date, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_create(p_empresa_id bigint, p_name character varying, p_legal_name character varying DEFAULT NULL::character varying, p_tax_id_type character varying DEFAULT NULL::character varying, p_tax_id character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_phone character varying DEFAULT NULL::character varying, p_address text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_birth_date date DEFAULT NULL::date, p_actividad_economica_codigo character varying DEFAULT NULL::character varying, p_actividad_economica_descripcion character varying DEFAULT NULL::character varying) RETURNS TABLE(id bigint, name character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  INSERT INTO clients(name, legal_name, tax_id_type, tax_id, email, phone,
                      address, notes, birth_date,
                      actividad_economica_codigo, actividad_economica_descripcion)
  VALUES (p_name, p_legal_name, p_tax_id_type, p_tax_id, p_email, p_phone,
          p_address, p_notes, p_birth_date,
          p_actividad_economica_codigo, p_actividad_economica_descripcion)
  RETURNING clients.id, clients.name;
END;
$$;


--
-- Name: sp_client_find(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_find(p_id bigint) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
  SELECT id, name, legal_name, tax_id_type, tax_id, email, phone, address, notes,
         birth_date, is_active, actividad_economica_codigo, actividad_economica_descripcion,
         created_at, updated_at
  FROM   clients WHERE id = p_id AND deleted_at IS NULL LIMIT 1;
$$;


--
-- Name: sp_client_find_by_tax_id(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_find_by_tax_id(p_tax_id character varying) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
  SELECT id, name, legal_name, tax_id_type, tax_id, email, phone, address, notes,
         birth_date, is_active, actividad_economica_codigo, actividad_economica_descripcion,
         created_at, updated_at
  FROM   clients WHERE tax_id = p_tax_id AND deleted_at IS NULL LIMIT 1;
$$;


--
-- Name: sp_client_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_list(p_empresa_id bigint) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
  SELECT id, name, legal_name, tax_id_type, tax_id, email, phone, address, notes,
         birth_date, is_active, actividad_economica_codigo, actividad_economica_descripcion,
         created_at, updated_at
  FROM   clients WHERE deleted_at IS NULL ORDER BY name;
$$;


--
-- Name: sp_client_search(bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_search(p_empresa_id bigint, p_query character varying) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
  SELECT id, name, legal_name, tax_id_type, tax_id, email, phone, address, notes,
         birth_date, is_active, actividad_economica_codigo, actividad_economica_descripcion,
         created_at, updated_at
  FROM   clients WHERE deleted_at IS NULL
    AND  (name ILIKE '%'||p_query||'%' OR tax_id ILIKE '%'||p_query||'%'
          OR legal_name ILIKE '%'||p_query||'%')
  ORDER BY name LIMIT 50;
$$;


--
-- Name: sp_client_soft_delete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_soft_delete(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE v_rows INTEGER;
BEGIN
    UPDATE clients SET is_active=FALSE, deleted_at=NOW(), updated_at=NOW()
    WHERE id=p_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
END;
$$;


--
-- Name: sp_client_toggle_status(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_toggle_status(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE v_rows INTEGER;
BEGIN
    UPDATE clients SET is_active=NOT is_active, updated_at=NOW()
    WHERE id=p_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
END;
$$;


--
-- Name: sp_client_update(bigint, character varying, character varying, character varying, character varying, character varying, character varying, text, text, date, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_update(p_id bigint, p_name character varying, p_legal_name character varying DEFAULT NULL::character varying, p_tax_id_type character varying DEFAULT NULL::character varying, p_tax_id character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_phone character varying DEFAULT NULL::character varying, p_address text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_birth_date date DEFAULT NULL::date, p_actividad_economica_codigo character varying DEFAULT NULL::character varying, p_actividad_economica_descripcion character varying DEFAULT NULL::character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE v_rows int;
BEGIN
  UPDATE clients SET
    name                            = p_name,
    legal_name                      = p_legal_name,
    tax_id_type                     = p_tax_id_type,
    tax_id                          = p_tax_id,
    email                           = p_email,
    phone                           = p_phone,
    address                         = p_address,
    notes                           = p_notes,
    birth_date                      = p_birth_date,
    actividad_economica_codigo      = p_actividad_economica_codigo,
    actividad_economica_descripcion = p_actividad_economica_descripcion,
    updated_at                      = NOW()
  WHERE id = p_id AND deleted_at IS NULL;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: company_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_settings (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    legal_name character varying(255) NOT NULL,
    commercial_name character varying(255),
    tax_id character varying(20) NOT NULL,
    tax_id_type character varying(2) DEFAULT '02'::character varying NOT NULL,
    province_code character varying(1),
    canton_code character varying(2),
    district_code character varying(2),
    other_signs text,
    phone character varying(30),
    email character varying(255),
    hacienda_environment character varying(10) DEFAULT 'stag'::character varying NOT NULL,
    hacienda_username_encrypted text,
    hacienda_password_encrypted text,
    certificate_p12_encrypted text,
    certificate_password_encrypted text,
    certificate_subject text,
    certificate_issuer text,
    certificate_serial character varying(255),
    certificate_valid_from timestamp without time zone,
    certificate_valid_to timestamp without time zone,
    certificate_tax_id character varying(20),
    certificate_validated_at timestamp without time zone,
    hacienda_token_tested_at timestamp without time zone,
    hacienda_token_expires_at timestamp without time zone,
    validation_status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    validation_errors jsonb DEFAULT '[]'::jsonb NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    actividad_economica character varying(10),
    leyenda_tributaria text,
    logo_url text,
    logo_public_id text,
    CONSTRAINT company_settings_hacienda_environment_check CHECK (((hacienda_environment)::text = ANY ((ARRAY['stag'::character varying, 'prod'::character varying])::text[]))),
    CONSTRAINT company_settings_validation_status_check CHECK (((validation_status)::text = ANY ((ARRAY['pending'::character varying, 'valid'::character varying, 'invalid'::character varying])::text[])))
);


--
-- Name: sp_company_settings_get(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_company_settings_get(p_empresa_id bigint) RETURNS SETOF public.company_settings
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY SELECT * FROM company_settings WHERE empresa_id = p_empresa_id AND deleted_at IS NULL LIMIT 1;
END; $$;


--
-- Name: sp_company_settings_save(bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, text, character varying, character varying, character varying, text, text, text, text, text, text, character varying, timestamp without time zone, timestamp without time zone, character varying, timestamp without time zone, timestamp without time zone, timestamp without time zone, character varying, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_company_settings_save(p_empresa_id bigint, p_legal_name character varying, p_commercial_name character varying, p_tax_id character varying, p_tax_id_type character varying, p_province_code character varying, p_canton_code character varying, p_district_code character varying, p_other_signs text, p_phone character varying, p_email character varying, p_hacienda_environment character varying, p_hacienda_username_encrypted text, p_hacienda_password_encrypted text, p_certificate_p12_encrypted text, p_certificate_password_encrypted text, p_certificate_subject text, p_certificate_issuer text, p_certificate_serial character varying, p_certificate_valid_from timestamp without time zone, p_certificate_valid_to timestamp without time zone, p_certificate_tax_id character varying, p_certificate_validated_at timestamp without time zone, p_hacienda_token_tested_at timestamp without time zone, p_hacienda_token_expires_at timestamp without time zone, p_validation_status character varying, p_validation_errors jsonb) RETURNS TABLE(id bigint, validation_status character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                INSERT INTO company_settings (
                    empresa_id, legal_name, commercial_name, tax_id, tax_id_type,
                    province_code, canton_code, district_code, other_signs, phone, email,
                    hacienda_environment, hacienda_username_encrypted, hacienda_password_encrypted,
                    certificate_p12_encrypted, certificate_password_encrypted,
                    certificate_subject, certificate_issuer, certificate_serial,
                    certificate_valid_from, certificate_valid_to, certificate_tax_id,
                    certificate_validated_at, hacienda_token_tested_at, hacienda_token_expires_at,
                    validation_status, validation_errors
                )
                VALUES (
                    p_empresa_id, p_legal_name, p_commercial_name, p_tax_id, p_tax_id_type,
                    p_province_code, p_canton_code, p_district_code, p_other_signs, p_phone, p_email,
                    p_hacienda_environment, p_hacienda_username_encrypted, p_hacienda_password_encrypted,
                    p_certificate_p12_encrypted, p_certificate_password_encrypted,
                    p_certificate_subject, p_certificate_issuer, p_certificate_serial,
                    p_certificate_valid_from, p_certificate_valid_to, p_certificate_tax_id,
                    p_certificate_validated_at, p_hacienda_token_tested_at, p_hacienda_token_expires_at,
                    p_validation_status, COALESCE(p_validation_errors, '[]'::jsonb)
                )
                ON CONFLICT (empresa_id) DO UPDATE SET
                    legal_name = EXCLUDED.legal_name,
                    commercial_name = EXCLUDED.commercial_name,
                    tax_id = EXCLUDED.tax_id,
                    tax_id_type = EXCLUDED.tax_id_type,
                    province_code = EXCLUDED.province_code,
                    canton_code = EXCLUDED.canton_code,
                    district_code = EXCLUDED.district_code,
                    other_signs = EXCLUDED.other_signs,
                    phone = EXCLUDED.phone,
                    email = EXCLUDED.email,
                    hacienda_environment = EXCLUDED.hacienda_environment,
                    hacienda_username_encrypted = COALESCE(EXCLUDED.hacienda_username_encrypted, company_settings.hacienda_username_encrypted),
                    hacienda_password_encrypted = COALESCE(EXCLUDED.hacienda_password_encrypted, company_settings.hacienda_password_encrypted),
                    certificate_p12_encrypted = COALESCE(EXCLUDED.certificate_p12_encrypted, company_settings.certificate_p12_encrypted),
                    certificate_password_encrypted = COALESCE(EXCLUDED.certificate_password_encrypted, company_settings.certificate_password_encrypted),
                    certificate_subject = COALESCE(EXCLUDED.certificate_subject, company_settings.certificate_subject),
                    certificate_issuer = COALESCE(EXCLUDED.certificate_issuer, company_settings.certificate_issuer),
                    certificate_serial = COALESCE(EXCLUDED.certificate_serial, company_settings.certificate_serial),
                    certificate_valid_from = COALESCE(EXCLUDED.certificate_valid_from, company_settings.certificate_valid_from),
                    certificate_valid_to = COALESCE(EXCLUDED.certificate_valid_to, company_settings.certificate_valid_to),
                    certificate_tax_id = COALESCE(EXCLUDED.certificate_tax_id, company_settings.certificate_tax_id),
                    certificate_validated_at = COALESCE(EXCLUDED.certificate_validated_at, company_settings.certificate_validated_at),
                    hacienda_token_tested_at = COALESCE(EXCLUDED.hacienda_token_tested_at, company_settings.hacienda_token_tested_at),
                    hacienda_token_expires_at = COALESCE(EXCLUDED.hacienda_token_expires_at, company_settings.hacienda_token_expires_at),
                    validation_status = EXCLUDED.validation_status,
                    validation_errors = COALESCE(EXCLUDED.validation_errors, '[]'::jsonb),
                    is_active = TRUE,
                    deleted_at = NULL,
                    updated_at = NOW()
                RETURNING company_settings.id, company_settings.validation_status;
            END; $$;


--
-- Name: sp_company_settings_save(bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, text, character varying, character varying, character varying, text, character varying, text, text, text, text, text, text, character varying, timestamp without time zone, timestamp without time zone, character varying, timestamp without time zone, timestamp without time zone, timestamp without time zone, character varying, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_company_settings_save(p_empresa_id bigint, p_legal_name character varying, p_commercial_name character varying, p_tax_id character varying, p_tax_id_type character varying, p_province_code character varying, p_canton_code character varying, p_district_code character varying, p_other_signs text, p_phone character varying, p_email character varying, p_actividad_economica character varying, p_leyenda_tributaria text, p_hacienda_environment character varying, p_hacienda_username_encrypted text, p_hacienda_password_encrypted text, p_certificate_p12_encrypted text, p_certificate_password_encrypted text, p_certificate_subject text, p_certificate_issuer text, p_certificate_serial character varying, p_certificate_valid_from timestamp without time zone, p_certificate_valid_to timestamp without time zone, p_certificate_tax_id character varying, p_certificate_validated_at timestamp without time zone, p_hacienda_token_tested_at timestamp without time zone, p_hacienda_token_expires_at timestamp without time zone, p_validation_status character varying, p_validation_errors jsonb) RETURNS TABLE(id bigint, validation_status character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                INSERT INTO company_settings (
                    empresa_id, legal_name, commercial_name, tax_id, tax_id_type,
                    province_code, canton_code, district_code, other_signs, phone, email,
                    actividad_economica, leyenda_tributaria,
                    hacienda_environment, hacienda_username_encrypted, hacienda_password_encrypted,
                    certificate_p12_encrypted, certificate_password_encrypted,
                    certificate_subject, certificate_issuer, certificate_serial,
                    certificate_valid_from, certificate_valid_to, certificate_tax_id,
                    certificate_validated_at, hacienda_token_tested_at, hacienda_token_expires_at,
                    validation_status, validation_errors
                )
                VALUES (
                    p_empresa_id, p_legal_name, p_commercial_name, p_tax_id, p_tax_id_type,
                    p_province_code, p_canton_code, p_district_code, p_other_signs, p_phone, p_email,
                    p_actividad_economica, p_leyenda_tributaria,
                    p_hacienda_environment, p_hacienda_username_encrypted, p_hacienda_password_encrypted,
                    p_certificate_p12_encrypted, p_certificate_password_encrypted,
                    p_certificate_subject, p_certificate_issuer, p_certificate_serial,
                    p_certificate_valid_from, p_certificate_valid_to, p_certificate_tax_id,
                    p_certificate_validated_at, p_hacienda_token_tested_at, p_hacienda_token_expires_at,
                    p_validation_status, COALESCE(p_validation_errors, '[]'::jsonb)
                )
                ON CONFLICT (empresa_id) DO UPDATE SET
                    legal_name                      = EXCLUDED.legal_name,
                    commercial_name                 = EXCLUDED.commercial_name,
                    tax_id                          = EXCLUDED.tax_id,
                    tax_id_type                     = EXCLUDED.tax_id_type,
                    province_code                   = EXCLUDED.province_code,
                    canton_code                     = EXCLUDED.canton_code,
                    district_code                   = EXCLUDED.district_code,
                    other_signs                     = EXCLUDED.other_signs,
                    phone                           = EXCLUDED.phone,
                    email                           = EXCLUDED.email,
                    actividad_economica             = EXCLUDED.actividad_economica,
                    leyenda_tributaria              = EXCLUDED.leyenda_tributaria,
                    hacienda_environment            = EXCLUDED.hacienda_environment,
                    hacienda_username_encrypted     = COALESCE(EXCLUDED.hacienda_username_encrypted, company_settings.hacienda_username_encrypted),
                    hacienda_password_encrypted     = COALESCE(EXCLUDED.hacienda_password_encrypted, company_settings.hacienda_password_encrypted),
                    certificate_p12_encrypted       = COALESCE(EXCLUDED.certificate_p12_encrypted, company_settings.certificate_p12_encrypted),
                    certificate_password_encrypted  = COALESCE(EXCLUDED.certificate_password_encrypted, company_settings.certificate_password_encrypted),
                    certificate_subject             = COALESCE(EXCLUDED.certificate_subject, company_settings.certificate_subject),
                    certificate_issuer              = COALESCE(EXCLUDED.certificate_issuer, company_settings.certificate_issuer),
                    certificate_serial              = COALESCE(EXCLUDED.certificate_serial, company_settings.certificate_serial),
                    certificate_valid_from          = COALESCE(EXCLUDED.certificate_valid_from, company_settings.certificate_valid_from),
                    certificate_valid_to            = COALESCE(EXCLUDED.certificate_valid_to, company_settings.certificate_valid_to),
                    certificate_tax_id              = COALESCE(EXCLUDED.certificate_tax_id, company_settings.certificate_tax_id),
                    certificate_validated_at        = COALESCE(EXCLUDED.certificate_validated_at, company_settings.certificate_validated_at),
                    hacienda_token_tested_at        = COALESCE(EXCLUDED.hacienda_token_tested_at, company_settings.hacienda_token_tested_at),
                    hacienda_token_expires_at       = COALESCE(EXCLUDED.hacienda_token_expires_at, company_settings.hacienda_token_expires_at),
                    validation_status               = EXCLUDED.validation_status,
                    validation_errors               = COALESCE(EXCLUDED.validation_errors, '[]'::jsonb),
                    is_active                       = TRUE,
                    deleted_at                      = NULL,
                    updated_at                      = NOW()
                RETURNING company_settings.id, company_settings.validation_status;
            END; $$;


--
-- Name: sp_company_settings_save(bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, text, character varying, character varying, character varying, text, character varying, text, text, text, text, text, text, character varying, timestamp without time zone, timestamp without time zone, character varying, timestamp without time zone, timestamp without time zone, timestamp without time zone, character varying, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_company_settings_save(p_empresa_id bigint, p_legal_name character varying, p_commercial_name character varying, p_tax_id character varying, p_tax_id_type character varying, p_province_code character varying, p_canton_code character varying, p_district_code character varying, p_other_signs text, p_phone character varying, p_email character varying, p_actividad_economica character varying, p_leyenda_tributaria text, p_hacienda_environment character varying, p_hacienda_username_encrypted text, p_hacienda_password_encrypted text, p_certificate_p12_encrypted text, p_certificate_password_encrypted text, p_certificate_subject text, p_certificate_issuer text, p_certificate_serial character varying, p_certificate_valid_from timestamp without time zone, p_certificate_valid_to timestamp without time zone, p_certificate_tax_id character varying, p_certificate_validated_at timestamp without time zone, p_hacienda_token_tested_at timestamp without time zone, p_hacienda_token_expires_at timestamp without time zone, p_validation_status character varying, p_validation_errors jsonb, p_logo_url text DEFAULT NULL::text, p_logo_public_id text DEFAULT NULL::text) RETURNS TABLE(id bigint, validation_status character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  INSERT INTO company_settings (
    empresa_id, legal_name, commercial_name, tax_id, tax_id_type,
    province_code, canton_code, district_code, other_signs, phone, email,
    actividad_economica, leyenda_tributaria,
    hacienda_environment, hacienda_username_encrypted, hacienda_password_encrypted,
    certificate_p12_encrypted, certificate_password_encrypted,
    certificate_subject, certificate_issuer, certificate_serial,
    certificate_valid_from, certificate_valid_to, certificate_tax_id,
    certificate_validated_at, hacienda_token_tested_at, hacienda_token_expires_at,
    validation_status, validation_errors, logo_url, logo_public_id
  )
  VALUES (
    p_empresa_id, p_legal_name, p_commercial_name, p_tax_id, p_tax_id_type,
    p_province_code, p_canton_code, p_district_code, p_other_signs, p_phone, p_email,
    p_actividad_economica, p_leyenda_tributaria,
    p_hacienda_environment, p_hacienda_username_encrypted, p_hacienda_password_encrypted,
    p_certificate_p12_encrypted, p_certificate_password_encrypted,
    p_certificate_subject, p_certificate_issuer, p_certificate_serial,
    p_certificate_valid_from, p_certificate_valid_to, p_certificate_tax_id,
    p_certificate_validated_at, p_hacienda_token_tested_at, p_hacienda_token_expires_at,
    p_validation_status, COALESCE(p_validation_errors, '[]'::jsonb),
    p_logo_url, p_logo_public_id
  )
  ON CONFLICT (empresa_id) DO UPDATE SET
    legal_name                      = EXCLUDED.legal_name,
    commercial_name                 = EXCLUDED.commercial_name,
    tax_id                          = EXCLUDED.tax_id,
    tax_id_type                     = EXCLUDED.tax_id_type,
    province_code                   = EXCLUDED.province_code,
    canton_code                     = EXCLUDED.canton_code,
    district_code                   = EXCLUDED.district_code,
    other_signs                     = EXCLUDED.other_signs,
    phone                           = EXCLUDED.phone,
    email                           = EXCLUDED.email,
    actividad_economica             = EXCLUDED.actividad_economica,
    leyenda_tributaria              = EXCLUDED.leyenda_tributaria,
    hacienda_environment            = EXCLUDED.hacienda_environment,
    hacienda_username_encrypted     = COALESCE(EXCLUDED.hacienda_username_encrypted, company_settings.hacienda_username_encrypted),
    hacienda_password_encrypted     = COALESCE(EXCLUDED.hacienda_password_encrypted, company_settings.hacienda_password_encrypted),
    certificate_p12_encrypted       = COALESCE(EXCLUDED.certificate_p12_encrypted, company_settings.certificate_p12_encrypted),
    certificate_password_encrypted  = COALESCE(EXCLUDED.certificate_password_encrypted, company_settings.certificate_password_encrypted),
    certificate_subject             = COALESCE(EXCLUDED.certificate_subject, company_settings.certificate_subject),
    certificate_issuer              = COALESCE(EXCLUDED.certificate_issuer, company_settings.certificate_issuer),
    certificate_serial              = COALESCE(EXCLUDED.certificate_serial, company_settings.certificate_serial),
    certificate_valid_from          = COALESCE(EXCLUDED.certificate_valid_from, company_settings.certificate_valid_from),
    certificate_valid_to            = COALESCE(EXCLUDED.certificate_valid_to, company_settings.certificate_valid_to),
    certificate_tax_id              = COALESCE(EXCLUDED.certificate_tax_id, company_settings.certificate_tax_id),
    certificate_validated_at        = COALESCE(EXCLUDED.certificate_validated_at, company_settings.certificate_validated_at),
    hacienda_token_tested_at        = COALESCE(EXCLUDED.hacienda_token_tested_at, company_settings.hacienda_token_tested_at),
    hacienda_token_expires_at       = COALESCE(EXCLUDED.hacienda_token_expires_at, company_settings.hacienda_token_expires_at),
    validation_status               = EXCLUDED.validation_status,
    validation_errors               = COALESCE(EXCLUDED.validation_errors, '[]'::jsonb),
    logo_url                        = COALESCE(EXCLUDED.logo_url, company_settings.logo_url),
    logo_public_id                  = COALESCE(EXCLUDED.logo_public_id, company_settings.logo_public_id),
    is_active                       = TRUE,
    deleted_at                      = NULL,
    updated_at                      = NOW()
  RETURNING company_settings.id, company_settings.validation_status;
END; $$;


--
-- Name: sp_company_settings_sensitive_get(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_company_settings_sensitive_get(p_empresa_id bigint) RETURNS TABLE(hacienda_environment character varying, hacienda_username_encrypted text, hacienda_password_encrypted text, certificate_p12_encrypted text, certificate_password_encrypted text, validation_status character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
    BEGIN
        RETURN QUERY
        SELECT cs.hacienda_environment,
               cs.hacienda_username_encrypted,
               cs.hacienda_password_encrypted,
               cs.certificate_p12_encrypted,
               cs.certificate_password_encrypted,
               cs.validation_status
        FROM company_settings cs
        WHERE cs.empresa_id = p_empresa_id AND cs.deleted_at IS NULL
        LIMIT 1;
    END;
    $$;


--
-- Name: sp_compras_item_create(bigint, character varying, character varying, character varying, character varying, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_compras_item_create(p_empresa_id bigint, p_tipo character varying, p_descripcion character varying, p_cabys_codigo character varying DEFAULT NULL::character varying, p_unidad_medida character varying DEFAULT 'Unid'::character varying, p_precio_default numeric DEFAULT 0) RETURNS bigint
    LANGUAGE sql
    AS $$
  INSERT INTO compras_items(empresa_id, tipo, descripcion, cabys_codigo, unidad_medida, precio_default)
  VALUES (p_empresa_id, p_tipo, p_descripcion, p_cabys_codigo, p_unidad_medida, p_precio_default)
  RETURNING id;
$$;


--
-- Name: sp_compras_item_list(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_compras_item_list(p_empresa_id bigint, p_search text DEFAULT NULL::text) RETURNS TABLE(id bigint, empresa_id bigint, tipo character varying, descripcion character varying, cabys_codigo character varying, unidad_medida character varying, precio_default numeric, is_active boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE sql
    AS $$
  SELECT id, empresa_id, tipo, descripcion, cabys_codigo, unidad_medida,
         precio_default, is_active, created_at, updated_at
  FROM   compras_items
  WHERE  empresa_id = p_empresa_id AND deleted_at IS NULL
    AND  (p_search IS NULL
          OR descripcion ILIKE '%'||p_search||'%'
          OR cabys_codigo ILIKE '%'||p_search||'%')
  ORDER BY tipo, descripcion;
$$;


--
-- Name: sp_compras_item_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_compras_item_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE compras_items SET deleted_at=NOW(), updated_at=NOW()
  WHERE  id=p_id AND empresa_id=p_empresa_id AND deleted_at IS NULL;
  RETURN FOUND;
END;
$$;


--
-- Name: sp_compras_item_toggle(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_compras_item_toggle(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE compras_items SET is_active = NOT is_active, updated_at=NOW()
  WHERE  id=p_id AND empresa_id=p_empresa_id AND deleted_at IS NULL;
  RETURN FOUND;
END;
$$;


--
-- Name: sp_compras_item_update(bigint, bigint, character varying, character varying, character varying, character varying, numeric, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_compras_item_update(p_id bigint, p_empresa_id bigint, p_tipo character varying, p_descripcion character varying, p_cabys_codigo character varying DEFAULT NULL::character varying, p_unidad_medida character varying DEFAULT 'Unid'::character varying, p_precio_default numeric DEFAULT 0, p_is_active boolean DEFAULT true) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE compras_items
  SET    tipo=p_tipo, descripcion=p_descripcion, cabys_codigo=p_cabys_codigo,
         unidad_medida=p_unidad_medida, precio_default=p_precio_default,
         is_active=p_is_active, updated_at=NOW()
  WHERE  id=p_id AND empresa_id=p_empresa_id AND deleted_at IS NULL;
  RETURN FOUND;
END;
$$;


--
-- Name: sp_consecutivo_next(bigint, bigint, character varying, character varying, character varying, smallint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_consecutivo_next(p_empresa_id bigint, p_sucursal_id bigint, p_sucursal_codigo character varying, p_terminal character varying, p_tipo_documento character varying, p_situacion smallint DEFAULT 1) RETURNS TABLE(consecutivo bigint, numero_consecutivo character varying)
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_next       BIGINT;
                v_num_consec VARCHAR(20);
            BEGIN
                INSERT INTO documento_consecutivos
                    (empresa_id, sucursal_id, terminal, tipo_documento, ultimo_consecutivo)
                VALUES
                    (p_empresa_id, p_sucursal_id, LPAD(p_terminal, 5, '0'), p_tipo_documento, 1)
                ON CONFLICT (empresa_id, sucursal_id, terminal, tipo_documento)
                DO UPDATE SET
                    ultimo_consecutivo = documento_consecutivos.ultimo_consecutivo + 1,
                    updated_at         = NOW()
                RETURNING ultimo_consecutivo INTO v_next;

                -- Formato FE 4.4: SUCURSAL(3) + TERMINAL(5) + TIPO(2) + CONSECUTIVO(10) = 20 chars
                v_num_consec := LPAD(p_sucursal_codigo, 3, '0')
                             || LPAD(p_terminal,        5, '0')
                             || p_tipo_documento
                             || LPAD(v_next::VARCHAR,  10, '0');

                RETURN QUERY SELECT v_next, v_num_consec;
            END;
            $$;


--
-- Name: sp_documento_ajustar_inventario(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_ajustar_inventario(p_documento_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_tipo   varchar(2);
    v_factor numeric;
    r        record;
BEGIN
    SELECT tipo_documento INTO v_tipo
      FROM documentos_electronicos WHERE id = p_documento_id;

    IF v_tipo IN ('01','04') THEN
        v_factor := -1;
    ELSIF v_tipo = '03' THEN
        v_factor := 1;
    ELSE
        RETURN;
    END IF;

    FOR r IN
        SELECT dl.bodega_id, dl.producto_id, dl.cantidad
          FROM documento_lineas dl
          JOIN productos p ON p.id = dl.producto_id
         WHERE dl.documento_id = p_documento_id
           AND dl.bodega_id IS NOT NULL
           AND dl.producto_id IS NOT NULL
           AND p.type = 'product'
    LOOP
        PERFORM sp_bodega_producto_ajustar_stock(r.bodega_id, r.producto_id, v_factor * r.cantidad);
    END LOOP;
END;
$$;


--
-- Name: sp_documento_asignar_clave(bigint, bigint, character varying, character varying, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_asignar_clave(p_id bigint, p_empresa_id bigint, p_clave character varying, p_numero_consecutivo character varying, p_consecutivo_comercio bigint, p_numero_seguridad character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE documentos_electronicos SET
                    clave                   = p_clave,
                    numero_consecutivo      = p_numero_consecutivo,
                    consecutivo_comercio    = p_consecutivo_comercio,
                    numero_seguridad        = p_numero_seguridad,
                    estado                  = 'procesando',
                    updated_at              = NOW()
                WHERE id = p_id
                  AND empresa_id = p_empresa_id
                  AND estado = 'borrador'
                  AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: documentos_electronicos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documentos_electronicos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    sucursal_id bigint NOT NULL,
    caja_id bigint,
    user_id bigint NOT NULL,
    tipo_documento character varying(2) NOT NULL,
    clave character varying(50),
    numero_consecutivo character varying(20),
    sucursal_codigo character varying(3),
    terminal character varying(5),
    consecutivo_comercio bigint,
    situacion_comprobante smallint DEFAULT 1 NOT NULL,
    fecha_emision timestamp without time zone,
    version character varying(5) DEFAULT '4.4'::character varying NOT NULL,
    condicion_venta character varying(2),
    condicion_venta_otros text,
    plazo_credito character varying(10),
    codigo_actividad_emisor character varying(10),
    codigo_actividad_receptor character varying(10),
    leyenda_tributaria text,
    proveedor_sistemas character varying(20),
    numero_seguridad character varying(8),
    emisor_nombre character varying(255),
    emisor_tipo_id character varying(2),
    emisor_numero_id character varying(20),
    emisor_nombre_comercial character varying(255),
    emisor_registro_fiscal character varying(20),
    emisor_provincia character varying(1),
    emisor_canton character varying(2),
    emisor_distrito character varying(2),
    emisor_barrio character varying(2),
    emisor_otras_senas text,
    emisor_codigo_pais character varying(3),
    emisor_telefono character varying(30),
    emisor_correos jsonb,
    receptor_cliente_id bigint,
    receptor_nombre character varying(255),
    receptor_tipo_id character varying(2),
    receptor_numero_id character varying(20),
    receptor_nombre_comercial character varying(255),
    receptor_provincia character varying(1),
    receptor_canton character varying(2),
    receptor_distrito character varying(2),
    receptor_barrio character varying(2),
    receptor_otras_senas text,
    receptor_codigo_pais character varying(3),
    receptor_telefono character varying(30),
    receptor_correo character varying(255),
    moneda character varying(3) DEFAULT 'CRC'::character varying NOT NULL,
    tipo_cambio numeric(18,5) DEFAULT 1 NOT NULL,
    total_serv_gravados numeric(18,5) DEFAULT 0 NOT NULL,
    total_serv_exentos numeric(18,5) DEFAULT 0 NOT NULL,
    total_serv_exonerado numeric(18,5) DEFAULT 0 NOT NULL,
    total_serv_no_sujeto numeric(18,5) DEFAULT 0 NOT NULL,
    total_merc_gravadas numeric(18,5) DEFAULT 0 NOT NULL,
    total_merc_exentas numeric(18,5) DEFAULT 0 NOT NULL,
    total_merc_exonerada numeric(18,5) DEFAULT 0 NOT NULL,
    total_merc_no_sujeta numeric(18,5) DEFAULT 0 NOT NULL,
    total_gravado numeric(18,5) DEFAULT 0 NOT NULL,
    total_exento numeric(18,5) DEFAULT 0 NOT NULL,
    total_exonerado numeric(18,5) DEFAULT 0 NOT NULL,
    total_no_sujeto numeric(18,5) DEFAULT 0 NOT NULL,
    total_venta numeric(18,5) DEFAULT 0 NOT NULL,
    total_descuentos numeric(18,5) DEFAULT 0 NOT NULL,
    total_venta_neta numeric(18,5) DEFAULT 0 NOT NULL,
    total_impuesto numeric(18,5) DEFAULT 0 NOT NULL,
    total_imp_asumido_emisor numeric(18,5) DEFAULT 0 NOT NULL,
    total_iva_devuelto numeric(18,5) DEFAULT 0 NOT NULL,
    total_otros_cargos numeric(18,5) DEFAULT 0 NOT NULL,
    total_comprobante numeric(18,5) DEFAULT 0 NOT NULL,
    otros_texto text,
    otros_contenido text,
    estado character varying(20) DEFAULT 'borrador'::character varying NOT NULL,
    xml_firmado text,
    xml_respuesta text,
    qr_url text,
    hacienda_mensaje text,
    hacienda_detalle_mensaje text,
    hacienda_attempts smallint DEFAULT 0 NOT NULL,
    hacienda_last_attempt_at timestamp without time zone,
    enviado_at timestamp without time zone,
    aceptado_at timestamp without time zone,
    rechazado_at timestamp without time zone,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    funcionario_id bigint,
    hacienda_poll_attempts integer DEFAULT 0 NOT NULL,
    CONSTRAINT chk_doc_estado CHECK (((estado)::text = ANY (ARRAY['borrador'::text, 'procesando'::text, 'aceptado'::text, 'rechazado'::text, 'error'::text, 'pendiente_manual'::text]))),
    CONSTRAINT documentos_electronicos_estado_check CHECK (((estado)::text = ANY ((ARRAY['borrador'::character varying, 'procesando'::character varying, 'aceptado'::character varying, 'rechazado'::character varying, 'anulado'::character varying, 'error'::character varying, 'pendiente_manual'::character varying])::text[])))
);


--
-- Name: sp_documento_buscar_por_termino(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_buscar_por_termino(p_empresa_id bigint, p_termino text) RETURNS SETOF public.documentos_electronicos
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT * FROM documentos_electronicos
  WHERE empresa_id = p_empresa_id
    AND (clave = p_termino OR numero_consecutivo = p_termino)
    AND estado = 'aceptado'
    AND tipo_documento IN ('01','04')
    AND deleted_at IS NULL
  LIMIT 1;
END;
$$;


--
-- Name: sp_documento_create(bigint, bigint, bigint, bigint, character varying, timestamp without time zone, character varying, text, character varying, character varying, character varying, text, character varying, smallint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, text, character varying, character varying, jsonb, bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, text, character varying, character varying, character varying, character varying, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text, text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_create(p_empresa_id bigint, p_sucursal_id bigint, p_caja_id bigint, p_user_id bigint, p_tipo_documento character varying, p_fecha_emision timestamp without time zone, p_condicion_venta character varying, p_condicion_venta_otros text, p_plazo_credito character varying, p_codigo_actividad_emisor character varying, p_codigo_actividad_receptor character varying, p_leyenda_tributaria text, p_proveedor_sistemas character varying, p_situacion_comprobante smallint, p_sucursal_codigo character varying, p_terminal character varying, p_emisor_nombre character varying, p_emisor_tipo_id character varying, p_emisor_numero_id character varying, p_emisor_nombre_comercial character varying, p_emisor_registro_fiscal character varying, p_emisor_provincia character varying, p_emisor_canton character varying, p_emisor_distrito character varying, p_emisor_barrio character varying, p_emisor_otras_senas text, p_emisor_codigo_pais character varying, p_emisor_telefono character varying, p_emisor_correos jsonb, p_receptor_cliente_id bigint, p_receptor_nombre character varying, p_receptor_tipo_id character varying, p_receptor_numero_id character varying, p_receptor_nombre_comercial character varying, p_receptor_provincia character varying, p_receptor_canton character varying, p_receptor_distrito character varying, p_receptor_barrio character varying, p_receptor_otras_senas text, p_receptor_codigo_pais character varying, p_receptor_telefono character varying, p_receptor_correo character varying, p_moneda character varying, p_tipo_cambio numeric, p_total_serv_gravados numeric DEFAULT 0, p_total_serv_exentos numeric DEFAULT 0, p_total_serv_exonerado numeric DEFAULT 0, p_total_serv_no_sujeto numeric DEFAULT 0, p_total_merc_gravadas numeric DEFAULT 0, p_total_merc_exentas numeric DEFAULT 0, p_total_merc_exonerada numeric DEFAULT 0, p_total_merc_no_sujeta numeric DEFAULT 0, p_total_gravado numeric DEFAULT 0, p_total_exento numeric DEFAULT 0, p_total_exonerado numeric DEFAULT 0, p_total_no_sujeto numeric DEFAULT 0, p_total_venta numeric DEFAULT 0, p_total_descuentos numeric DEFAULT 0, p_total_venta_neta numeric DEFAULT 0, p_total_impuesto numeric DEFAULT 0, p_total_imp_asumido_emisor numeric DEFAULT 0, p_total_iva_devuelto numeric DEFAULT 0, p_total_otros_cargos numeric DEFAULT 0, p_total_comprobante numeric DEFAULT 0, p_otros_texto text DEFAULT NULL::text, p_otros_contenido text DEFAULT NULL::text, p_funcionario_id bigint DEFAULT NULL::bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO documentos_electronicos (
                    empresa_id, sucursal_id, caja_id, user_id,
                    tipo_documento, fecha_emision,
                    condicion_venta, condicion_venta_otros, plazo_credito,
                    codigo_actividad_emisor, codigo_actividad_receptor,
                    leyenda_tributaria, proveedor_sistemas, situacion_comprobante,
                    sucursal_codigo, terminal,
                    emisor_nombre, emisor_tipo_id, emisor_numero_id,
                    emisor_nombre_comercial, emisor_registro_fiscal,
                    emisor_provincia, emisor_canton, emisor_distrito,
                    emisor_barrio, emisor_otras_senas,
                    emisor_codigo_pais, emisor_telefono, emisor_correos,
                    receptor_cliente_id, receptor_nombre,
                    receptor_tipo_id, receptor_numero_id,
                    receptor_nombre_comercial,
                    receptor_provincia, receptor_canton, receptor_distrito,
                    receptor_barrio, receptor_otras_senas,
                    receptor_codigo_pais, receptor_telefono, receptor_correo,
                    moneda, tipo_cambio,
                    total_serv_gravados, total_serv_exentos, total_serv_exonerado, total_serv_no_sujeto,
                    total_merc_gravadas, total_merc_exentas, total_merc_exonerada, total_merc_no_sujeta,
                    total_gravado, total_exento, total_exonerado, total_no_sujeto,
                    total_venta, total_descuentos, total_venta_neta, total_impuesto,
                    total_imp_asumido_emisor, total_iva_devuelto, total_otros_cargos,
                    total_comprobante,
                    otros_texto, otros_contenido,
                    funcionario_id,
                    estado
                ) VALUES (
                    p_empresa_id, p_sucursal_id, p_caja_id, p_user_id,
                    p_tipo_documento, p_fecha_emision,
                    p_condicion_venta, p_condicion_venta_otros, p_plazo_credito,
                    p_codigo_actividad_emisor, p_codigo_actividad_receptor,
                    p_leyenda_tributaria, p_proveedor_sistemas, p_situacion_comprobante,
                    p_sucursal_codigo, p_terminal,
                    p_emisor_nombre, p_emisor_tipo_id, p_emisor_numero_id,
                    p_emisor_nombre_comercial, p_emisor_registro_fiscal,
                    p_emisor_provincia, p_emisor_canton, p_emisor_distrito,
                    p_emisor_barrio, p_emisor_otras_senas,
                    p_emisor_codigo_pais, p_emisor_telefono, p_emisor_correos,
                    p_receptor_cliente_id, p_receptor_nombre,
                    p_receptor_tipo_id, p_receptor_numero_id,
                    p_receptor_nombre_comercial,
                    p_receptor_provincia, p_receptor_canton, p_receptor_distrito,
                    p_receptor_barrio, p_receptor_otras_senas,
                    p_receptor_codigo_pais, p_receptor_telefono, p_receptor_correo,
                    p_moneda, p_tipo_cambio,
                    p_total_serv_gravados, p_total_serv_exentos, p_total_serv_exonerado, p_total_serv_no_sujeto,
                    p_total_merc_gravadas, p_total_merc_exentas, p_total_merc_exonerada, p_total_merc_no_sujeta,
                    p_total_gravado, p_total_exento, p_total_exonerado, p_total_no_sujeto,
                    p_total_venta, p_total_descuentos, p_total_venta_neta, p_total_impuesto,
                    p_total_imp_asumido_emisor, p_total_iva_devuelto, p_total_otros_cargos,
                    p_total_comprobante,
                    p_otros_texto, p_otros_contenido,
                    p_funcionario_id,
                    'borrador'
                ) RETURNING id INTO v_id;
                RETURN v_id;
            END;
            $$;


--
-- Name: sp_documento_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, sucursal_id bigint, caja_id bigint, user_id bigint, funcionario_id bigint, tipo_documento character varying, clave character varying, numero_consecutivo character varying, sucursal_codigo character varying, terminal character varying, consecutivo_comercio bigint, situacion_comprobante smallint, fecha_emision timestamp without time zone, version character varying, condicion_venta character varying, condicion_venta_otros text, plazo_credito character varying, codigo_actividad_emisor character varying, codigo_actividad_receptor character varying, leyenda_tributaria text, proveedor_sistemas character varying, numero_seguridad character varying, emisor_nombre character varying, emisor_tipo_id character varying, emisor_numero_id character varying, emisor_nombre_comercial character varying, emisor_registro_fiscal character varying, emisor_provincia character varying, emisor_canton character varying, emisor_distrito character varying, emisor_barrio character varying, emisor_otras_senas text, emisor_codigo_pais character varying, emisor_telefono character varying, emisor_correos jsonb, receptor_cliente_id bigint, receptor_nombre character varying, receptor_tipo_id character varying, receptor_numero_id character varying, receptor_nombre_comercial character varying, receptor_provincia character varying, receptor_canton character varying, receptor_distrito character varying, receptor_barrio character varying, receptor_otras_senas text, receptor_codigo_pais character varying, receptor_telefono character varying, receptor_correo character varying, moneda character varying, tipo_cambio numeric, total_serv_gravados numeric, total_serv_exentos numeric, total_serv_exonerado numeric, total_serv_no_sujeto numeric, total_merc_gravadas numeric, total_merc_exentas numeric, total_merc_exonerada numeric, total_merc_no_sujeta numeric, total_gravado numeric, total_exento numeric, total_exonerado numeric, total_no_sujeto numeric, total_venta numeric, total_descuentos numeric, total_venta_neta numeric, total_impuesto numeric, total_imp_asumido_emisor numeric, total_iva_devuelto numeric, total_otros_cargos numeric, total_comprobante numeric, otros_texto text, otros_contenido text, estado character varying, xml_firmado text, xml_respuesta text, qr_url text, hacienda_mensaje text, hacienda_detalle_mensaje text, hacienda_attempts smallint, hacienda_last_attempt_at timestamp without time zone, enviado_at timestamp without time zone, aceptado_at timestamp without time zone, rechazado_at timestamp without time zone, created_at timestamp without time zone, updated_at timestamp without time zone, lineas jsonb, otros_cargos jsonb, medios_pago jsonb, referencias jsonb, desglose_impuesto jsonb)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        d.id, d.empresa_id, d.sucursal_id, d.caja_id, d.user_id, d.funcionario_id,
        d.tipo_documento, d.clave, d.numero_consecutivo,
        d.sucursal_codigo, d.terminal, d.consecutivo_comercio,
        d.situacion_comprobante, d.fecha_emision, d.version,
        d.condicion_venta, d.condicion_venta_otros, d.plazo_credito,
        d.codigo_actividad_emisor, d.codigo_actividad_receptor,
        d.leyenda_tributaria, d.proveedor_sistemas, d.numero_seguridad,
        d.emisor_nombre, d.emisor_tipo_id, d.emisor_numero_id,
        d.emisor_nombre_comercial, d.emisor_registro_fiscal,
        d.emisor_provincia, d.emisor_canton, d.emisor_distrito,
        d.emisor_barrio, d.emisor_otras_senas,
        d.emisor_codigo_pais, d.emisor_telefono, d.emisor_correos,
        d.receptor_cliente_id, d.receptor_nombre,
        d.receptor_tipo_id, d.receptor_numero_id,
        d.receptor_nombre_comercial,
        d.receptor_provincia, d.receptor_canton, d.receptor_distrito,
        d.receptor_barrio, d.receptor_otras_senas,
        d.receptor_codigo_pais, d.receptor_telefono, d.receptor_correo,
        d.moneda, d.tipo_cambio,
        d.total_serv_gravados, d.total_serv_exentos, d.total_serv_exonerado,
        d.total_serv_no_sujeto, d.total_merc_gravadas, d.total_merc_exentas,
        d.total_merc_exonerada, d.total_merc_no_sujeta,
        d.total_gravado, d.total_exento, d.total_exonerado, d.total_no_sujeto,
        d.total_venta, d.total_descuentos, d.total_venta_neta,
        d.total_impuesto, d.total_imp_asumido_emisor, d.total_iva_devuelto,
        d.total_otros_cargos, d.total_comprobante,
        d.otros_texto, d.otros_contenido,
        d.estado, d.xml_firmado, d.xml_respuesta, d.qr_url,
        d.hacienda_mensaje, d.hacienda_detalle_mensaje,
        d.hacienda_attempts, d.hacienda_last_attempt_at,
        d.enviado_at, d.aceptado_at, d.rechazado_at,
        d.created_at, d.updated_at,
        COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', l.id, 'numero_linea', l.numero_linea, 'bodega_id', l.bodega_id,
                'funcionario_id', l.funcionario_id,
                'funcionario', l.funcionario, 'producto_id', l.producto_id,
                'codigo_actividad', l.codigo_actividad, 'cabys_code', l.cabys_code,
                'cantidad', l.cantidad, 'unidad_medida', l.unidad_medida,
                'tipo_unidad', l.tipo_unidad, 'tipo_transaccion', l.tipo_transaccion,
                'unidad_medida_comercial', l.unidad_medida_comercial, 'detalle', l.detalle,
                'registro_medicamento', l.registro_medicamento, 'forma_farmaceutica', l.forma_farmaceutica,
                'precio_unitario', l.precio_unitario, 'monto_total', l.monto_total,
                'subtotal', l.subtotal, 'iva_cobrado_fabrica', l.iva_cobrado_fabrica,
                'base_imponible', l.base_imponible, 'impuesto_asumido_emisor', l.impuesto_asumido_emisor,
                'impuesto_neto', l.impuesto_neto, 'monto_total_linea', l.monto_total_linea,
                'codigos_comerciales', l.codigos_comerciales, 'numeros_serie', l.numeros_serie,
                'descuentos', COALESCE((SELECT jsonb_agg(to_jsonb(dd)) FROM documento_linea_descuentos dd WHERE dd.linea_id = l.id), '[]'::jsonb),
                'impuestos', COALESCE((SELECT jsonb_agg(to_jsonb(i)) FROM documento_linea_impuestos i WHERE i.linea_id = l.id), '[]'::jsonb),
                'surtidos', COALESCE((SELECT jsonb_agg(to_jsonb(s)) FROM documento_linea_surtidos s WHERE s.linea_id = l.id), '[]'::jsonb)
            ) ORDER BY l.numero_linea)
            FROM documento_lineas l WHERE l.documento_id = d.id
        ), '[]'::jsonb),
        COALESCE((SELECT jsonb_agg(to_jsonb(oc)) FROM documento_otros_cargos oc WHERE oc.documento_id = d.id), '[]'::jsonb),
        COALESCE((SELECT jsonb_agg(to_jsonb(mp)) FROM documento_medios_pago mp WHERE mp.documento_id = d.id), '[]'::jsonb),
        COALESCE((SELECT jsonb_agg(to_jsonb(r)) FROM documento_referencias r WHERE r.documento_id = d.id), '[]'::jsonb),
        COALESCE((SELECT jsonb_agg(to_jsonb(di)) FROM documento_desglose_impuesto di WHERE di.documento_id = d.id), '[]'::jsonb)
    FROM documentos_electronicos d
    WHERE d.id = p_id
      AND (p_empresa_id = 0 OR d.empresa_id = p_empresa_id)
      AND d.deleted_at IS NULL;
END;
$$;


--
-- Name: sp_documento_list(bigint, character varying, character varying, text, date, date, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_list(p_empresa_id bigint, p_tipo_documento character varying DEFAULT NULL::character varying, p_estado character varying DEFAULT NULL::character varying, p_search text DEFAULT NULL::text, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date, p_page integer DEFAULT 1, p_per_page integer DEFAULT 20) RETURNS TABLE(id bigint, tipo_documento character varying, clave character varying, numero_consecutivo character varying, fecha_emision timestamp without time zone, receptor_nombre character varying, receptor_numero_id character varying, moneda character varying, total_comprobante numeric, estado character varying, aceptado_at timestamp without time zone, created_at timestamp without time zone, total_rows bigint)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    d.id, d.tipo_documento, d.clave, d.numero_consecutivo,
                    d.fecha_emision, d.receptor_nombre, d.receptor_numero_id,
                    d.moneda, d.total_comprobante, d.estado, d.aceptado_at,
                    d.created_at,
                    COUNT(*) OVER()::BIGINT AS total_rows
                FROM documentos_electronicos d
                WHERE d.empresa_id = p_empresa_id
                  AND d.deleted_at IS NULL
                  AND (p_tipo_documento IS NULL OR d.tipo_documento = p_tipo_documento)
                  AND (p_estado IS NULL OR d.estado = p_estado)
                  AND (p_fecha_desde IS NULL OR d.fecha_emision::DATE >= p_fecha_desde)
                  AND (p_fecha_hasta IS NULL OR d.fecha_emision::DATE <= p_fecha_hasta)
                  AND (p_search IS NULL
                       OR d.clave ILIKE '%' || p_search || '%'
                       OR d.receptor_nombre ILIKE '%' || p_search || '%'
                       OR d.receptor_numero_id ILIKE '%' || p_search || '%'
                       OR d.numero_consecutivo ILIKE '%' || p_search || '%')
                ORDER BY d.created_at DESC
                LIMIT p_per_page OFFSET (p_page - 1) * p_per_page;
            END;
            $$;


--
-- Name: sp_documento_reintentar(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_reintentar(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE documentos_electronicos
    SET estado                 = 'procesando',
        hacienda_attempts      = 0,
        hacienda_poll_attempts = 0,
        hacienda_mensaje       = NULL,
        updated_at             = NOW()
    WHERE id         = p_id
      AND empresa_id = p_empresa_id
      AND estado     IN ('pendiente_manual', 'procesando', 'error');
    RETURN FOUND;
END;
$$;


--
-- Name: sp_documento_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE documentos_electronicos
                SET deleted_at = NOW(), updated_at = NOW()
                WHERE id = p_id
                  AND empresa_id = p_empresa_id
                  AND estado = 'borrador'
                  AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_documento_update(bigint, bigint, timestamp without time zone, character varying, text, character varying, character varying, character varying, text, bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, text, character varying, character varying, character varying, character varying, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text, text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_update(p_id bigint, p_empresa_id bigint, p_fecha_emision timestamp without time zone, p_condicion_venta character varying, p_condicion_venta_otros text, p_plazo_credito character varying, p_codigo_actividad_emisor character varying, p_codigo_actividad_receptor character varying, p_leyenda_tributaria text, p_receptor_cliente_id bigint, p_receptor_nombre character varying, p_receptor_tipo_id character varying, p_receptor_numero_id character varying, p_receptor_nombre_comercial character varying, p_receptor_provincia character varying, p_receptor_canton character varying, p_receptor_distrito character varying, p_receptor_barrio character varying, p_receptor_otras_senas text, p_receptor_codigo_pais character varying, p_receptor_telefono character varying, p_receptor_correo character varying, p_moneda character varying, p_tipo_cambio numeric, p_total_serv_gravados numeric, p_total_serv_exentos numeric, p_total_serv_exonerado numeric, p_total_serv_no_sujeto numeric, p_total_merc_gravadas numeric, p_total_merc_exentas numeric, p_total_merc_exonerada numeric, p_total_merc_no_sujeta numeric, p_total_gravado numeric, p_total_exento numeric, p_total_exonerado numeric, p_total_no_sujeto numeric, p_total_venta numeric, p_total_descuentos numeric, p_total_venta_neta numeric, p_total_impuesto numeric, p_total_imp_asumido_emisor numeric, p_total_iva_devuelto numeric, p_total_otros_cargos numeric, p_total_comprobante numeric, p_otros_texto text, p_otros_contenido text, p_funcionario_id bigint DEFAULT NULL::bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE documentos_electronicos SET
                    fecha_emision               = p_fecha_emision,
                    condicion_venta             = p_condicion_venta,
                    condicion_venta_otros       = p_condicion_venta_otros,
                    plazo_credito               = p_plazo_credito,
                    codigo_actividad_emisor     = p_codigo_actividad_emisor,
                    codigo_actividad_receptor   = p_codigo_actividad_receptor,
                    leyenda_tributaria          = p_leyenda_tributaria,
                    receptor_cliente_id         = p_receptor_cliente_id,
                    receptor_nombre             = p_receptor_nombre,
                    receptor_tipo_id            = p_receptor_tipo_id,
                    receptor_numero_id          = p_receptor_numero_id,
                    receptor_nombre_comercial   = p_receptor_nombre_comercial,
                    receptor_provincia          = p_receptor_provincia,
                    receptor_canton             = p_receptor_canton,
                    receptor_distrito           = p_receptor_distrito,
                    receptor_barrio             = p_receptor_barrio,
                    receptor_otras_senas        = p_receptor_otras_senas,
                    receptor_codigo_pais        = p_receptor_codigo_pais,
                    receptor_telefono           = p_receptor_telefono,
                    receptor_correo             = p_receptor_correo,
                    moneda                      = p_moneda,
                    tipo_cambio                 = p_tipo_cambio,
                    total_serv_gravados         = p_total_serv_gravados,
                    total_serv_exentos          = p_total_serv_exentos,
                    total_serv_exonerado        = p_total_serv_exonerado,
                    total_serv_no_sujeto        = p_total_serv_no_sujeto,
                    total_merc_gravadas         = p_total_merc_gravadas,
                    total_merc_exentas          = p_total_merc_exentas,
                    total_merc_exonerada        = p_total_merc_exonerada,
                    total_merc_no_sujeta        = p_total_merc_no_sujeta,
                    total_gravado               = p_total_gravado,
                    total_exento                = p_total_exento,
                    total_exonerado             = p_total_exonerado,
                    total_no_sujeto             = p_total_no_sujeto,
                    total_venta                 = p_total_venta,
                    total_descuentos            = p_total_descuentos,
                    total_venta_neta            = p_total_venta_neta,
                    total_impuesto              = p_total_impuesto,
                    total_imp_asumido_emisor    = p_total_imp_asumido_emisor,
                    total_iva_devuelto          = p_total_iva_devuelto,
                    total_otros_cargos          = p_total_otros_cargos,
                    total_comprobante           = p_total_comprobante,
                    otros_texto                 = p_otros_texto,
                    otros_contenido             = p_otros_contenido,
                    funcionario_id              = p_funcionario_id,
                    updated_at                  = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_documento_update_estado(bigint, character varying, text, text, text, text, text, smallint, timestamp without time zone, timestamp without time zone, timestamp without time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_update_estado(p_id bigint, p_estado character varying, p_xml_firmado text DEFAULT NULL::text, p_xml_respuesta text DEFAULT NULL::text, p_qr_url text DEFAULT NULL::text, p_hacienda_mensaje text DEFAULT NULL::text, p_hacienda_detalle_mensaje text DEFAULT NULL::text, p_hacienda_attempts smallint DEFAULT NULL::smallint, p_enviado_at timestamp without time zone DEFAULT NULL::timestamp without time zone, p_aceptado_at timestamp without time zone DEFAULT NULL::timestamp without time zone, p_rechazado_at timestamp without time zone DEFAULT NULL::timestamp without time zone, p_hacienda_poll_attempts integer DEFAULT NULL::integer) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE documentos_electronicos SET
                    estado                      = p_estado,
                    xml_firmado                 = COALESCE(p_xml_firmado, xml_firmado),
                    xml_respuesta               = COALESCE(p_xml_respuesta, xml_respuesta),
                    qr_url                      = COALESCE(p_qr_url, qr_url),
                    hacienda_mensaje            = COALESCE(p_hacienda_mensaje, hacienda_mensaje),
                    hacienda_detalle_mensaje    = COALESCE(p_hacienda_detalle_mensaje, hacienda_detalle_mensaje),
                    hacienda_attempts           = COALESCE(p_hacienda_attempts, hacienda_attempts),
                    hacienda_poll_attempts      = COALESCE(p_hacienda_poll_attempts, hacienda_poll_attempts),
                    hacienda_last_attempt_at    = NOW(),
                    enviado_at                  = COALESCE(p_enviado_at, enviado_at),
                    aceptado_at                 = COALESCE(p_aceptado_at, aceptado_at),
                    rechazado_at                = COALESCE(p_rechazado_at, rechazado_at),
                    updated_at                  = NOW()
                WHERE id = p_id;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_empresa_condicion_ventas_save(integer, character varying, boolean, boolean); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_empresa_condicion_ventas_save(IN p_empresa_id integer, IN p_codigo character varying, IN p_activo boolean, IN p_es_default boolean)
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF p_es_default THEN
    UPDATE empresa_condicion_ventas
    SET es_default = false, updated_at = NOW()
    WHERE empresa_id = p_empresa_id AND codigo <> p_codigo;
  END IF;

  INSERT INTO empresa_condicion_ventas (empresa_id, codigo, activo, es_default, updated_at)
  VALUES (p_empresa_id, p_codigo, p_activo, p_es_default, NOW())
  ON CONFLICT (empresa_id, codigo) DO UPDATE
    SET activo     = EXCLUDED.activo,
        es_default = EXCLUDED.es_default,
        updated_at = NOW();
END;
$$;


--
-- Name: empresa_hacienda_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_hacienda_config (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    tipo_identificacion character varying(2) DEFAULT '02'::character varying NOT NULL,
    numero_identificacion character varying(30) NOT NULL,
    nombre_emisor character varying(255),
    nombre_comercial character varying(255),
    codigo_pais character varying(3) DEFAULT 'CRC'::character varying NOT NULL,
    codigo_actividad character varying(10),
    telefono character varying(30),
    correo_electronico character varying(255),
    provincia character varying(2),
    canton character varying(2),
    distrito character varying(2),
    barrio character varying(2),
    otras_senas text,
    hacienda_usuario character varying(255),
    hacienda_contrasena text,
    hacienda_ambiente character varying(10) DEFAULT 'sandbox'::character varying NOT NULL,
    credenciales_validas boolean DEFAULT false,
    credenciales_verificadas_at timestamp without time zone,
    certificado_p12 text,
    certificado_pin text,
    certificado_cn character varying(255),
    certificado_fecha_inicio date,
    certificado_fecha_vence date,
    certificado_valido boolean DEFAULT false,
    certificado_verificado_at timestamp without time zone,
    is_active boolean DEFAULT true NOT NULL,
    created_by text,
    updated_by text,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    deleted_at timestamp without time zone
);


--
-- Name: sp_empresa_hacienda_get(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_hacienda_get(p_empresa_id bigint) RETURNS SETOF public.empresa_hacienda_config
    LANGUAGE plpgsql
    AS $$                                                                 BEGIN                                                                         RETURN QUERY SELECT * FROM empresa_hacienda_config                        WHERE empresa_id = p_empresa_id AND deleted_at IS NULL                    LIMIT 1;                                                                  END;                                                                          $$;


--
-- Name: sp_empresa_hacienda_save_certificado(bigint, text, text, character varying, date, date, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_hacienda_save_certificado(p_empresa_id bigint, p_cert_b64 text, p_cert_pin text, p_cert_cn character varying, p_fecha_inicio date, p_fecha_vence date, p_valido boolean, p_updated_by text) RETURNS void
    LANGUAGE plpgsql
    AS $$                                                                                                                                                                                                                           BEGIN                                                                                                                                                                                                                                   UPDATE empresa_hacienda_config SET                                                                                                                                                                                                  certificado_p12            = p_cert_b64,                                                                                                                                                                                        certificado_pin            = p_cert_pin,                                                                                                                                                                                        certificado_cn             = p_cert_cn,                                                                                                                                                                                         certificado_fecha_inicio   = p_fecha_inicio,                                                                                                                                                                                    certificado_fecha_vence    = p_fecha_vence,                                                                                                                                                                                     certificado_valido         = p_valido,                                                                                                                                                                                          certificado_verificado_at  = NOW(),                                                                                                                                                                                             updated_by                 = p_updated_by,                                                                                                                                                                                      updated_at                 = NOW()                                                                                                                                                                                              WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;                                                                                                                                                                             END;                                                                                                                                                                                                                                    $$;


--
-- Name: sp_empresa_hacienda_save_credenciales(bigint, character varying, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_hacienda_save_credenciales(p_empresa_id bigint, p_usuario character varying, p_contrasena text, p_updated_by text) RETURNS void
    LANGUAGE plpgsql
    AS $$                                                                                                                                                  BEGIN                                                                                                                                                          UPDATE empresa_hacienda_config SET                                                                                                                         hacienda_usuario     = p_usuario,                                                                                                                      hacienda_contrasena  = p_contrasena,                                                                                                                   credenciales_validas = FALSE,                                                                                                                          credenciales_verificadas_at = NULL,                                                                                                                    updated_by           = p_updated_by,                                                                                                                   updated_at           = NOW()                                                                                                                           WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;                                                                                                    END;                                                                                                                                                           $$;


--
-- Name: sp_empresa_hacienda_save_info(bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, text, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_hacienda_save_info(p_empresa_id bigint, p_tipo_id character varying, p_numero_id character varying, p_nombre_emisor character varying, p_nombre_comercial character varying, p_codigo_pais character varying, p_codigo_actividad character varying, p_telefono character varying, p_correo character varying, p_provincia character varying, p_canton character varying, p_distrito character varying, p_barrio character varying, p_otras_senas text, p_ambiente character varying, p_updated_by text) RETURNS SETOF public.empresa_hacienda_config
    LANGUAGE plpgsql
    AS $$                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       BEGIN                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               INSERT INTO empresa_hacienda_config (                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           empresa_id, tipo_identificacion, numero_identificacion,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     nombre_emisor, nombre_comercial, codigo_pais, codigo_actividad,                                                                                                                                                                                                                                                                                                                                                                                                                                                                             telefono, correo_electronico, provincia, canton, distrito, barrio,                                                                                                                                                                                                                                                                                                                                                                                                                                                                          otras_senas, hacienda_ambiente, created_by, updated_by                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      ) VALUES (                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      p_empresa_id, p_tipo_id, p_numero_id,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       p_nombre_emisor, p_nombre_comercial, p_codigo_pais, p_codigo_actividad,                                                                                                                                                                                                                                                                                                                                                                                                                                                                     p_telefono, p_correo, p_provincia, p_canton, p_distrito, p_barrio,                                                                                                                                                                                                                                                                                                                                                                                                                                                                          p_otras_senas, p_ambiente, p_updated_by, p_updated_by                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       )                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               ON CONFLICT (empresa_id) DO UPDATE SET                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          tipo_identificacion = EXCLUDED.tipo_identificacion,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         numero_identificacion = EXCLUDED.numero_identificacion,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     nombre_emisor = EXCLUDED.nombre_emisor,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     nombre_comercial = EXCLUDED.nombre_comercial,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               codigo_pais = EXCLUDED.codigo_pais,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         codigo_actividad = EXCLUDED.codigo_actividad,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               telefono = EXCLUDED.telefono,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               correo_electronico = EXCLUDED.correo_electronico,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           provincia = EXCLUDED.provincia,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             canton = EXCLUDED.canton,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   distrito = EXCLUDED.distrito,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               barrio = EXCLUDED.barrio,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   otras_senas = EXCLUDED.otras_senas,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         hacienda_ambiente = EXCLUDED.hacienda_ambiente,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             updated_by = p_updated_by,                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  updated_at = NOW();                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         RETURN QUERY SELECT * FROM empresa_hacienda_config WHERE empresa_id = p_empresa_id;                                                                                                                                                                                                                                                                                                                                                                                                                                                             END;                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                $$;


--
-- Name: sp_empresa_hacienda_set_credenciales_status(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_hacienda_set_credenciales_status(p_empresa_id bigint, p_validas boolean) RETURNS void
    LANGUAGE plpgsql
    AS $$                                                                                                        BEGIN                                                                                                                UPDATE empresa_hacienda_config SET                                                                               credenciales_validas        = p_validas,                                                                     credenciales_verificadas_at = NOW(),                                                                         updated_at                  = NOW()                                                                          WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;                                                          END;                                                                                                                 $$;


--
-- Name: sp_factura_recibida_create(bigint, character varying, character varying, character varying, timestamp without time zone, character varying, character varying, character varying, character varying, character varying, character varying, character varying, numeric, numeric, text, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_create(p_empresa_id bigint, p_clave character varying, p_tipo_documento character varying, p_numero_consecutivo character varying, p_fecha_emision timestamp without time zone, p_emisor_tipo_id character varying, p_emisor_numero_id character varying, p_emisor_nombre character varying, p_receptor_tipo_id character varying, p_receptor_numero_id character varying, p_receptor_nombre character varying, p_moneda character varying, p_total_comprobante numeric, p_total_impuesto numeric, p_xml_recibido text, p_estado_hacienda character varying, p_hacienda_mensaje text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO facturas_recibidas(
                    empresa_id, clave, tipo_documento, numero_consecutivo_emisor,
                    fecha_emision, emisor_tipo_id, emisor_numero_id, emisor_nombre,
                    receptor_tipo_id, receptor_numero_id, receptor_nombre,
                    moneda, total_comprobante, total_impuesto,
                    xml_recibido, estado_hacienda, hacienda_mensaje
                )
                VALUES(
                    p_empresa_id, p_clave, p_tipo_documento, p_numero_consecutivo,
                    p_fecha_emision, p_emisor_tipo_id, p_emisor_numero_id, p_emisor_nombre,
                    p_receptor_tipo_id, p_receptor_numero_id, p_receptor_nombre,
                    p_moneda, p_total_comprobante, p_total_impuesto,
                    p_xml_recibido, p_estado_hacienda, p_hacienda_mensaje
                )
                ON CONFLICT (empresa_id, clave)
                DO UPDATE SET
                    estado_hacienda  = EXCLUDED.estado_hacienda,
                    hacienda_mensaje = EXCLUDED.hacienda_mensaje,
                    updated_at       = NOW()
                RETURNING id INTO v_id;
                RETURN v_id;
            END;
            $$;


--
-- Name: facturas_recibidas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.facturas_recibidas (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    clave character varying(50),
    tipo_documento character varying(2),
    numero_consecutivo_emisor character varying(20),
    fecha_emision timestamp without time zone,
    emisor_tipo_id character varying(2),
    emisor_numero_id character varying(20),
    emisor_nombre character varying(255),
    receptor_tipo_id character varying(2),
    receptor_numero_id character varying(20),
    receptor_nombre character varying(255),
    moneda character varying(3) DEFAULT 'CRC'::character varying,
    total_comprobante numeric(18,5) DEFAULT 0,
    total_impuesto numeric(18,5) DEFAULT 0,
    xml_recibido text,
    estado_hacienda character varying(30) DEFAULT 'pendiente'::character varying,
    hacienda_mensaje text,
    estado_recepcion character varying(30) DEFAULT 'pendiente'::character varying,
    mensaje_tipo smallint,
    detalle_mensaje character varying(160),
    monto_impuesto_acreditar numeric(18,5),
    monto_total_linea_detalle numeric(18,5),
    numero_consecutivo_receptor character varying(20),
    xml_mensaje_receptor text,
    hacienda_respuesta_mr text,
    respondido_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


--
-- Name: sp_factura_recibida_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_get(p_id bigint, p_empresa_id bigint) RETURNS SETOF public.facturas_recibidas
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT * FROM facturas_recibidas
                WHERE id = p_id AND empresa_id = p_empresa_id;
            END;
            $$;


--
-- Name: sp_factura_recibida_list(bigint, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_list(p_empresa_id bigint, p_estado character varying DEFAULT NULL::character varying, p_search text DEFAULT NULL::text) RETURNS TABLE(id bigint, empresa_id bigint, clave character varying, tipo_documento character varying, numero_consecutivo_emisor character varying, fecha_emision timestamp without time zone, emisor_tipo_id character varying, emisor_numero_id character varying, emisor_nombre character varying, moneda character varying, total_comprobante numeric, total_impuesto numeric, estado_hacienda character varying, estado_recepcion character varying, mensaje_tipo smallint, respondido_at timestamp without time zone, created_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT f.id, f.empresa_id,
                       f.clave, f.tipo_documento,
                       f.numero_consecutivo_emisor,
                       f.fecha_emision,
                       f.emisor_tipo_id, f.emisor_numero_id, f.emisor_nombre,
                       f.moneda, f.total_comprobante, f.total_impuesto,
                       f.estado_hacienda, f.estado_recepcion,
                       f.mensaje_tipo, f.respondido_at,
                       f.created_at
                FROM facturas_recibidas f
                WHERE f.empresa_id = p_empresa_id
                  AND (p_estado IS NULL OR f.estado_recepcion = p_estado)
                  AND (
                    p_search IS NULL OR p_search = ''
                    OR f.emisor_nombre   ILIKE '%' || p_search || '%'
                    OR f.emisor_numero_id ILIKE '%' || p_search || '%'
                    OR f.clave           ILIKE '%' || p_search || '%'
                  )
                ORDER BY f.created_at DESC;
            END;
            $$;


--
-- Name: sp_factura_recibida_responder(bigint, bigint, smallint, character varying, numeric, numeric, character varying, text, text, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_responder(p_id bigint, p_empresa_id bigint, p_mensaje_tipo smallint, p_detalle_mensaje character varying, p_monto_impuesto_acreditar numeric, p_monto_total_linea_detalle numeric, p_numero_consecutivo_receptor character varying, p_xml_mensaje_receptor text, p_hacienda_respuesta_mr text, p_estado_recepcion character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE facturas_recibidas
                SET mensaje_tipo                  = p_mensaje_tipo,
                    detalle_mensaje               = p_detalle_mensaje,
                    monto_impuesto_acreditar      = p_monto_impuesto_acreditar,
                    monto_total_linea_detalle     = p_monto_total_linea_detalle,
                    numero_consecutivo_receptor   = p_numero_consecutivo_receptor,
                    xml_mensaje_receptor          = p_xml_mensaje_receptor,
                    hacienda_respuesta_mr         = p_hacienda_respuesta_mr,
                    estado_recepcion              = p_estado_recepcion,
                    respondido_at                 = NOW(),
                    updated_at                    = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_funcionario_create(bigint, character varying, character varying, character varying, character varying, text, date, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_create(p_empresa_id bigint, p_name character varying, p_tax_id character varying, p_email character varying, p_phone character varying, p_address text, p_birth_date date DEFAULT NULL::date, p_commission_pct numeric DEFAULT 0.00, p_notes text DEFAULT NULL::text) RETURNS TABLE(id bigint, name character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                INSERT INTO funcionarios (
                    empresa_id, name, tax_id,
                    email, phone, address, birth_date, commission_pct, notes
                )
                VALUES (
                    p_empresa_id, p_name, p_tax_id,
                    p_email, p_phone, p_address, p_birth_date, p_commission_pct, p_notes
                )
                RETURNING funcionarios.id, funcionarios.name;
            END; $$;


--
-- Name: sp_funcionario_find(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_find(p_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, tax_id character varying, email character varying, phone character varying, address text, birth_date date, commission_pct numeric, notes text, is_default boolean, is_active boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT f.id, f.empresa_id,
                       f.name, f.tax_id,
                       f.email, f.phone, f.address,
                       f.birth_date, f.commission_pct, f.notes,
                       f.is_default, f.is_active,
                       f.created_at, f.updated_at
                FROM funcionarios f
                WHERE f.id = p_id AND f.deleted_at IS NULL;
            END; $$;


--
-- Name: sp_funcionario_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_list(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, tax_id character varying, email character varying, phone character varying, address text, birth_date date, commission_pct numeric, notes text, is_default boolean, is_active boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT f.id, f.empresa_id,
                       f.name, f.tax_id,
                       f.email, f.phone, f.address,
                       f.birth_date, f.commission_pct, f.notes,
                       f.is_default, f.is_active,
                       f.created_at, f.updated_at
                FROM funcionarios f
                WHERE f.empresa_id = p_empresa_id AND f.deleted_at IS NULL
                ORDER BY f.is_default DESC, f.name;
            END; $$;


--
-- Name: sp_funcionario_search(bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_search(p_empresa_id bigint, p_query character varying) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, tax_id character varying, email character varying, phone character varying, address text, birth_date date, commission_pct numeric, notes text, is_default boolean, is_active boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT f.id, f.empresa_id,
                       f.name, f.tax_id,
                       f.email, f.phone, f.address,
                       f.birth_date, f.commission_pct, f.notes,
                       f.is_default, f.is_active,
                       f.created_at, f.updated_at
                FROM funcionarios f
                WHERE f.empresa_id = p_empresa_id
                  AND f.deleted_at IS NULL
                  AND (
                      f.name   ILIKE '%' || p_query || '%' OR
                      f.tax_id ILIKE '%' || p_query || '%' OR
                      f.email  ILIKE '%' || p_query || '%'
                  )
                ORDER BY f.is_default DESC, f.name;
            END; $$;


--
-- Name: sp_funcionario_set_default(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_set_default(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                -- Quitar default a todos los de la empresa
                UPDATE funcionarios SET is_default = FALSE, updated_at = NOW()
                WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;
                -- Poner default al seleccionado
                UPDATE funcionarios SET is_default = TRUE, updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_funcionario_soft_delete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_soft_delete(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE funcionarios SET is_active = FALSE, deleted_at = NOW(), updated_at = NOW()
                WHERE id = p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_funcionario_toggle_status(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_toggle_status(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE funcionarios SET is_active = NOT is_active, updated_at = NOW()
                WHERE id = p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_funcionario_update(bigint, character varying, character varying, character varying, character varying, text, date, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_update(p_id bigint, p_name character varying, p_tax_id character varying, p_email character varying, p_phone character varying, p_address text, p_birth_date date DEFAULT NULL::date, p_commission_pct numeric DEFAULT 0.00, p_notes text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE funcionarios SET
                    name           = p_name,
                    tax_id         = p_tax_id,
                    email          = p_email,
                    phone          = p_phone,
                    address        = p_address,
                    birth_date     = p_birth_date,
                    commission_pct = p_commission_pct,
                    notes          = p_notes,
                    updated_at     = NOW()
                WHERE id = p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_medio_pago_create(bigint, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_medio_pago_create(p_empresa_id bigint, p_nombre character varying, p_tipo_hacienda_codigo character varying, p_tipo_hacienda_nombre character varying) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO empresa_medios_pago(empresa_id, nombre, tipo_hacienda_codigo, tipo_hacienda_nombre)
                VALUES (p_empresa_id, p_nombre, p_tipo_hacienda_codigo, p_tipo_hacienda_nombre)
                RETURNING id INTO v_id;
                RETURN v_id;
            END;
            $$;


--
-- Name: sp_medio_pago_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_medio_pago_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE empresa_medios_pago
                SET deleted_at = NOW(), updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_medio_pago_reordenar(bigint, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_medio_pago_reordenar(p_id bigint, p_empresa_id bigint, p_direccion text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_orden_actual integer;
  v_tipo         character varying(2);
  v_id_swap      bigint;
  v_orden_swap   integer;
BEGIN
  SELECT orden, tipo_hacienda_codigo INTO v_orden_actual, v_tipo
  FROM empresa_medios_pago WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;

  IF NOT FOUND THEN RETURN false; END IF;

  IF p_direccion = 'up' THEN
    SELECT id, orden INTO v_id_swap, v_orden_swap
    FROM empresa_medios_pago
    WHERE empresa_id = p_empresa_id AND tipo_hacienda_codigo = v_tipo
      AND deleted_at IS NULL AND orden < v_orden_actual
    ORDER BY orden DESC LIMIT 1;
  ELSE
    SELECT id, orden INTO v_id_swap, v_orden_swap
    FROM empresa_medios_pago
    WHERE empresa_id = p_empresa_id AND tipo_hacienda_codigo = v_tipo
      AND deleted_at IS NULL AND orden > v_orden_actual
    ORDER BY orden ASC LIMIT 1;
  END IF;

  IF v_id_swap IS NULL THEN RETURN false; END IF;

  UPDATE empresa_medios_pago SET orden = v_orden_swap WHERE id = p_id;
  UPDATE empresa_medios_pago SET orden = v_orden_actual WHERE id = v_id_swap;
  RETURN true;
END;
$$;


--
-- Name: sp_medio_pago_update(bigint, bigint, character varying, character varying, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_medio_pago_update(p_id bigint, p_empresa_id bigint, p_nombre character varying, p_tipo_hacienda_codigo character varying, p_tipo_hacienda_nombre character varying, p_is_active boolean) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE empresa_medios_pago
                SET nombre               = p_nombre,
                    tipo_hacienda_codigo = p_tipo_hacienda_codigo,
                    tipo_hacienda_nombre = p_tipo_hacienda_nombre,
                    is_active            = p_is_active,
                    updated_at           = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_medios_pago_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_medios_pago_list(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, nombre character varying, tipo_hacienda_codigo character varying, tipo_hacienda_nombre character varying, is_active boolean, orden integer, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT m.id, m.empresa_id, m.nombre, m.tipo_hacienda_codigo,
         m.tipo_hacienda_nombre, m.is_active, m.orden, m.created_at, m.updated_at
  FROM empresa_medios_pago m
  WHERE m.empresa_id = p_empresa_id
    AND m.deleted_at IS NULL
  ORDER BY m.tipo_hacienda_codigo, m.orden, m.nombre;
END;
$$;


--
-- Name: sp_moneda_create(bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_moneda_create(p_empresa_id bigint, p_codigo character varying, p_nombre character varying) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_id BIGINT;
BEGIN
  INSERT INTO empresa_monedas(empresa_id, codigo, nombre)
  VALUES (p_empresa_id, p_codigo, p_nombre)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;


--
-- Name: sp_moneda_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_moneda_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE empresa_monedas SET deleted_at = NOW(), updated_at = NOW()
  WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL AND is_default = false;
  RETURN FOUND;
END;
$$;


--
-- Name: sp_moneda_set_default(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_moneda_set_default(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE empresa_monedas SET is_default = false, updated_at = NOW()
  WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;
  UPDATE empresa_monedas SET is_default = true, updated_at = NOW()
  WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
  RETURN FOUND;
END;
$$;


--
-- Name: sp_moneda_update(bigint, bigint, character varying, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_moneda_update(p_id bigint, p_empresa_id bigint, p_codigo character varying, p_nombre character varying, p_is_active boolean) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE empresa_monedas
  SET codigo = p_codigo, nombre = p_nombre, is_active = p_is_active, updated_at = NOW()
  WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
  RETURN FOUND;
END;
$$;


--
-- Name: sp_monedas_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_monedas_list(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, codigo character varying, nombre character varying, is_default boolean, is_active boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT m.id, m.empresa_id, m.codigo, m.nombre, m.is_default, m.is_active, m.created_at, m.updated_at
  FROM empresa_monedas m
  WHERE m.empresa_id = p_empresa_id AND m.deleted_at IS NULL
  ORDER BY m.is_default DESC, m.codigo;
END;
$$;


--
-- Name: sp_producto_create(bigint, bigint, character varying, character varying, text, character varying, character varying, character varying, numeric, character varying, character varying, numeric, text, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_create(p_empresa_id bigint, p_categoria_id bigint, p_code character varying, p_name character varying, p_description text, p_type character varying, p_unit_measure character varying, p_cabys_code character varying, p_price numeric, p_tax_type character varying, p_tax_code character varying, p_tax_rate numeric, p_image_url text DEFAULT NULL::text, p_image_public_id character varying DEFAULT NULL::character varying) RETURNS TABLE(id bigint, code character varying, name character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_producto_id BIGINT;
    v_code        VARCHAR;
    v_name        VARCHAR;
BEGIN
    INSERT INTO productos (
        empresa_id, categoria_id, code, name, description, type,
        unit_measure, cabys_code, price, tax_type, tax_code, tax_rate,
        image_url, image_public_id
    )
    VALUES (
        p_empresa_id, NULLIF(p_categoria_id, 0), p_code, p_name, p_description, p_type,
        p_unit_measure, NULLIF(p_cabys_code, ''), p_price, p_tax_type, p_tax_code, p_tax_rate,
        p_image_url, p_image_public_id
    )
    RETURNING productos.id, productos.code, productos.name
    INTO v_producto_id, v_code, v_name;

    IF p_type = 'product' THEN
        INSERT INTO bodega_productos (bodega_id, producto_id, stock, stock_min)
        SELECT b.id, v_producto_id, 0, 0
        FROM bodegas b
        WHERE b.empresa_id = p_empresa_id AND b.deleted_at IS NULL
        ON CONFLICT (bodega_id, producto_id) DO NOTHING;
    END IF;

    RETURN QUERY SELECT v_producto_id, v_code, v_name;
END;
$$;


--
-- Name: sp_producto_deleted_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_deleted_list(p_empresa_id bigint) RETURNS TABLE(id bigint, code character varying, name character varying, description text, type character varying, image_url text, image_public_id character varying, deleted_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT p.id, p.code, p.name, p.description, p.type,
           p.image_url, p.image_public_id, p.deleted_at
    FROM productos p
    WHERE p.empresa_id = p_empresa_id
      AND p.deleted_at IS NOT NULL
    ORDER BY p.deleted_at DESC;
END;
$$;


--
-- Name: sp_producto_list(bigint, bigint, character varying, bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_list(p_empresa_id bigint, p_bodega_id bigint DEFAULT NULL::bigint, p_search character varying DEFAULT NULL::character varying, p_categoria_id bigint DEFAULT NULL::bigint, p_estado character varying DEFAULT 'todos'::character varying, p_tipo character varying DEFAULT NULL::character varying) RETURNS TABLE(id bigint, empresa_id bigint, categoria_id bigint, categoria_name character varying, code character varying, name character varying, description text, type character varying, unit_measure character varying, cabys_code character varying, price numeric, tax_type character varying, tax_code character varying, tax_rate numeric, price_with_tax numeric, is_active boolean, image_url text, image_public_id character varying, bodega_id bigint, stock numeric, stock_min numeric, bodega_active boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT p.id, p.empresa_id, p.categoria_id, c.name,
           p.code, p.name, p.description, p.type,
           p.unit_measure, p.cabys_code,
           p.price, p.tax_type, p.tax_code, p.tax_rate,
           ROUND(p.price * (1 + p.tax_rate / 100), 5),
           p.is_active,
           p.image_url, p.image_public_id,
           bp.bodega_id, bp.stock, bp.stock_min, bp.is_active
    FROM productos p
    LEFT JOIN categorias_producto c ON c.id = p.categoria_id
    LEFT JOIN bodega_productos bp ON bp.producto_id = p.id
        AND (p_bodega_id IS NULL OR bp.bodega_id = p_bodega_id)
    WHERE p.empresa_id = p_empresa_id
      AND p.deleted_at IS NULL
      AND (p_tipo         IS NULL OR p.type         = p_tipo)
      AND (p_categoria_id IS NULL OR p.categoria_id = p_categoria_id)
      AND (
          p_estado = 'todos'
          OR (p_estado = 'activos'   AND p.is_active = TRUE)
          OR (p_estado = 'inactivos' AND p.is_active = FALSE)
      )
      AND (p_search IS NULL
           OR p.name        ILIKE '%' || p_search || '%'
           OR p.code        ILIKE '%' || p_search || '%'
           OR p.cabys_code  ILIKE '%' || p_search || '%'
           OR p.description ILIKE '%' || p_search || '%')
    ORDER BY p.is_active DESC, p.code, p.name;
END;
$$;


--
-- Name: sp_producto_restore(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_restore(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE v_rows INTEGER;
BEGIN
    UPDATE productos SET is_active = TRUE, deleted_at = NULL, updated_at = NOW()
    WHERE id = p_id AND deleted_at IS NOT NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
END;
$$;


--
-- Name: sp_producto_soft_delete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_soft_delete(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE productos SET is_active=FALSE, deleted_at=NOW(), updated_at=NOW()
                WHERE id=p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_producto_toggle(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_toggle(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE productos SET is_active = NOT is_active, updated_at = NOW()
                WHERE id = p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_producto_update(bigint, bigint, character varying, character varying, text, character varying, character varying, character varying, numeric, character varying, character varying, numeric, text, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_update(p_id bigint, p_categoria_id bigint, p_code character varying, p_name character varying, p_description text, p_type character varying, p_unit_measure character varying, p_cabys_code character varying, p_price numeric, p_tax_type character varying, p_tax_code character varying, p_tax_rate numeric, p_image_url text DEFAULT NULL::text, p_image_public_id character varying DEFAULT NULL::character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE v_rows INTEGER;
BEGIN
    UPDATE productos SET
        categoria_id    = NULLIF(p_categoria_id, 0),
        code            = p_code,
        name            = p_name,
        description     = p_description,
        type            = p_type,
        unit_measure    = p_unit_measure,
        cabys_code      = NULLIF(p_cabys_code, ''),
        price           = p_price,
        tax_type        = p_tax_type,
        tax_code        = p_tax_code,
        tax_rate        = p_tax_rate,
        image_url       = p_image_url,
        image_public_id = p_image_public_id,
        updated_at      = NOW()
    WHERE id = p_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
END;
$$;


--
-- Name: sp_proveedor_create(bigint, character varying, character varying, character varying, character varying, character varying, character varying, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_create(p_empresa_id bigint, p_name character varying, p_legal_name character varying, p_tipo_id character varying, p_tax_id character varying, p_email character varying, p_phone character varying, p_address text, p_notes text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO proveedores(empresa_id, name, legal_name, tipo_id, tax_id, email, phone, address, notes)
                VALUES (p_empresa_id, p_name, p_legal_name, p_tipo_id, p_tax_id, p_email, p_phone, p_address, p_notes)
                RETURNING id INTO v_id;
                RETURN v_id;
            END;
            $$;


--
-- Name: sp_proveedor_create(bigint, character varying, character varying, character varying, character varying, character varying, character varying, text, text, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_create(p_empresa_id bigint, p_name character varying, p_legal_name character varying, p_tipo_id character varying, p_tax_id character varying, p_email character varying, p_phone character varying, p_address text, p_notes text, p_actividad_economica_codigo character varying DEFAULT NULL::character varying, p_actividad_economica_descripcion character varying DEFAULT NULL::character varying) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO proveedores(empresa_id, name, legal_name, tipo_id, tax_id, email, phone,
                          address, notes, actividad_economica_codigo, actividad_economica_descripcion)
  VALUES (p_empresa_id, p_name, p_legal_name, p_tipo_id, p_tax_id, p_email, p_phone,
          p_address, p_notes, p_actividad_economica_codigo, p_actividad_economica_descripcion)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;


--
-- Name: sp_proveedor_find_by_tax_id(character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_find_by_tax_id(p_tax_id character varying, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, legal_name character varying, tipo_id character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
  SELECT id, empresa_id, name, legal_name, tipo_id, tax_id, email, phone, address, notes,
         is_active, actividad_economica_codigo, actividad_economica_descripcion, created_at, updated_at
  FROM   proveedores
  WHERE  tax_id = p_tax_id AND empresa_id = p_empresa_id AND deleted_at IS NULL LIMIT 1;
$$;


--
-- Name: sp_proveedor_list(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_list(p_empresa_id bigint, p_search text DEFAULT NULL::text) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, legal_name character varying, tipo_id character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
  SELECT id, empresa_id, name, legal_name, tipo_id, tax_id, email, phone, address, notes,
         is_active, actividad_economica_codigo, actividad_economica_descripcion, created_at, updated_at
  FROM   proveedores
  WHERE  empresa_id = p_empresa_id AND deleted_at IS NULL
    AND  (p_search IS NULL OR name ILIKE '%'||p_search||'%' OR tax_id ILIKE '%'||p_search||'%')
  ORDER BY name;
$$;


--
-- Name: sp_proveedor_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE proveedores
                SET deleted_at = NOW(), updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_proveedor_toggle(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_toggle(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE proveedores
                SET is_active = NOT is_active, updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_proveedor_update(bigint, bigint, character varying, character varying, character varying, character varying, character varying, character varying, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_update(p_id bigint, p_empresa_id bigint, p_name character varying, p_legal_name character varying, p_tipo_id character varying, p_tax_id character varying, p_email character varying, p_phone character varying, p_address text, p_notes text, p_is_active boolean) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE proveedores
                SET name       = p_name,
                    legal_name = p_legal_name,
                    tipo_id    = p_tipo_id,
                    tax_id     = p_tax_id,
                    email      = p_email,
                    phone      = p_phone,
                    address    = p_address,
                    notes      = p_notes,
                    is_active  = p_is_active,
                    updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_proveedor_update(bigint, bigint, character varying, character varying, character varying, character varying, character varying, character varying, text, text, boolean, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_update(p_id bigint, p_empresa_id bigint, p_name character varying, p_legal_name character varying, p_tipo_id character varying, p_tax_id character varying, p_email character varying, p_phone character varying, p_address text, p_notes text, p_is_active boolean, p_actividad_economica_codigo character varying DEFAULT NULL::character varying, p_actividad_economica_descripcion character varying DEFAULT NULL::character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE proveedores SET
    name                            = p_name,
    legal_name                      = p_legal_name,
    tipo_id                         = p_tipo_id,
    tax_id                          = p_tax_id,
    email                           = p_email,
    phone                           = p_phone,
    address                         = p_address,
    notes                           = p_notes,
    is_active                       = p_is_active,
    actividad_economica_codigo      = p_actividad_economica_codigo,
    actividad_economica_descripcion = p_actividad_economica_descripcion,
    updated_at                      = NOW()
  WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
  RETURN FOUND;
END;
$$;


--
-- Name: sp_reporte_documentos_estado(bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_documentos_estado(p_empresa_id bigint, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date) RETURNS TABLE(estado character varying, tipo_documento character varying, tipo_label character varying, cantidad bigint, total_comprobante numeric)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    d.estado,
                    d.tipo_documento,
                    CASE d.tipo_documento
                        WHEN '01' THEN 'Factura Electrónica'
                        WHEN '02' THEN 'Nota de Débito'
                        WHEN '03' THEN 'Nota de Crédito'
                        WHEN '04' THEN 'Tiquete Electrónico'
                        WHEN '08' THEN 'Factura de Compra'
                        WHEN '09' THEN 'Factura de Exportación'
                        WHEN '10' THEN 'Recibo Electrónico de Pago'
                        ELSE 'Otro (' || d.tipo_documento || ')'
                    END::VARCHAR                 AS tipo_label,
                    COUNT(*)::BIGINT             AS cantidad,
                    SUM(d.total_comprobante)     AS total_comprobante
                FROM documentos_electronicos d
                WHERE d.empresa_id  = p_empresa_id
                  AND d.deleted_at  IS NULL
                  AND (p_fecha_desde IS NULL OR d.fecha_emision::DATE >= p_fecha_desde)
                  AND (p_fecha_hasta IS NULL OR d.fecha_emision::DATE <= p_fecha_hasta)
                GROUP BY d.estado, d.tipo_documento
                ORDER BY d.estado, d.tipo_documento;
            END;
            $$;


--
-- Name: sp_reporte_facturas_recibidas_resumen(bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_facturas_recibidas_resumen(p_empresa_id bigint, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date) RETURNS TABLE(estado_recepcion character varying, estado_hacienda character varying, cantidad bigint, total_comprobante numeric, total_impuesto numeric)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    f.estado_recepcion,
                    f.estado_hacienda,
                    COUNT(*)::BIGINT         AS cantidad,
                    SUM(f.total_comprobante) AS total_comprobante,
                    SUM(f.total_impuesto)    AS total_impuesto
                FROM facturas_recibidas f
                WHERE f.empresa_id = p_empresa_id
                  AND (p_fecha_desde IS NULL OR f.created_at::DATE >= p_fecha_desde)
                  AND (p_fecha_hasta IS NULL OR f.created_at::DATE <= p_fecha_hasta)
                GROUP BY f.estado_recepcion, f.estado_hacienda
                ORDER BY f.estado_recepcion;
            END;
            $$;


--
-- Name: sp_reporte_inventario(bigint, bigint, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_inventario(p_empresa_id bigint, p_bodega_id bigint DEFAULT NULL::bigint, p_bajo_minimo boolean DEFAULT false, p_search text DEFAULT NULL::text) RETURNS TABLE(bodega_id bigint, bodega_nombre character varying, producto_id bigint, codigo character varying, nombre character varying, categoria character varying, unidad_medida character varying, precio numeric, stock numeric, stock_min numeric, bajo_minimo boolean)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    b.id                 AS bodega_id,
                    b.name               AS bodega_nombre,
                    p.id                 AS producto_id,
                    p.code               AS codigo,
                    p.name               AS nombre,
                    COALESCE(c.name, '') AS categoria,
                    COALESCE(p.unit_measure, '') AS unidad_medida,
                    COALESCE(p.price, 0) AS precio,
                    COALESCE(bp.stock, 0) AS stock,
                    COALESCE(bp.stock_min, 0) AS stock_min,
                    (COALESCE(bp.stock, 0) < COALESCE(bp.stock_min, 0) AND bp.stock_min > 0) AS bajo_minimo
                FROM bodegas b
                JOIN bodega_productos bp ON bp.bodega_id = b.id
                JOIN productos p         ON p.id = bp.producto_id
                LEFT JOIN categorias_producto c ON c.id = p.categoria_id
                WHERE b.empresa_id  = p_empresa_id
                  AND p.empresa_id  = p_empresa_id
                  AND p.type        = 'product'
                  AND (p_bodega_id IS NULL OR b.id = p_bodega_id)
                  AND (NOT p_bajo_minimo OR (bp.stock < bp.stock_min AND bp.stock_min > 0))
                  AND (
                    p_search IS NULL OR p_search = ''
                    OR p.name ILIKE '%' || p_search || '%'
                    OR p.code ILIKE '%' || p_search || '%'
                  )
                ORDER BY b.name, p.name;
            END;
            $$;


--
-- Name: sp_reporte_inventario_summary(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_inventario_summary(p_empresa_id bigint) RETURNS TABLE(bodega_id bigint, bodega_nombre character varying, total_items bigint, bajo_minimo bigint, sin_stock bigint)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    b.id          AS bodega_id,
                    b.name        AS bodega_nombre,
                    COUNT(bp.id)  AS total_items,
                    COUNT(*) FILTER (WHERE bp.stock < bp.stock_min AND bp.stock_min > 0) AS bajo_minimo,
                    COUNT(*) FILTER (WHERE bp.stock <= 0) AS sin_stock
                FROM bodegas b
                JOIN bodega_productos bp ON bp.bodega_id = b.id
                JOIN productos p         ON p.id = bp.producto_id
                                       AND p.empresa_id = p_empresa_id
                                       AND p.type = 'product'
                WHERE b.empresa_id = p_empresa_id
                GROUP BY b.id, b.name
                ORDER BY b.name;
            END;
            $$;


--
-- Name: sp_reporte_libro_ventas(bigint, date, date, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_libro_ventas(p_empresa_id bigint, p_fecha_desde date, p_fecha_hasta date, p_tipo_documento character varying DEFAULT NULL::character varying, p_estado character varying DEFAULT NULL::character varying) RETURNS TABLE(id bigint, fecha_emision timestamp without time zone, tipo_documento character varying, tipo_label character varying, numero_consecutivo character varying, clave character varying, receptor_nombre character varying, receptor_numero_id character varying, moneda character varying, total_venta_neta numeric, total_impuesto numeric, total_comprobante numeric, estado character varying)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    d.id,
                    d.fecha_emision,
                    d.tipo_documento,
                    CASE d.tipo_documento
                        WHEN '01' THEN 'Factura Electrónica'
                        WHEN '02' THEN 'Nota de Débito'
                        WHEN '03' THEN 'Nota de Crédito'
                        WHEN '04' THEN 'Tiquete Electrónico'
                        WHEN '08' THEN 'Factura de Compra'
                        WHEN '09' THEN 'Factura de Exportación'
                        WHEN '10' THEN 'Recibo Electrónico de Pago'
                        ELSE 'Otro (' || d.tipo_documento || ')'
                    END::VARCHAR                                               AS tipo_label,
                    d.numero_consecutivo,
                    d.clave,
                    COALESCE(d.receptor_nombre,    'Consumidor Final')::VARCHAR AS receptor_nombre,
                    COALESCE(d.receptor_numero_id, '—')::VARCHAR                AS receptor_numero_id,
                    d.moneda,
                    d.total_venta_neta,
                    d.total_impuesto,
                    d.total_comprobante,
                    d.estado
                FROM documentos_electronicos d
                WHERE d.empresa_id  = p_empresa_id
                  AND d.deleted_at  IS NULL
                  AND d.fecha_emision::DATE BETWEEN p_fecha_desde AND p_fecha_hasta
                  AND (p_tipo_documento IS NULL OR d.tipo_documento = p_tipo_documento)
                  AND (p_estado         IS NULL OR d.estado         = p_estado)
                ORDER BY d.fecha_emision DESC;
            END;
            $$;


--
-- Name: sp_reporte_ranking_clientes(bigint, date, date, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_ranking_clientes(p_empresa_id bigint, p_fecha_desde date, p_fecha_hasta date, p_limit integer DEFAULT 20) RETURNS TABLE(posicion bigint, receptor_nombre character varying, receptor_numero_id character varying, cantidad_docs bigint, total_venta_neta numeric, total_impuesto numeric, total_comprobante numeric)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    ROW_NUMBER() OVER (ORDER BY SUM(d.total_comprobante) DESC)::BIGINT AS posicion,
                    COALESCE(d.receptor_nombre,    'Consumidor Final')::VARCHAR AS receptor_nombre,
                    COALESCE(d.receptor_numero_id, '—')::VARCHAR                AS receptor_numero_id,
                    COUNT(*)::BIGINT              AS cantidad_docs,
                    SUM(d.total_venta_neta)       AS total_venta_neta,
                    SUM(d.total_impuesto)         AS total_impuesto,
                    SUM(d.total_comprobante)      AS total_comprobante
                FROM documentos_electronicos d
                WHERE d.empresa_id  = p_empresa_id
                  AND d.estado      = 'aceptado'
                  AND d.deleted_at  IS NULL
                  AND d.fecha_emision::DATE BETWEEN p_fecha_desde AND p_fecha_hasta
                GROUP BY d.receptor_nombre, d.receptor_numero_id
                ORDER BY SUM(d.total_comprobante) DESC
                LIMIT p_limit;
            END;
            $$;


--
-- Name: sp_reporte_ventas_periodo(bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_ventas_periodo(p_empresa_id bigint, p_fecha_desde date, p_fecha_hasta date) RETURNS TABLE(tipo_documento character varying, tipo_label character varying, cantidad bigint, total_venta_neta numeric, total_impuesto numeric, total_comprobante numeric)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    d.tipo_documento,
                    CASE d.tipo_documento
                        WHEN '01' THEN 'Factura Electrónica'
                        WHEN '02' THEN 'Nota de Débito'
                        WHEN '03' THEN 'Nota de Crédito'
                        WHEN '04' THEN 'Tiquete Electrónico'
                        WHEN '08' THEN 'Factura de Compra'
                        WHEN '09' THEN 'Factura de Exportación'
                        WHEN '10' THEN 'Recibo Electrónico de Pago'
                        ELSE 'Otro (' || d.tipo_documento || ')'
                    END::VARCHAR                  AS tipo_label,
                    COUNT(*)::BIGINT              AS cantidad,
                    SUM(d.total_venta_neta)       AS total_venta_neta,
                    SUM(d.total_impuesto)         AS total_impuesto,
                    SUM(d.total_comprobante)      AS total_comprobante
                FROM documentos_electronicos d
                WHERE d.empresa_id  = p_empresa_id
                  AND d.estado      = 'aceptado'
                  AND d.deleted_at  IS NULL
                  AND d.fecha_emision::DATE BETWEEN p_fecha_desde AND p_fecha_hasta
                GROUP BY d.tipo_documento
                ORDER BY SUM(d.total_comprobante) DESC;
            END;
            $$;


--
-- Name: bodega_productos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bodega_productos (
    id bigint NOT NULL,
    bodega_id bigint NOT NULL,
    producto_id bigint NOT NULL,
    stock numeric(15,4) DEFAULT 0 NOT NULL,
    stock_min numeric(15,4) DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: bodega_productos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bodega_productos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'bodega_productos'::character varying NOT NULL,
    operacion character varying(10) NOT NULL,
    registro_id bigint NOT NULL,
    datos_antes jsonb,
    datos_despues jsonb,
    usuario_bd character varying(100) DEFAULT CURRENT_USER NOT NULL,
    app_user_id bigint,
    ip_address character varying(45),
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: bodega_productos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bodega_productos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bodega_productos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bodega_productos_auditoria_id_seq OWNED BY public.bodega_productos_auditoria.id;


--
-- Name: bodega_productos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bodega_productos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bodega_productos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bodega_productos_id_seq OWNED BY public.bodega_productos.id;


--
-- Name: bodegas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bodegas (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    is_default boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    permite_stock_negativo boolean DEFAULT false NOT NULL
);


--
-- Name: bodegas_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bodegas_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'bodegas'::character varying NOT NULL,
    operacion character varying(10) NOT NULL,
    registro_id bigint NOT NULL,
    datos_antes jsonb,
    datos_despues jsonb,
    usuario_bd character varying(100) DEFAULT CURRENT_USER NOT NULL,
    app_user_id bigint,
    ip_address character varying(45),
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: bodegas_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bodegas_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bodegas_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bodegas_auditoria_id_seq OWNED BY public.bodegas_auditoria.id;


--
-- Name: bodegas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bodegas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bodegas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bodegas_id_seq OWNED BY public.bodegas.id;


--
-- Name: categorias_producto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categorias_producto (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    name character varying(100) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: categorias_producto_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categorias_producto_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'categorias_producto'::character varying NOT NULL,
    operacion character varying(10) NOT NULL,
    registro_id bigint NOT NULL,
    datos_antes jsonb,
    datos_despues jsonb,
    usuario_bd character varying(100) DEFAULT CURRENT_USER NOT NULL,
    app_user_id bigint,
    ip_address character varying(45),
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: categorias_producto_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.categorias_producto_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: categorias_producto_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.categorias_producto_auditoria_id_seq OWNED BY public.categorias_producto_auditoria.id;


--
-- Name: categorias_producto_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.categorias_producto_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: categorias_producto_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.categorias_producto_id_seq OWNED BY public.categorias_producto.id;


--
-- Name: clientes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clientes (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    legal_name character varying(255),
    tax_id character varying(50),
    email character varying(255),
    phone character varying(50),
    address text,
    birth_date date,
    notes text,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: clientes_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clientes_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'clientes'::character varying NOT NULL,
    operacion character varying(10) NOT NULL,
    registro_id bigint NOT NULL,
    datos_antes jsonb,
    datos_despues jsonb,
    usuario_bd character varying(100) DEFAULT CURRENT_USER NOT NULL,
    app_user_id bigint,
    ip_address character varying(45),
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: clientes_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.clientes_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: clientes_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.clientes_auditoria_id_seq OWNED BY public.clientes_auditoria.id;


--
-- Name: clientes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.clientes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: clientes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.clientes_id_seq OWNED BY public.clientes.id;


--
-- Name: clients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clients (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    legal_name character varying(255),
    tax_id character varying(50),
    email character varying(255),
    phone character varying(50),
    address text,
    notes text,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    tax_id_type character varying(2),
    actividad_economica_codigo character varying(20),
    actividad_economica_descripcion character varying(255),
    birth_date date
);


--
-- Name: clients_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clients_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'clients'::character varying NOT NULL,
    operacion character varying(10) NOT NULL,
    registro_id bigint NOT NULL,
    datos_antes jsonb,
    datos_despues jsonb,
    usuario_bd character varying(100) DEFAULT CURRENT_USER NOT NULL,
    app_user_id bigint,
    ip_address character varying(45),
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT clients_auditoria_operacion_check CHECK (((operacion)::text = ANY ((ARRAY['INSERT'::character varying, 'UPDATE'::character varying, 'DELETE'::character varying])::text[])))
);


--
-- Name: clients_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.clients_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: clients_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.clients_auditoria_id_seq OWNED BY public.clients_auditoria.id;


--
-- Name: clients_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.clients_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: clients_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.clients_id_seq OWNED BY public.clients.id;


--
-- Name: company_settings_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.company_settings_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'company_settings'::character varying NOT NULL,
    operacion character varying(10) NOT NULL,
    registro_id bigint NOT NULL,
    datos_antes jsonb,
    datos_despues jsonb,
    usuario_bd character varying(100) DEFAULT CURRENT_USER NOT NULL,
    app_user_id bigint,
    ip_address character varying(45),
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: company_settings_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.company_settings_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: company_settings_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.company_settings_auditoria_id_seq OWNED BY public.company_settings_auditoria.id;


--
-- Name: company_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.company_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: company_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.company_settings_id_seq OWNED BY public.company_settings.id;


--
-- Name: compras_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.compras_items (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    tipo character varying(1) DEFAULT 'S'::character varying NOT NULL,
    descripcion character varying(255) NOT NULL,
    cabys_codigo character varying(20),
    unidad_medida character varying(20) DEFAULT 'Unid'::character varying,
    precio_default numeric(18,5) DEFAULT 0,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    deleted_at timestamp without time zone,
    CONSTRAINT compras_items_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['P'::character varying, 'S'::character varying])::text[])))
);


--
-- Name: compras_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.compras_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: compras_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.compras_items_id_seq OWNED BY public.compras_items.id;


--
-- Name: documento_consecutivos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_consecutivos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    sucursal_id bigint NOT NULL,
    tipo_documento character varying(2) NOT NULL,
    ultimo_consecutivo bigint DEFAULT 0 NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: documento_consecutivos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_consecutivos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_consecutivos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documento_consecutivos_id_seq OWNED BY public.documento_consecutivos.id;


--
-- Name: documento_desglose_impuesto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_desglose_impuesto (
    id bigint NOT NULL,
    documento_id bigint NOT NULL,
    codigo character varying(2) NOT NULL,
    codigo_tarifa_iva character varying(2),
    total_monto_impuesto numeric(18,5) NOT NULL
);


--
-- Name: documento_desglose_impuesto_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_desglose_impuesto_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_desglose_impuesto_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documento_desglose_impuesto_id_seq OWNED BY public.documento_desglose_impuesto.id;


--
-- Name: documento_linea_descuentos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_linea_descuentos (
    id bigint NOT NULL,
    linea_id bigint NOT NULL,
    monto_descuento numeric(18,5) NOT NULL,
    codigo_descuento character varying(2) NOT NULL,
    codigo_descuento_otro character varying(2),
    naturaleza_descuento text
);


--
-- Name: documento_linea_descuentos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_linea_descuentos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_linea_descuentos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documento_linea_descuentos_id_seq OWNED BY public.documento_linea_descuentos.id;


--
-- Name: documento_linea_impuestos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_linea_impuestos (
    id bigint NOT NULL,
    linea_id bigint NOT NULL,
    codigo character varying(2) NOT NULL,
    codigo_impuesto_otro character varying(2),
    codigo_tarifa_iva character varying(2),
    tarifa numeric(6,2),
    factor_calculo_iva numeric(10,5) DEFAULT 0 NOT NULL,
    monto numeric(18,5) NOT NULL,
    ie_cantidad_unidad_medida character varying(10),
    ie_porcentaje numeric(10,5),
    ie_proporcion numeric(10,5),
    ie_volumen_unidad_consumo numeric(10,5),
    ie_impuesto_unidad numeric(18,5),
    ex_tipo_documento character varying(2),
    ex_tipo_documento_otro character varying(2),
    ex_numero_documento text,
    ex_articulo character varying(10),
    ex_inciso character varying(5),
    ex_nombre_institucion character varying(5),
    ex_nombre_institucion_otros character varying(100),
    ex_fecha_emision timestamp without time zone,
    ex_tarifa_exonerada numeric(6,2),
    ex_monto_exoneracion numeric(18,5)
);


--
-- Name: documento_linea_impuestos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_linea_impuestos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_linea_impuestos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documento_linea_impuestos_id_seq OWNED BY public.documento_linea_impuestos.id;


--
-- Name: documento_linea_surtidos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_linea_surtidos (
    id bigint NOT NULL,
    linea_id bigint NOT NULL,
    numero_linea_surtido smallint,
    bodega_surtido bigint,
    producto_id_surtido bigint,
    cabys_surtido character varying(13) NOT NULL,
    cantidad_surtido numeric(16,3) NOT NULL,
    unidad_medida_surtido character varying(5) NOT NULL,
    unidad_medida_comercial_surtido character varying(20),
    detalle_surtido text NOT NULL,
    precio_unitario_surtido numeric(18,5) NOT NULL,
    monto_total_surtido numeric(18,5) NOT NULL,
    subtotal_surtido numeric(18,5) NOT NULL,
    iva_cobrado_fabrica_surtido numeric(18,5) DEFAULT 0 NOT NULL,
    base_imponible_surtido numeric(18,5) NOT NULL,
    codigos_comerciales_surtido jsonb,
    descuentos_surtido jsonb,
    impuestos_surtido jsonb
);


--
-- Name: documento_linea_surtidos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_linea_surtidos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_linea_surtidos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documento_linea_surtidos_id_seq OWNED BY public.documento_linea_surtidos.id;


--
-- Name: documento_lineas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_lineas (
    id bigint NOT NULL,
    documento_id bigint NOT NULL,
    numero_linea smallint NOT NULL,
    bodega_id bigint,
    funcionario character varying(100),
    producto_id bigint,
    codigo_actividad character varying(10),
    cabys_code character varying(13) NOT NULL,
    cantidad numeric(16,3) NOT NULL,
    unidad_medida character varying(5) NOT NULL,
    tipo_unidad boolean,
    tipo_transaccion character varying(2),
    unidad_medida_comercial character varying(20),
    detalle text NOT NULL,
    registro_medicamento character varying(50),
    forma_farmaceutica character varying(10),
    precio_unitario numeric(18,5) NOT NULL,
    monto_total numeric(18,5) NOT NULL,
    subtotal numeric(18,5) NOT NULL,
    iva_cobrado_fabrica numeric(18,5) DEFAULT 0 NOT NULL,
    base_imponible numeric(18,5) NOT NULL,
    impuesto_asumido_emisor numeric(18,5) DEFAULT 0 NOT NULL,
    impuesto_neto numeric(18,5) DEFAULT 0 NOT NULL,
    monto_total_linea numeric(18,5) NOT NULL,
    codigos_comerciales jsonb,
    numeros_serie jsonb,
    funcionario_id bigint
);


--
-- Name: documento_lineas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_lineas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_lineas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documento_lineas_id_seq OWNED BY public.documento_lineas.id;


--
-- Name: documento_medios_pago; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_medios_pago (
    id bigint NOT NULL,
    documento_id bigint NOT NULL,
    tipo_medio_pago character varying(2) NOT NULL,
    medio_pago_otros character varying(2),
    total_medio_pago numeric(18,5) NOT NULL,
    id_tipo_pago bigint,
    tipo_pago character varying(100),
    referencia character varying(100),
    autorizado character varying(100),
    porc_comi_banca numeric(6,2) DEFAULT 0 NOT NULL,
    porc_reten_iva numeric(6,2) DEFAULT 0 NOT NULL,
    porc_reten_renta numeric(6,2) DEFAULT 0 NOT NULL,
    monto_vuelto numeric(18,5) DEFAULT 0 NOT NULL
);


--
-- Name: documento_medios_pago_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_medios_pago_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_medios_pago_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documento_medios_pago_id_seq OWNED BY public.documento_medios_pago.id;


--
-- Name: documento_otros_cargos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_otros_cargos (
    id bigint NOT NULL,
    documento_id bigint NOT NULL,
    tipo_documento_oc character varying(2) NOT NULL,
    tipo_documento_otros character varying(2),
    identificacion_tipo character varying(2),
    identificacion_numero character varying(20),
    nombre_tercero character varying(255),
    detalle text NOT NULL,
    porcentaje numeric(10,5),
    monto_cargo numeric(18,5) NOT NULL
);


--
-- Name: documento_otros_cargos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_otros_cargos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_otros_cargos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documento_otros_cargos_id_seq OWNED BY public.documento_otros_cargos.id;


--
-- Name: documento_referencias; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_referencias (
    id bigint NOT NULL,
    documento_id bigint NOT NULL,
    tipo_doc_ir character varying(2) NOT NULL,
    tipo_doc_ref_otro character varying(2),
    numero character varying(50) NOT NULL,
    fecha_emision_ir timestamp without time zone NOT NULL,
    codigo character varying(2) NOT NULL,
    codigo_referencia_otro character varying(2),
    razon text
);


--
-- Name: documento_referencias_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_referencias_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_referencias_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documento_referencias_id_seq OWNED BY public.documento_referencias.id;


--
-- Name: documentos_electronicos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documentos_electronicos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'documentos_electronicos'::character varying NOT NULL,
    operacion character varying(10) NOT NULL,
    registro_id bigint NOT NULL,
    datos_antes jsonb,
    datos_despues jsonb,
    usuario_bd character varying(100) DEFAULT CURRENT_USER NOT NULL,
    app_user_id bigint,
    ip_address character varying(45),
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: documentos_electronicos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documentos_electronicos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documentos_electronicos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documentos_electronicos_auditoria_id_seq OWNED BY public.documentos_electronicos_auditoria.id;


--
-- Name: documentos_electronicos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documentos_electronicos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documentos_electronicos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documentos_electronicos_id_seq OWNED BY public.documentos_electronicos.id;


--
-- Name: empresa_condicion_ventas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_condicion_ventas (
    id integer NOT NULL,
    empresa_id integer NOT NULL,
    codigo character varying(5) NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    es_default boolean DEFAULT false NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: empresa_condicion_ventas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_condicion_ventas_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_condicion_ventas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_condicion_ventas_id_seq OWNED BY public.empresa_condicion_ventas.id;


--
-- Name: empresa_hacienda_config_bitacora; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_hacienda_config_bitacora (
    id bigint NOT NULL,
    operacion character varying(10) NOT NULL,
    empresa_id bigint,
    campo character varying(100),
    valor_antes text,
    valor_despues text,
    usuario text,
    ip inet,
    created_at timestamp without time zone DEFAULT now()
);


--
-- Name: empresa_hacienda_config_bitacora_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_hacienda_config_bitacora_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_hacienda_config_bitacora_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_hacienda_config_bitacora_id_seq OWNED BY public.empresa_hacienda_config_bitacora.id;


--
-- Name: empresa_hacienda_config_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_hacienda_config_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_hacienda_config_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_hacienda_config_id_seq OWNED BY public.empresa_hacienda_config.id;


--
-- Name: empresa_medios_pago; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_medios_pago (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    nombre character varying(100) NOT NULL,
    tipo_hacienda_codigo character varying(2) NOT NULL,
    tipo_hacienda_nombre character varying(100),
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    deleted_at timestamp without time zone,
    orden integer DEFAULT 0 NOT NULL
);


--
-- Name: empresa_medios_pago_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_medios_pago_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_medios_pago_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_medios_pago_id_seq OWNED BY public.empresa_medios_pago.id;


--
-- Name: empresa_monedas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_monedas (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    codigo character varying(3) NOT NULL,
    nombre character varying(100) NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: empresa_monedas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_monedas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_monedas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_monedas_id_seq OWNED BY public.empresa_monedas.id;


--
-- Name: facturas_recibidas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.facturas_recibidas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: facturas_recibidas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.facturas_recibidas_id_seq OWNED BY public.facturas_recibidas.id;


--
-- Name: funcionarios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.funcionarios (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    tax_id character varying(50),
    email character varying(255),
    phone character varying(50),
    address text,
    birth_date date,
    commission_pct numeric(5,2) DEFAULT 0.00 NOT NULL,
    notes text,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    is_default boolean DEFAULT false NOT NULL
);


--
-- Name: funcionarios_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.funcionarios_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'funcionarios'::character varying NOT NULL,
    operacion character varying(10) NOT NULL,
    registro_id bigint NOT NULL,
    datos_antes jsonb,
    datos_despues jsonb,
    usuario_bd character varying(100) DEFAULT CURRENT_USER NOT NULL,
    app_user_id bigint,
    ip_address character varying(45),
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: funcionarios_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.funcionarios_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: funcionarios_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.funcionarios_auditoria_id_seq OWNED BY public.funcionarios_auditoria.id;


--
-- Name: funcionarios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.funcionarios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: funcionarios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.funcionarios_id_seq OWNED BY public.funcionarios.id;


--
-- Name: migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.migrations (
    id integer NOT NULL,
    migration character varying(255) NOT NULL,
    batch integer NOT NULL
);


--
-- Name: migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.migrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: migrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.migrations_id_seq OWNED BY public.migrations.id;


--
-- Name: productos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.productos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    categoria_id bigint,
    code character varying(50) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    type character varying(10) DEFAULT 'product'::character varying NOT NULL,
    unit_measure character varying(20) DEFAULT 'Unid'::character varying NOT NULL,
    cabys_code character varying(13),
    price numeric(15,5) DEFAULT 0 NOT NULL,
    tax_type character varying(30) DEFAULT 'IVA'::character varying NOT NULL,
    tax_code character varying(2) DEFAULT '01'::character varying NOT NULL,
    tax_rate numeric(5,2) DEFAULT 13.00 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    image_url text,
    image_public_id character varying(255),
    CONSTRAINT productos_type_check CHECK (((type)::text = ANY ((ARRAY['product'::character varying, 'service'::character varying])::text[])))
);


--
-- Name: productos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.productos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'productos'::character varying NOT NULL,
    operacion character varying(10) NOT NULL,
    registro_id bigint NOT NULL,
    datos_antes jsonb,
    datos_despues jsonb,
    usuario_bd character varying(100) DEFAULT CURRENT_USER NOT NULL,
    app_user_id bigint,
    ip_address character varying(45),
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: productos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.productos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: productos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.productos_auditoria_id_seq OWNED BY public.productos_auditoria.id;


--
-- Name: productos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.productos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: productos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.productos_id_seq OWNED BY public.productos.id;


--
-- Name: proveedores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.proveedores (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    legal_name character varying(255),
    tipo_id character varying(2),
    tax_id character varying(20),
    email character varying(255),
    phone character varying(30),
    address text,
    notes text,
    is_active boolean DEFAULT true,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    actividad_economica_codigo character varying(20),
    actividad_economica_descripcion character varying(255)
);


--
-- Name: proveedores_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.proveedores_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: proveedores_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.proveedores_id_seq OWNED BY public.proveedores.id;


--
-- Name: bodega_productos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodega_productos ALTER COLUMN id SET DEFAULT nextval('public.bodega_productos_id_seq'::regclass);


--
-- Name: bodega_productos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodega_productos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.bodega_productos_auditoria_id_seq'::regclass);


--
-- Name: bodegas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodegas ALTER COLUMN id SET DEFAULT nextval('public.bodegas_id_seq'::regclass);


--
-- Name: bodegas_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodegas_auditoria ALTER COLUMN id SET DEFAULT nextval('public.bodegas_auditoria_id_seq'::regclass);


--
-- Name: categorias_producto id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorias_producto ALTER COLUMN id SET DEFAULT nextval('public.categorias_producto_id_seq'::regclass);


--
-- Name: categorias_producto_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorias_producto_auditoria ALTER COLUMN id SET DEFAULT nextval('public.categorias_producto_auditoria_id_seq'::regclass);


--
-- Name: clientes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clientes ALTER COLUMN id SET DEFAULT nextval('public.clientes_id_seq'::regclass);


--
-- Name: clientes_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clientes_auditoria ALTER COLUMN id SET DEFAULT nextval('public.clientes_auditoria_id_seq'::regclass);


--
-- Name: clients id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients ALTER COLUMN id SET DEFAULT nextval('public.clients_id_seq'::regclass);


--
-- Name: clients_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients_auditoria ALTER COLUMN id SET DEFAULT nextval('public.clients_auditoria_id_seq'::regclass);


--
-- Name: company_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_settings ALTER COLUMN id SET DEFAULT nextval('public.company_settings_id_seq'::regclass);


--
-- Name: company_settings_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_settings_auditoria ALTER COLUMN id SET DEFAULT nextval('public.company_settings_auditoria_id_seq'::regclass);


--
-- Name: compras_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.compras_items ALTER COLUMN id SET DEFAULT nextval('public.compras_items_id_seq'::regclass);


--
-- Name: documento_consecutivos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_consecutivos ALTER COLUMN id SET DEFAULT nextval('public.documento_consecutivos_id_seq'::regclass);


--
-- Name: documento_desglose_impuesto id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_desglose_impuesto ALTER COLUMN id SET DEFAULT nextval('public.documento_desglose_impuesto_id_seq'::regclass);


--
-- Name: documento_linea_descuentos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_linea_descuentos ALTER COLUMN id SET DEFAULT nextval('public.documento_linea_descuentos_id_seq'::regclass);


--
-- Name: documento_linea_impuestos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_linea_impuestos ALTER COLUMN id SET DEFAULT nextval('public.documento_linea_impuestos_id_seq'::regclass);


--
-- Name: documento_linea_surtidos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_linea_surtidos ALTER COLUMN id SET DEFAULT nextval('public.documento_linea_surtidos_id_seq'::regclass);


--
-- Name: documento_lineas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_lineas ALTER COLUMN id SET DEFAULT nextval('public.documento_lineas_id_seq'::regclass);


--
-- Name: documento_medios_pago id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_medios_pago ALTER COLUMN id SET DEFAULT nextval('public.documento_medios_pago_id_seq'::regclass);


--
-- Name: documento_otros_cargos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_otros_cargos ALTER COLUMN id SET DEFAULT nextval('public.documento_otros_cargos_id_seq'::regclass);


--
-- Name: documento_referencias id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_referencias ALTER COLUMN id SET DEFAULT nextval('public.documento_referencias_id_seq'::regclass);


--
-- Name: documentos_electronicos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documentos_electronicos ALTER COLUMN id SET DEFAULT nextval('public.documentos_electronicos_id_seq'::regclass);


--
-- Name: documentos_electronicos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documentos_electronicos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.documentos_electronicos_auditoria_id_seq'::regclass);


--
-- Name: empresa_condicion_ventas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_condicion_ventas ALTER COLUMN id SET DEFAULT nextval('public.empresa_condicion_ventas_id_seq'::regclass);


--
-- Name: empresa_hacienda_config id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_hacienda_config ALTER COLUMN id SET DEFAULT nextval('public.empresa_hacienda_config_id_seq'::regclass);


--
-- Name: empresa_hacienda_config_bitacora id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_hacienda_config_bitacora ALTER COLUMN id SET DEFAULT nextval('public.empresa_hacienda_config_bitacora_id_seq'::regclass);


--
-- Name: empresa_medios_pago id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_medios_pago ALTER COLUMN id SET DEFAULT nextval('public.empresa_medios_pago_id_seq'::regclass);


--
-- Name: empresa_monedas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_monedas ALTER COLUMN id SET DEFAULT nextval('public.empresa_monedas_id_seq'::regclass);


--
-- Name: facturas_recibidas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facturas_recibidas ALTER COLUMN id SET DEFAULT nextval('public.facturas_recibidas_id_seq'::regclass);


--
-- Name: funcionarios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionarios ALTER COLUMN id SET DEFAULT nextval('public.funcionarios_id_seq'::regclass);


--
-- Name: funcionarios_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionarios_auditoria ALTER COLUMN id SET DEFAULT nextval('public.funcionarios_auditoria_id_seq'::regclass);


--
-- Name: migrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.migrations ALTER COLUMN id SET DEFAULT nextval('public.migrations_id_seq'::regclass);


--
-- Name: productos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos ALTER COLUMN id SET DEFAULT nextval('public.productos_id_seq'::regclass);


--
-- Name: productos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.productos_auditoria_id_seq'::regclass);


--
-- Name: proveedores id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proveedores ALTER COLUMN id SET DEFAULT nextval('public.proveedores_id_seq'::regclass);


--
-- Name: bodega_productos_auditoria bodega_productos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodega_productos_auditoria
    ADD CONSTRAINT bodega_productos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: bodega_productos bodega_productos_bodega_id_producto_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodega_productos
    ADD CONSTRAINT bodega_productos_bodega_id_producto_id_key UNIQUE (bodega_id, producto_id);


--
-- Name: bodega_productos bodega_productos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodega_productos
    ADD CONSTRAINT bodega_productos_pkey PRIMARY KEY (id);


--
-- Name: bodegas_auditoria bodegas_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodegas_auditoria
    ADD CONSTRAINT bodegas_auditoria_pkey PRIMARY KEY (id);


--
-- Name: bodegas bodegas_empresa_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodegas
    ADD CONSTRAINT bodegas_empresa_id_name_key UNIQUE (empresa_id, name);


--
-- Name: bodegas bodegas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodegas
    ADD CONSTRAINT bodegas_pkey PRIMARY KEY (id);


--
-- Name: categorias_producto_auditoria categorias_producto_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorias_producto_auditoria
    ADD CONSTRAINT categorias_producto_auditoria_pkey PRIMARY KEY (id);


--
-- Name: categorias_producto categorias_producto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorias_producto
    ADD CONSTRAINT categorias_producto_pkey PRIMARY KEY (id);


--
-- Name: clientes_auditoria clientes_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clientes_auditoria
    ADD CONSTRAINT clientes_auditoria_pkey PRIMARY KEY (id);


--
-- Name: clientes clientes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clientes
    ADD CONSTRAINT clientes_pkey PRIMARY KEY (id);


--
-- Name: clients_auditoria clients_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients_auditoria
    ADD CONSTRAINT clients_auditoria_pkey PRIMARY KEY (id);


--
-- Name: clients clients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_pkey PRIMARY KEY (id);


--
-- Name: company_settings_auditoria company_settings_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_settings_auditoria
    ADD CONSTRAINT company_settings_auditoria_pkey PRIMARY KEY (id);


--
-- Name: company_settings company_settings_empresa_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_settings
    ADD CONSTRAINT company_settings_empresa_id_key UNIQUE (empresa_id);


--
-- Name: company_settings company_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.company_settings
    ADD CONSTRAINT company_settings_pkey PRIMARY KEY (id);


--
-- Name: compras_items compras_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.compras_items
    ADD CONSTRAINT compras_items_pkey PRIMARY KEY (id);


--
-- Name: documento_consecutivos documento_consecutivos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_consecutivos
    ADD CONSTRAINT documento_consecutivos_pkey PRIMARY KEY (id);


--
-- Name: documento_desglose_impuesto documento_desglose_impuesto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_desglose_impuesto
    ADD CONSTRAINT documento_desglose_impuesto_pkey PRIMARY KEY (id);


--
-- Name: documento_linea_descuentos documento_linea_descuentos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_linea_descuentos
    ADD CONSTRAINT documento_linea_descuentos_pkey PRIMARY KEY (id);


--
-- Name: documento_linea_impuestos documento_linea_impuestos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_linea_impuestos
    ADD CONSTRAINT documento_linea_impuestos_pkey PRIMARY KEY (id);


--
-- Name: documento_linea_surtidos documento_linea_surtidos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_linea_surtidos
    ADD CONSTRAINT documento_linea_surtidos_pkey PRIMARY KEY (id);


--
-- Name: documento_lineas documento_lineas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_lineas
    ADD CONSTRAINT documento_lineas_pkey PRIMARY KEY (id);


--
-- Name: documento_medios_pago documento_medios_pago_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_medios_pago
    ADD CONSTRAINT documento_medios_pago_pkey PRIMARY KEY (id);


--
-- Name: documento_otros_cargos documento_otros_cargos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_otros_cargos
    ADD CONSTRAINT documento_otros_cargos_pkey PRIMARY KEY (id);


--
-- Name: documento_referencias documento_referencias_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_referencias
    ADD CONSTRAINT documento_referencias_pkey PRIMARY KEY (id);


--
-- Name: documentos_electronicos_auditoria documentos_electronicos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documentos_electronicos_auditoria
    ADD CONSTRAINT documentos_electronicos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: documentos_electronicos documentos_electronicos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documentos_electronicos
    ADD CONSTRAINT documentos_electronicos_pkey PRIMARY KEY (id);


--
-- Name: empresa_condicion_ventas empresa_condicion_ventas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_condicion_ventas
    ADD CONSTRAINT empresa_condicion_ventas_pkey PRIMARY KEY (id);


--
-- Name: empresa_hacienda_config_bitacora empresa_hacienda_config_bitacora_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_hacienda_config_bitacora
    ADD CONSTRAINT empresa_hacienda_config_bitacora_pkey PRIMARY KEY (id);


--
-- Name: empresa_hacienda_config empresa_hacienda_config_empresa_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_hacienda_config
    ADD CONSTRAINT empresa_hacienda_config_empresa_id_key UNIQUE (empresa_id);


--
-- Name: empresa_hacienda_config empresa_hacienda_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_hacienda_config
    ADD CONSTRAINT empresa_hacienda_config_pkey PRIMARY KEY (id);


--
-- Name: empresa_medios_pago empresa_medios_pago_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_medios_pago
    ADD CONSTRAINT empresa_medios_pago_pkey PRIMARY KEY (id);


--
-- Name: empresa_monedas empresa_monedas_empresa_id_codigo_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_monedas
    ADD CONSTRAINT empresa_monedas_empresa_id_codigo_key UNIQUE (empresa_id, codigo);


--
-- Name: empresa_monedas empresa_monedas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_monedas
    ADD CONSTRAINT empresa_monedas_pkey PRIMARY KEY (id);


--
-- Name: facturas_recibidas facturas_recibidas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facturas_recibidas
    ADD CONSTRAINT facturas_recibidas_pkey PRIMARY KEY (id);


--
-- Name: funcionarios_auditoria funcionarios_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionarios_auditoria
    ADD CONSTRAINT funcionarios_auditoria_pkey PRIMARY KEY (id);


--
-- Name: funcionarios funcionarios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionarios
    ADD CONSTRAINT funcionarios_pkey PRIMARY KEY (id);


--
-- Name: migrations migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (id);


--
-- Name: productos_auditoria productos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos_auditoria
    ADD CONSTRAINT productos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: productos productos_empresa_id_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_empresa_id_code_key UNIQUE (empresa_id, code);


--
-- Name: productos productos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_pkey PRIMARY KEY (id);


--
-- Name: proveedores proveedores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proveedores
    ADD CONSTRAINT proveedores_pkey PRIMARY KEY (id);


--
-- Name: documento_consecutivos uq_consecutivo; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_consecutivos
    ADD CONSTRAINT uq_consecutivo UNIQUE (empresa_id, sucursal_id, tipo_documento);


--
-- Name: empresa_condicion_ventas uq_empresa_condicion_venta; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_condicion_ventas
    ADD CONSTRAINT uq_empresa_condicion_venta UNIQUE (empresa_id, codigo);


--
-- Name: documento_lineas uq_linea_doc; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_lineas
    ADD CONSTRAINT uq_linea_doc UNIQUE (documento_id, numero_linea);


--
-- Name: idx_documentos_clave; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_documentos_clave ON public.documentos_electronicos USING btree (clave) WHERE (clave IS NOT NULL);


--
-- Name: idx_documentos_empresa_tipo_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documentos_empresa_tipo_estado ON public.documentos_electronicos USING btree (empresa_id, tipo_documento, estado);


--
-- Name: idx_documentos_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documentos_fecha ON public.documentos_electronicos USING btree (empresa_id, fecha_emision DESC);


--
-- Name: idx_emp_medios_pago_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_emp_medios_pago_empresa ON public.empresa_medios_pago USING btree (empresa_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_fr_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fr_empresa ON public.facturas_recibidas USING btree (empresa_id);


--
-- Name: idx_fr_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fr_estado ON public.facturas_recibidas USING btree (estado_recepcion);


--
-- Name: idx_proveedores_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_proveedores_empresa ON public.proveedores USING btree (empresa_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_proveedores_tax_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_proveedores_tax_id ON public.proveedores USING btree (tax_id) WHERE (deleted_at IS NULL);


--
-- Name: uq_fr_clave; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_fr_clave ON public.facturas_recibidas USING btree (empresa_id, clave) WHERE (clave IS NOT NULL);


--
-- Name: bodega_productos trg_bodega_productos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_bodega_productos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.bodega_productos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: bodegas trg_bodegas_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_bodegas_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.bodegas FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: categorias_producto trg_categorias_producto_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_categorias_producto_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.categorias_producto FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: clientes trg_clientes_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_clientes_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.clientes FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: clients trg_clients_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_clients_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.clients FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: company_settings trg_company_settings_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_company_settings_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.company_settings FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: documentos_electronicos trg_documentos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_documentos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.documentos_electronicos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: funcionarios trg_funcionarios_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_funcionarios_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.funcionarios FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: productos trg_productos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_productos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.productos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: bodega_productos bodega_productos_bodega_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodega_productos
    ADD CONSTRAINT bodega_productos_bodega_id_fkey FOREIGN KEY (bodega_id) REFERENCES public.bodegas(id);


--
-- Name: bodega_productos bodega_productos_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bodega_productos
    ADD CONSTRAINT bodega_productos_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);


--
-- Name: documento_desglose_impuesto documento_desglose_impuesto_documento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_desglose_impuesto
    ADD CONSTRAINT documento_desglose_impuesto_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos_electronicos(id) ON DELETE CASCADE;


--
-- Name: documento_linea_descuentos documento_linea_descuentos_linea_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_linea_descuentos
    ADD CONSTRAINT documento_linea_descuentos_linea_id_fkey FOREIGN KEY (linea_id) REFERENCES public.documento_lineas(id) ON DELETE CASCADE;


--
-- Name: documento_linea_impuestos documento_linea_impuestos_linea_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_linea_impuestos
    ADD CONSTRAINT documento_linea_impuestos_linea_id_fkey FOREIGN KEY (linea_id) REFERENCES public.documento_lineas(id) ON DELETE CASCADE;


--
-- Name: documento_linea_surtidos documento_linea_surtidos_linea_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_linea_surtidos
    ADD CONSTRAINT documento_linea_surtidos_linea_id_fkey FOREIGN KEY (linea_id) REFERENCES public.documento_lineas(id) ON DELETE CASCADE;


--
-- Name: documento_lineas documento_lineas_documento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_lineas
    ADD CONSTRAINT documento_lineas_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos_electronicos(id) ON DELETE CASCADE;


--
-- Name: documento_medios_pago documento_medios_pago_documento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_medios_pago
    ADD CONSTRAINT documento_medios_pago_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos_electronicos(id) ON DELETE CASCADE;


--
-- Name: documento_otros_cargos documento_otros_cargos_documento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_otros_cargos
    ADD CONSTRAINT documento_otros_cargos_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos_electronicos(id) ON DELETE CASCADE;


--
-- Name: documento_referencias documento_referencias_documento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_referencias
    ADD CONSTRAINT documento_referencias_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos_electronicos(id) ON DELETE CASCADE;


--
-- Name: productos productos_categoria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_categoria_id_fkey FOREIGN KEY (categoria_id) REFERENCES public.categorias_producto(id);


--
-- PostgreSQL database dump complete
--

