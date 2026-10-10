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
-- Name: unaccent; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;


--
-- Name: EXTENSION unaccent; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION unaccent IS 'text search dictionary that removes accents';


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
-- Name: fn_valida_evento_no_pasado(timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_valida_evento_no_pasado(p_fecha_inicio timestamp without time zone) RETURNS void
    LANGUAGE plpgsql
    AS $$
            BEGIN
                IF p_fecha_inicio IS NOT NULL AND p_fecha_inicio < NOW() THEN
                    RAISE EXCEPTION 'EVENTO_PASADO: No se puede modificar una cita agendada antes de la fecha y hora actual.';
                END IF;
            END; $$;


--
-- Name: fn_valida_horario_funcionario(bigint, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_valida_horario_funcionario(p_funcionario_id bigint, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone, p_todo_el_dia boolean) RETURNS void
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_horario     JSONB;
                v_dow         INT;
                v_dia         JSONB;
                v_hora_inicio TIME;
                v_hora_fin    TIME;
            BEGIN
                IF p_funcionario_id IS NULL OR COALESCE(p_todo_el_dia, false) THEN
                    RETURN;
                END IF;

                SELECT horario_semanal INTO v_horario FROM funcionarios WHERE id = p_funcionario_id;
                IF v_horario IS NULL OR jsonb_array_length(v_horario) = 0 THEN
                    RETURN;
                END IF;

                IF DATE(p_fecha_inicio) <> DATE(p_fecha_fin) THEN
                    RAISE EXCEPTION 'HORARIO_FUERA: El horario del funcionario no permite citas que abarquen más de un día.';
                END IF;

                v_dow := EXTRACT(DOW FROM p_fecha_inicio)::INT;

                SELECT elem INTO v_dia
                FROM jsonb_array_elements(v_horario) elem
                WHERE (elem->>'dia')::INT = v_dow;

                IF v_dia IS NULL OR NOT COALESCE((v_dia->>'activo')::BOOLEAN, false) THEN
                    RAISE EXCEPTION 'HORARIO_FUERA: El funcionario no trabaja ese día según su horario configurado.';
                END IF;

                v_hora_inicio := (v_dia->>'hora_inicio')::TIME;
                v_hora_fin    := (v_dia->>'hora_fin')::TIME;

                IF p_fecha_inicio::TIME < v_hora_inicio OR p_fecha_fin::TIME > v_hora_fin THEN
                    RAISE EXCEPTION 'HORARIO_FUERA: El evento está fuera del horario laboral del funcionario (% - %).', v_hora_inicio, v_hora_fin;
                END IF;
            END; $$;


--
-- Name: fn_valida_horario_funcionario_vs_sucursal(jsonb, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_valida_horario_funcionario_vs_sucursal(p_horario_semanal jsonb, p_sucursal_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_horario_sucursal JSONB;
                v_dia_func         JSONB;
                v_dia_suc          JSONB;
            BEGIN
                IF p_sucursal_id IS NULL OR p_horario_semanal IS NULL THEN
                    RETURN;
                END IF;

                SELECT horario_semanal INTO v_horario_sucursal FROM sucursal_horarios WHERE sucursal_id = p_sucursal_id;
                IF v_horario_sucursal IS NULL OR jsonb_array_length(v_horario_sucursal) = 0 THEN
                    RETURN;
                END IF;

                FOR v_dia_func IN SELECT elem FROM jsonb_array_elements(p_horario_semanal) elem
                LOOP
                    IF NOT COALESCE((v_dia_func->>'activo')::BOOLEAN, false) THEN
                        CONTINUE;
                    END IF;

                    SELECT elem INTO v_dia_suc
                    FROM jsonb_array_elements(v_horario_sucursal) elem
                    WHERE (elem->>'dia')::INT = (v_dia_func->>'dia')::INT;

                    IF v_dia_suc IS NULL OR NOT COALESCE((v_dia_suc->>'activo')::BOOLEAN, false) THEN
                        RAISE EXCEPTION 'HORARIO_SUCURSAL_FUERA: El funcionario no puede trabajar un día en que la sucursal no labora.';
                    END IF;

                    IF (v_dia_func->>'hora_inicio')::TIME < (v_dia_suc->>'hora_inicio')::TIME
                       OR (v_dia_func->>'hora_fin')::TIME > (v_dia_suc->>'hora_fin')::TIME THEN
                        RAISE EXCEPTION 'HORARIO_SUCURSAL_FUERA: El horario del funcionario está fuera del horario de la sucursal (% - %).',
                            (v_dia_suc->>'hora_inicio')::TIME, (v_dia_suc->>'hora_fin')::TIME;
                    END IF;
                END LOOP;
            END; $$;


--
-- Name: fn_valida_horario_sucursal(bigint, timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_valida_horario_sucursal(p_sucursal_id bigint, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone, p_todo_el_dia boolean) RETURNS void
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_horario     JSONB;
                v_dow         INT;
                v_dia         JSONB;
                v_hora_inicio TIME;
                v_hora_fin    TIME;
            BEGIN
                IF p_sucursal_id IS NULL OR COALESCE(p_todo_el_dia, false) THEN
                    RETURN;
                END IF;

                SELECT horario_semanal INTO v_horario FROM sucursal_horarios WHERE sucursal_id = p_sucursal_id;
                IF v_horario IS NULL OR jsonb_array_length(v_horario) = 0 THEN
                    RETURN;
                END IF;

                IF DATE(p_fecha_inicio) <> DATE(p_fecha_fin) THEN
                    RAISE EXCEPTION 'HORARIO_SUCURSAL_FUERA: El horario de la sucursal no permite citas que abarquen más de un día.';
                END IF;

                v_dow := EXTRACT(DOW FROM p_fecha_inicio)::INT;

                SELECT elem INTO v_dia
                FROM jsonb_array_elements(v_horario) elem
                WHERE (elem->>'dia')::INT = v_dow;

                IF v_dia IS NULL OR NOT COALESCE((v_dia->>'activo')::BOOLEAN, false) THEN
                    RAISE EXCEPTION 'HORARIO_SUCURSAL_FUERA: La sucursal no labora ese día según su horario configurado.';
                END IF;

                v_hora_inicio := (v_dia->>'hora_inicio')::TIME;
                v_hora_fin    := (v_dia->>'hora_fin')::TIME;

                IF p_fecha_inicio::TIME < v_hora_inicio OR p_fecha_fin::TIME > v_hora_fin THEN
                    RAISE EXCEPTION 'HORARIO_SUCURSAL_FUERA: El evento está fuera del horario de operación de la sucursal (% - %).', v_hora_inicio, v_hora_fin;
                END IF;
            END; $$;


--
-- Name: sp_agenda_avisos_config_get(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_avisos_config_get(p_empresa_id bigint) RETURNS TABLE(empresa_id bigint, aviso_creacion_activo boolean, aviso_creacion_mensaje text, aviso_dia_antes_activo boolean, aviso_dia_antes_mensaje text, aviso_discrecional_activo boolean, aviso_discrecional_dias integer, aviso_discrecional_mensaje text)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    p_empresa_id,
                    COALESCE(c.aviso_creacion_activo, true),
                    c.aviso_creacion_mensaje,
                    COALESCE(c.aviso_dia_antes_activo, true),
                    c.aviso_dia_antes_mensaje,
                    COALESCE(c.aviso_discrecional_activo, false),
                    COALESCE(c.aviso_discrecional_dias, 3),
                    c.aviso_discrecional_mensaje
                FROM (SELECT 1) AS dummy
                LEFT JOIN agenda_avisos_config c ON c.empresa_id = p_empresa_id;
            END;
            $$;


--
-- Name: sp_agenda_avisos_config_upsert(bigint, boolean, text, boolean, text, boolean, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_avisos_config_upsert(p_empresa_id bigint, p_aviso_creacion_activo boolean, p_aviso_creacion_mensaje text, p_aviso_dia_antes_activo boolean, p_aviso_dia_antes_mensaje text, p_aviso_discrecional_activo boolean, p_aviso_discrecional_dias integer, p_aviso_discrecional_mensaje text) RETURNS void
    LANGUAGE plpgsql
    AS $$
            BEGIN
                INSERT INTO agenda_avisos_config (
                    empresa_id, aviso_creacion_activo, aviso_creacion_mensaje,
                    aviso_dia_antes_activo, aviso_dia_antes_mensaje,
                    aviso_discrecional_activo, aviso_discrecional_dias, aviso_discrecional_mensaje
                ) VALUES (
                    p_empresa_id, p_aviso_creacion_activo, p_aviso_creacion_mensaje,
                    p_aviso_dia_antes_activo, p_aviso_dia_antes_mensaje,
                    p_aviso_discrecional_activo, p_aviso_discrecional_dias, p_aviso_discrecional_mensaje
                )
                ON CONFLICT (empresa_id) DO UPDATE SET
                    aviso_creacion_activo       = EXCLUDED.aviso_creacion_activo,
                    aviso_creacion_mensaje      = EXCLUDED.aviso_creacion_mensaje,
                    aviso_dia_antes_activo      = EXCLUDED.aviso_dia_antes_activo,
                    aviso_dia_antes_mensaje     = EXCLUDED.aviso_dia_antes_mensaje,
                    aviso_discrecional_activo   = EXCLUDED.aviso_discrecional_activo,
                    aviso_discrecional_dias     = EXCLUDED.aviso_discrecional_dias,
                    aviso_discrecional_mensaje  = EXCLUDED.aviso_discrecional_mensaje,
                    updated_at                  = NOW();
            END;
            $$;


--
-- Name: sp_agenda_avisos_marcar_enviado(bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_avisos_marcar_enviado(p_evento_id bigint, p_tipo character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                INSERT INTO agenda_avisos_envios (evento_id, tipo)
                VALUES (p_evento_id, p_tipo)
                ON CONFLICT (evento_id, tipo) DO NOTHING;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_agenda_avisos_pendientes_dia_antes(timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_avisos_pendientes_dia_antes(p_fecha_ref timestamp without time zone) RETURNS TABLE(evento_id bigint, empresa_id bigint, titulo character varying, ubicacion character varying, fecha_inicio timestamp without time zone, cliente_nombre character varying, cliente_correo character varying, mensaje_custom text)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    e.id, e.empresa_id, e.titulo,
                    (SELECT l.ubicacion FROM agenda_evento_lineas l WHERE l.evento_id = e.id ORDER BY l.orden, l.id LIMIT 1),
                    e.fecha_inicio,
                    cl.name, cl.email,
                    cfg.aviso_dia_antes_mensaje
                FROM agenda_eventos e
                JOIN clients cl ON cl.id = e.cliente_id
                LEFT JOIN agenda_avisos_config cfg ON cfg.empresa_id = e.empresa_id
                WHERE e.deleted_at IS NULL
                  AND e.estado NOT IN ('cancelado','completado')
                  AND cl.email IS NOT NULL AND cl.email <> ''
                  AND COALESCE(cfg.aviso_dia_antes_activo, true) = true
                  AND e.fecha_inicio BETWEEN (p_fecha_ref + INTERVAL '24 hours') AND (p_fecha_ref + INTERVAL '25 hours')
                  AND NOT EXISTS (
                      SELECT 1 FROM agenda_avisos_envios v
                      WHERE v.evento_id = e.id AND v.tipo = 'dia_antes'
                  );
            END;
            $$;


--
-- Name: sp_agenda_avisos_pendientes_discrecional(timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_avisos_pendientes_discrecional(p_fecha_ref timestamp without time zone) RETURNS TABLE(evento_id bigint, empresa_id bigint, titulo character varying, ubicacion character varying, fecha_inicio timestamp without time zone, cliente_nombre character varying, cliente_correo character varying, mensaje_custom text)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    e.id, e.empresa_id, e.titulo,
                    (SELECT l.ubicacion FROM agenda_evento_lineas l WHERE l.evento_id = e.id ORDER BY l.orden, l.id LIMIT 1),
                    e.fecha_inicio,
                    cl.name, cl.email,
                    cfg.aviso_discrecional_mensaje
                FROM agenda_eventos e
                JOIN clients cl ON cl.id = e.cliente_id
                JOIN agenda_avisos_config cfg ON cfg.empresa_id = e.empresa_id
                WHERE e.deleted_at IS NULL
                  AND e.estado NOT IN ('cancelado','completado')
                  AND cl.email IS NOT NULL AND cl.email <> ''
                  AND cfg.aviso_discrecional_activo = true
                  AND e.fecha_inicio BETWEEN
                        (p_fecha_ref + (cfg.aviso_discrecional_dias || ' days')::INTERVAL)
                        AND (p_fecha_ref + (cfg.aviso_discrecional_dias || ' days')::INTERVAL + INTERVAL '1 hour')
                  AND NOT EXISTS (
                      SELECT 1 FROM agenda_avisos_envios v
                      WHERE v.evento_id = e.id AND v.tipo = 'discrecional'
                  );
            END;
            $$;


--
-- Name: sp_agenda_avisos_token_consumir(character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_avisos_token_consumir(p_token character varying, p_estado character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_evento_id BIGINT;
            BEGIN
                IF p_estado NOT IN ('confirmado','cancelado') THEN
                    RETURN FALSE;
                END IF;

                SELECT evento_id INTO v_evento_id
                FROM agenda_avisos_tokens
                WHERE token = p_token
                  AND usado_at IS NULL
                  AND expira_at > NOW()
                FOR UPDATE;

                IF v_evento_id IS NULL THEN
                    RETURN FALSE;
                END IF;

                UPDATE agenda_eventos SET estado = p_estado, updated_at = NOW()
                WHERE id = v_evento_id;

                UPDATE agenda_avisos_tokens SET usado_at = NOW()
                WHERE token = p_token;

                RETURN TRUE;
            END;
            $$;


--
-- Name: sp_agenda_avisos_token_create(bigint, bigint, character varying, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_avisos_token_create(p_evento_id bigint, p_empresa_id bigint, p_token character varying, p_expira_at timestamp without time zone) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO agenda_avisos_tokens (evento_id, empresa_id, token, expira_at)
                VALUES (p_evento_id, p_empresa_id, p_token, p_expira_at)
                RETURNING id INTO v_id;
                RETURN v_id;
            END;
            $$;


--
-- Name: sp_agenda_avisos_token_resolver(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_avisos_token_resolver(p_token character varying) RETURNS TABLE(evento_id bigint, empresa_id bigint, expira_at timestamp without time zone, usado_at timestamp without time zone, titulo character varying, descripcion text, ubicacion character varying, fecha_inicio timestamp without time zone, estado character varying)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    t.evento_id, t.empresa_id, t.expira_at, t.usado_at,
                    e.titulo, e.descripcion, e.ubicacion, e.fecha_inicio, e.estado
                FROM agenda_avisos_tokens t
                JOIN agenda_eventos e ON e.id = t.evento_id
                WHERE t.token = p_token;
            END;
            $$;


--
-- Name: sp_agenda_evento_create(bigint, bigint, bigint, character varying, timestamp without time zone, timestamp without time zone, boolean, bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_create(p_empresa_id bigint, p_sucursal_id bigint, p_user_id bigint, p_titulo character varying, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone, p_todo_el_dia boolean, p_cliente_id bigint, p_color character varying, p_estado character varying) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                PERFORM fn_valida_horario_sucursal(p_sucursal_id, p_fecha_inicio, p_fecha_fin, p_todo_el_dia);

                INSERT INTO agenda_eventos (
                    empresa_id, sucursal_id, user_id, titulo,
                    fecha_inicio, fecha_fin, todo_el_dia, cliente_id,
                    color, estado
                ) VALUES (
                    p_empresa_id, p_sucursal_id, p_user_id, p_titulo,
                    p_fecha_inicio, p_fecha_fin, p_todo_el_dia, p_cliente_id,
                    p_color, p_estado
                ) RETURNING id INTO v_id;
                RETURN v_id;
            END; $$;


--
-- Name: sp_agenda_evento_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, sucursal_id bigint, user_id bigint, titulo character varying, fecha_inicio timestamp without time zone, fecha_fin timestamp without time zone, todo_el_dia boolean, cliente_id bigint, cliente_nombre character varying, color character varying, estado character varying, documento_id bigint, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT ae.id, ae.empresa_id, ae.sucursal_id, ae.user_id,
                       ae.titulo,
                       ae.fecha_inicio, ae.fecha_fin, ae.todo_el_dia,
                       ae.cliente_id, c.name AS cliente_nombre,
                       ae.color, ae.estado, ae.documento_id,
                       ae.created_at, ae.updated_at
                FROM agenda_eventos ae
                LEFT JOIN clients c ON c.id = ae.cliente_id
                WHERE ae.id = p_id AND ae.empresa_id = p_empresa_id AND ae.deleted_at IS NULL;
            END; $$;


--
-- Name: sp_agenda_evento_linea_create(bigint, bigint, bigint, timestamp without time zone, timestamp without time zone, text, character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_linea_create(p_evento_id bigint, p_servicio_id bigint, p_funcionario_id bigint, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone, p_comentario text, p_ubicacion character varying, p_orden integer) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_id          BIGINT;
                v_todo_el_dia BOOLEAN;
            BEGIN
                IF p_funcionario_id IS NOT NULL THEN
                    SELECT todo_el_dia INTO v_todo_el_dia FROM agenda_eventos WHERE id = p_evento_id;
                    PERFORM fn_valida_horario_funcionario(p_funcionario_id, p_fecha_inicio, p_fecha_fin, v_todo_el_dia);
                END IF;

                INSERT INTO agenda_evento_lineas (evento_id, servicio_id, funcionario_id, fecha_inicio, fecha_fin, comentario, ubicacion, orden)
                VALUES (p_evento_id, p_servicio_id, p_funcionario_id, p_fecha_inicio, p_fecha_fin, p_comentario, p_ubicacion, p_orden)
                RETURNING id INTO v_id;
                RETURN v_id;
            END; $$;


--
-- Name: sp_agenda_evento_linea_producto_create(bigint, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_linea_producto_create(p_linea_id bigint, p_producto_id bigint, p_cantidad numeric) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO agenda_evento_linea_productos (linea_id, producto_id, cantidad)
                VALUES (p_linea_id, p_producto_id, p_cantidad)
                RETURNING id INTO v_id;
                RETURN v_id;
            END; $$;


--
-- Name: sp_agenda_evento_lineas_delete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_lineas_delete(p_evento_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                DELETE FROM agenda_evento_linea_productos
                WHERE linea_id IN (SELECT id FROM agenda_evento_lineas WHERE evento_id = p_evento_id);
                DELETE FROM agenda_evento_lineas WHERE evento_id = p_evento_id;
            END; $$;


--
-- Name: sp_agenda_evento_lineas_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_lineas_list(p_evento_id bigint) RETURNS TABLE(linea_id bigint, servicio_id bigint, servicio_nombre character varying, funcionario_id bigint, funcionario_nombre character varying, funcionario_color character varying, fecha_inicio timestamp without time zone, fecha_fin timestamp without time zone, comentario text, ubicacion character varying, orden integer, productos jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT l.id, l.servicio_id, s.name,
                       l.funcionario_id, f.name, f.color,
                       l.fecha_inicio, l.fecha_fin,
                       l.comentario, l.ubicacion, l.orden,
                       COALESCE((
                           SELECT jsonb_agg(jsonb_build_object(
                               'producto_id', p.id, 'nombre', p.name,
                               'price', p.price, 'moneda', p.moneda,
                               'cantidad', lp.cantidad
                           ))
                           FROM agenda_evento_linea_productos lp
                           JOIN productos p ON p.id = lp.producto_id
                           WHERE lp.linea_id = l.id
                       ), '[]'::jsonb) AS productos
                FROM agenda_evento_lineas l
                LEFT JOIN servicios    s ON s.id = l.servicio_id
                LEFT JOIN funcionarios f ON f.id = l.funcionario_id
                WHERE l.evento_id = p_evento_id
                ORDER BY l.orden, l.id;
            END; $$;


--
-- Name: sp_agenda_evento_list(bigint, timestamp without time zone, timestamp without time zone, bigint[], bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_list(p_empresa_id bigint, p_fecha_desde timestamp without time zone, p_fecha_hasta timestamp without time zone, p_funcionario_ids bigint[] DEFAULT NULL::bigint[], p_sucursal_id bigint DEFAULT NULL::bigint) RETURNS TABLE(evento_id bigint, linea_id bigint, titulo character varying, fecha_inicio timestamp without time zone, fecha_fin timestamp without time zone, todo_el_dia boolean, cliente_id bigint, cliente_nombre character varying, cliente_telefono character varying, cliente_email character varying, color character varying, estado character varying, servicio_id bigint, servicio_nombre character varying, funcionario_id bigint, funcionario_nombre character varying, funcionario_color character varying, sucursal_id bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT ae.id, l.id, ae.titulo,
                       l.fecha_inicio, l.fecha_fin, ae.todo_el_dia,
                       ae.cliente_id, c.name AS cliente_nombre, c.phone AS cliente_telefono, c.email AS cliente_email,
                       ae.color, ae.estado,
                       l.servicio_id, s.name AS servicio_nombre,
                       l.funcionario_id, f.name AS funcionario_nombre, f.color AS funcionario_color,
                       ae.sucursal_id
                FROM agenda_eventos ae
                JOIN agenda_evento_lineas l ON l.evento_id = ae.id
                LEFT JOIN clients c ON c.id = ae.cliente_id
                LEFT JOIN servicios    s ON s.id = l.servicio_id
                LEFT JOIN funcionarios f ON f.id = l.funcionario_id
                WHERE ae.empresa_id = p_empresa_id
                  AND ae.deleted_at IS NULL
                  AND l.fecha_inicio < p_fecha_hasta
                  AND l.fecha_fin > p_fecha_desde
                  AND (p_funcionario_ids IS NULL OR array_length(p_funcionario_ids, 1) IS NULL OR l.funcionario_id = ANY(p_funcionario_ids))
                  AND (p_sucursal_id IS NULL OR ae.sucursal_id = p_sucursal_id)
                ORDER BY l.fecha_inicio, l.orden;
            END; $$;


--
-- Name: sp_agenda_evento_marcar_facturado(bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_marcar_facturado(p_id bigint, p_empresa_id bigint, p_documento_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE agenda_eventos SET
                    documento_id = p_documento_id,
                    updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_agenda_evento_mover(bigint, bigint, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_mover(p_id bigint, p_empresa_id bigint, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_rows              INTEGER;
                v_todo_el_dia       BOOLEAN;
                v_sucursal_id       BIGINT;
                v_fecha_inicio_prev TIMESTAMP;
                v_delta             INTERVAL;
                v_linea             RECORD;
            BEGIN
                SELECT todo_el_dia, sucursal_id, fecha_inicio
                INTO v_todo_el_dia, v_sucursal_id, v_fecha_inicio_prev
                FROM agenda_eventos WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;

                PERFORM fn_valida_evento_no_pasado(v_fecha_inicio_prev);
                PERFORM fn_valida_horario_sucursal(v_sucursal_id, p_fecha_inicio, p_fecha_fin, v_todo_el_dia);

                v_delta := p_fecha_inicio - v_fecha_inicio_prev;

                FOR v_linea IN
                    SELECT funcionario_id,
                           fecha_inicio + v_delta AS nueva_fecha_inicio,
                           fecha_fin + v_delta    AS nueva_fecha_fin
                    FROM agenda_evento_lineas WHERE evento_id = p_id
                LOOP
                    IF v_linea.funcionario_id IS NOT NULL THEN
                        PERFORM fn_valida_horario_funcionario(v_linea.funcionario_id, v_linea.nueva_fecha_inicio, v_linea.nueva_fecha_fin, v_todo_el_dia);
                    END IF;
                END LOOP;

                UPDATE agenda_evento_lineas
                SET fecha_inicio = fecha_inicio + v_delta, fecha_fin = fecha_fin + v_delta, updated_at = NOW()
                WHERE evento_id = p_id;

                UPDATE agenda_eventos SET
                    fecha_inicio = p_fecha_inicio, fecha_fin = p_fecha_fin, updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_agenda_evento_set_estado(bigint, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_set_estado(p_id bigint, p_empresa_id bigint, p_estado character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_fecha_inicio_prev TIMESTAMP;
            BEGIN
                SELECT fecha_inicio INTO v_fecha_inicio_prev
                FROM agenda_eventos WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;

                PERFORM fn_valida_evento_no_pasado(v_fecha_inicio_prev);

                UPDATE agenda_eventos SET
                    estado     = p_estado,
                    updated_at = NOW()
                WHERE id = p_id
                  AND empresa_id = p_empresa_id
                  AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_agenda_evento_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_fecha_inicio_prev TIMESTAMP;
            BEGIN
                SELECT fecha_inicio INTO v_fecha_inicio_prev
                FROM agenda_eventos WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;

                PERFORM fn_valida_evento_no_pasado(v_fecha_inicio_prev);

                UPDATE agenda_eventos
                SET deleted_at = NOW(), updated_at = NOW()
                WHERE id = p_id
                  AND empresa_id = p_empresa_id
                  AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_agenda_evento_update(bigint, bigint, character varying, timestamp without time zone, timestamp without time zone, boolean, bigint, character varying, character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_update(p_id bigint, p_empresa_id bigint, p_titulo character varying, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone, p_todo_el_dia boolean, p_cliente_id bigint, p_color character varying, p_estado character varying, p_sucursal_id bigint DEFAULT NULL::bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_rows              INTEGER;
                v_sucursal_id       BIGINT;
                v_fecha_inicio_prev TIMESTAMP;
            BEGIN
                SELECT sucursal_id, fecha_inicio INTO v_sucursal_id, v_fecha_inicio_prev
                FROM agenda_eventos WHERE id = p_id AND empresa_id = p_empresa_id;

                v_sucursal_id := COALESCE(p_sucursal_id, v_sucursal_id);

                PERFORM fn_valida_evento_no_pasado(v_fecha_inicio_prev);
                PERFORM fn_valida_horario_sucursal(v_sucursal_id, p_fecha_inicio, p_fecha_fin, p_todo_el_dia);

                UPDATE agenda_eventos SET
                    titulo = p_titulo,
                    fecha_inicio = p_fecha_inicio, fecha_fin = p_fecha_fin, todo_el_dia = p_todo_el_dia,
                    cliente_id = p_cliente_id,
                    color = p_color, estado = COALESCE(p_estado, estado),
                    sucursal_id = v_sucursal_id,
                    updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_bitacora_insert(bigint, bigint, bigint, character varying, character varying, jsonb, jsonb, integer, jsonb, character varying, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bitacora_insert(p_user_id bigint, p_empresa_id bigint, p_sucursal_id bigint, p_metodo character varying, p_endpoint character varying, p_request_headers jsonb, p_request_body jsonb, p_response_status integer, p_response_body jsonb, p_ip_address character varying, p_user_agent text, p_duracion_ms integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    INSERT INTO bitacora_api (user_id, empresa_id, sucursal_id, metodo, endpoint, request_headers, request_body, response_status, response_body, ip_address, user_agent, duracion_ms)
    VALUES (p_user_id, p_empresa_id, p_sucursal_id, p_metodo, p_endpoint, p_request_headers, p_request_body, p_response_status, p_response_body, p_ip_address, p_user_agent, p_duracion_ms);
END; $$;


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

CREATE FUNCTION public.sp_bodega_list(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, description text, is_default boolean, is_active boolean, permite_stock_negativo boolean, total_productos bigint, sucursal_ids bigint[])
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT b.id, b.empresa_id, b.name, b.description,
         b.is_default, b.is_active, b.permite_stock_negativo,
         COUNT(bp.id) FILTER (WHERE bp.is_active),
         ARRAY_REMOVE(ARRAY_AGG(DISTINCT sb.sucursal_id), NULL)
  FROM bodegas b
  LEFT JOIN bodega_productos bp ON bp.bodega_id = b.id
  LEFT JOIN sucursal_bodegas sb ON sb.bodega_id = b.id
  WHERE b.empresa_id = p_empresa_id AND b.deleted_at IS NULL
  GROUP BY b.id
  ORDER BY b.is_default DESC, b.name;
END;
$$;


--
-- Name: sp_bodega_list_by_sucursal(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_list_by_sucursal(p_sucursal_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, description text, is_default boolean, is_active boolean, permite_stock_negativo boolean, total_productos bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY
  SELECT b.id, b.empresa_id, b.name, b.description,
         b.is_default, b.is_active, b.permite_stock_negativo,
         COUNT(bp.id) FILTER (WHERE bp.is_active)
  FROM bodegas b
  JOIN sucursal_bodegas sb ON sb.bodega_id = b.id AND sb.sucursal_id = p_sucursal_id
  LEFT JOIN bodega_productos bp ON bp.bodega_id = b.id
  WHERE b.deleted_at IS NULL AND b.is_active = true
  GROUP BY b.id
  ORDER BY b.is_default DESC, b.name;
END;
$$;


--
-- Name: sp_bodega_list_eliminadas(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_list_eliminadas(p_empresa_id bigint) RETURNS TABLE(id bigint, name character varying, description text, deleted_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT b.id, b.name, b.description, b.deleted_at
                FROM bodegas b
                WHERE b.empresa_id = p_empresa_id AND b.deleted_at IS NOT NULL
                ORDER BY b.deleted_at DESC;
            END;
            $$;


--
-- Name: sp_bodega_producto_ajustar_stock(bigint, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_producto_ajustar_stock(p_bodega_id bigint, p_producto_id bigint, p_delta numeric) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_permite_negativo BOOLEAN;
            BEGIN
                SELECT permite_stock_negativo INTO v_permite_negativo
                  FROM bodegas WHERE id = p_bodega_id;

                INSERT INTO bodega_productos (bodega_id, producto_id, stock)
                VALUES (p_bodega_id, p_producto_id, CASE WHEN v_permite_negativo THEN p_delta ELSE GREATEST(p_delta, 0) END)
                ON CONFLICT (bodega_id, producto_id) DO UPDATE
                   SET stock = CASE
                                  WHEN v_permite_negativo THEN bodega_productos.stock + p_delta
                                  ELSE GREATEST(bodega_productos.stock + p_delta, 0)
                               END,
                       updated_at = NOW();
            END;
            $$;


--
-- Name: sp_bodega_producto_set_stock_min(bigint, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_producto_set_stock_min(p_bodega_id bigint, p_producto_id bigint, p_stock_min numeric) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE v_rows INTEGER;
BEGIN
    UPDATE bodega_productos
       SET stock_min = GREATEST(COALESCE(p_stock_min, 0), 0), updated_at = NOW()
     WHERE bodega_id = p_bodega_id AND producto_id = p_producto_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows > 0;
END; $$;


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
    INSERT INTO bodega_productos (bodega_id, producto_id, is_active, stock, stock_min)
    VALUES (p_bodega_id, p_producto_id, true, 0, 0)
    ON CONFLICT (bodega_id, producto_id)
    DO UPDATE SET is_active = NOT bodega_productos.is_active, updated_at = NOW();
    RETURN true;
END;
$$;


--
-- Name: sp_bodega_restore(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_restore(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                UPDATE bodegas
                SET deleted_at = NULL, is_active = TRUE, updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NOT NULL;
                RETURN FOUND;
            END;
            $$;


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
-- Name: sp_cierre_caja_calcular(bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cierre_caja_calcular(p_empresa_id bigint, p_sucursal_id bigint, p_caja_id bigint) RETURNS TABLE(fecha_inicio timestamp without time zone, fecha_fin timestamp without time zone, total_documentos integer, medios_pago jsonb)
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_fecha_inicio timestamp;
                v_fecha_fin    timestamp := NOW();
            BEGIN
                SELECT COALESCE(MAX(cc.fecha_fin), '1970-01-01 00:00:00'::timestamp)
                INTO v_fecha_inicio
                FROM caja_cierres cc
                WHERE cc.empresa_id = p_empresa_id
                  AND cc.caja_id    = p_caja_id;

                RETURN QUERY
                SELECT
                    v_fecha_inicio,
                    v_fecha_fin,
                    (SELECT COUNT(*)::integer
                     FROM documentos_electronicos d
                     WHERE d.empresa_id  = p_empresa_id
                       AND d.caja_id     = p_caja_id
                       AND d.fecha_emision > v_fecha_inicio
                       AND d.fecha_emision <= v_fecha_fin
                       AND d.estado = 'aceptado'),
                    (SELECT COALESCE(jsonb_agg(
                        jsonb_build_object(
                            'tipo_medio_pago', sub.tipo_medio_pago,
                            'moneda',          sub.moneda,
                            'monto_sistema',   sub.monto
                        ) ORDER BY sub.moneda, sub.tipo_medio_pago
                     ), '[]'::jsonb)
                     FROM (
                         SELECT mp.tipo_medio_pago, d.moneda, SUM(mp.total_medio_pago) AS monto
                         FROM documento_medios_pago mp
                         JOIN documentos_electronicos d ON d.id = mp.documento_id
                         WHERE d.empresa_id  = p_empresa_id
                           AND d.caja_id     = p_caja_id
                           AND d.fecha_emision > v_fecha_inicio
                           AND d.fecha_emision <= v_fecha_fin
                           AND d.estado = 'aceptado'
                         GROUP BY mp.tipo_medio_pago, d.moneda
                     ) sub);
            END;
            $$;


--
-- Name: sp_cierre_caja_crear(bigint, bigint, bigint, bigint, character varying, timestamp without time zone, timestamp without time zone, integer, numeric, numeric, text, jsonb, jsonb, jsonb, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cierre_caja_crear(p_empresa_id bigint, p_sucursal_id bigint, p_caja_id bigint, p_user_id bigint, p_user_nombre character varying, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone, p_total_docs integer, p_total_sistema numeric, p_total_declarado numeric, p_observaciones text, p_medios jsonb, p_fondo_inicial jsonb DEFAULT '{}'::jsonb, p_efectivo_denominaciones jsonb DEFAULT '[]'::jsonb, p_egresos jsonb DEFAULT '[]'::jsonb, p_totales_moneda jsonb DEFAULT '{}'::jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_id      bigint;
                v_diff    numeric;
                v_medio   jsonb;
            BEGIN
                v_diff := p_total_declarado - p_total_sistema;

                INSERT INTO caja_cierres(
                    empresa_id, sucursal_id, caja_id, user_id, user_nombre,
                    fecha_inicio, fecha_fin,
                    total_documentos, total_sistema, total_declarado, diferencia,
                    observaciones,
                    fondo_inicial, efectivo_denominaciones, egresos, totales_moneda
                ) VALUES (
                    p_empresa_id, p_sucursal_id, p_caja_id, p_user_id, p_user_nombre,
                    p_fecha_inicio, p_fecha_fin,
                    p_total_docs, p_total_sistema, p_total_declarado, v_diff,
                    p_observaciones,
                    p_fondo_inicial, p_efectivo_denominaciones, p_egresos, p_totales_moneda
                ) RETURNING id INTO v_id;

                FOR v_medio IN SELECT * FROM jsonb_array_elements(p_medios) LOOP
                    INSERT INTO caja_cierre_medios_pago(
                        cierre_id, tipo_medio_pago, descripcion, moneda,
                        monto_sistema, monto_declarado, diferencia
                    ) VALUES (
                        v_id,
                        v_medio->>'tipo_medio_pago',
                        v_medio->>'descripcion',
                        COALESCE(v_medio->>'moneda', 'CRC'),
                        (v_medio->>'monto_sistema')::numeric,
                        (v_medio->>'monto_declarado')::numeric,
                        (v_medio->>'monto_declarado')::numeric - (v_medio->>'monto_sistema')::numeric
                    );
                END LOOP;

                RETURN v_id;
            END;
            $$;


--
-- Name: sp_cierre_caja_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cierre_caja_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, sucursal_id bigint, caja_id bigint, user_id bigint, user_nombre character varying, fecha_inicio timestamp without time zone, fecha_fin timestamp without time zone, total_documentos integer, total_sistema numeric, total_declarado numeric, diferencia numeric, observaciones text, created_at timestamp without time zone, fondo_inicial jsonb, efectivo_denominaciones jsonb, egresos jsonb, totales_moneda jsonb, medios_pago jsonb)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    cc.id, cc.sucursal_id, cc.caja_id,
                    cc.user_id, cc.user_nombre,
                    cc.fecha_inicio, cc.fecha_fin,
                    cc.total_documentos,
                    cc.total_sistema, cc.total_declarado, cc.diferencia,
                    cc.observaciones, cc.created_at,
                    cc.fondo_inicial, cc.efectivo_denominaciones, cc.egresos, cc.totales_moneda,
                    COALESCE((
                        SELECT jsonb_agg(to_jsonb(m) ORDER BY m.moneda, m.tipo_medio_pago)
                        FROM caja_cierre_medios_pago m WHERE m.cierre_id = cc.id
                    ), '[]'::jsonb) AS medios_pago
                FROM caja_cierres cc
                WHERE cc.id = p_id
                  AND (p_empresa_id = 0 OR cc.empresa_id = p_empresa_id);
            END;
            $$;


--
-- Name: sp_cierre_caja_list(bigint, bigint, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cierre_caja_list(p_empresa_id bigint, p_caja_id bigint, p_page integer, p_per_page integer) RETURNS TABLE(id bigint, sucursal_id bigint, caja_id bigint, user_id bigint, user_nombre character varying, fecha_inicio timestamp without time zone, fecha_fin timestamp without time zone, total_documentos integer, total_sistema numeric, total_declarado numeric, diferencia numeric, observaciones text, created_at timestamp without time zone, totales_moneda jsonb, total_count bigint)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    cc.id, cc.sucursal_id, cc.caja_id,
                    cc.user_id, cc.user_nombre,
                    cc.fecha_inicio, cc.fecha_fin,
                    cc.total_documentos,
                    cc.total_sistema, cc.total_declarado, cc.diferencia,
                    cc.observaciones, cc.created_at,
                    cc.totales_moneda,
                    COUNT(*) OVER()::bigint AS total_count
                FROM caja_cierres cc
                WHERE cc.empresa_id = p_empresa_id
                  AND (p_caja_id = 0 OR cc.caja_id = p_caja_id)
                ORDER BY cc.created_at DESC
                LIMIT p_per_page OFFSET (p_page - 1) * p_per_page;
            END;
            $$;


--
-- Name: sp_client_create(bigint, character varying, character varying, character varying, character varying, character varying, character varying, text, text, date, character varying, character varying, character varying, character varying, character varying, integer, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_create(p_empresa_id bigint, p_name character varying, p_legal_name character varying DEFAULT NULL::character varying, p_tax_id_type character varying DEFAULT NULL::character varying, p_tax_id character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_phone character varying DEFAULT NULL::character varying, p_address text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_birth_date date DEFAULT NULL::date, p_actividad_economica_codigo character varying DEFAULT NULL::character varying, p_actividad_economica_descripcion character varying DEFAULT NULL::character varying, p_province_code character varying DEFAULT NULL::character varying, p_canton_code character varying DEFAULT NULL::character varying, p_district_code character varying DEFAULT NULL::character varying, p_dias_credito integer DEFAULT 0, p_limite_credito numeric DEFAULT 0, p_porcentaje_descuento numeric DEFAULT 0) RETURNS TABLE(id bigint, name character varying)
    LANGUAGE plpgsql
    AS $$
            BEGIN
              RETURN QUERY
              INSERT INTO clients(name, legal_name, tax_id_type, tax_id, email, phone,
                                  address, notes, birth_date,
                                  actividad_economica_codigo, actividad_economica_descripcion,
                                  province_code, canton_code, district_code,
                                  dias_credito, limite_credito, porcentaje_descuento)
              VALUES (p_name, p_legal_name, p_tax_id_type, p_tax_id, p_email, p_phone,
                      p_address, p_notes, p_birth_date,
                      p_actividad_economica_codigo, p_actividad_economica_descripcion,
                      p_province_code, p_canton_code, p_district_code,
                      COALESCE(p_dias_credito, 0), COALESCE(p_limite_credito, 0), COALESCE(p_porcentaje_descuento, 0))
              RETURNING clients.id, clients.name;
            END;
            $$;


--
-- Name: sp_client_find(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_find(p_id bigint) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, province_code character varying, canton_code character varying, district_code character varying, created_at timestamp without time zone, updated_at timestamp without time zone, dias_credito integer, limite_credito numeric, estado_credito character varying, saldo_pendiente numeric, porcentaje_descuento numeric)
    LANGUAGE sql STABLE
    AS $$
                SELECT c.id, c.name, c.legal_name, c.tax_id_type, c.tax_id, c.email, c.phone, c.address, c.notes,
                       c.birth_date, c.is_active, c.actividad_economica_codigo, c.actividad_economica_descripcion,
                       c.province_code, c.canton_code, c.district_code,
                       c.created_at, c.updated_at,
                       c.dias_credito, c.limite_credito, c.estado_credito,
                       COALESCE((SELECT SUM(cxc.saldo_pendiente) FROM cuentas_por_cobrar cxc
                                 WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')), 0) AS saldo_pendiente,
                       c.porcentaje_descuento
                FROM   clients c WHERE c.id = p_id AND c.deleted_at IS NULL LIMIT 1;
            $$;


--
-- Name: sp_client_find_by_central_id(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_find_by_central_id(p_central_client_id bigint) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id character varying, tax_id_type character varying, email character varying, phone character varying, address text, province_code character varying, canton_code character varying, district_code character varying, is_active boolean)
    LANGUAGE sql STABLE
    AS $$
                SELECT c.id, c.name, c.legal_name, c.tax_id, c.tax_id_type,
                       c.email, c.phone, c.address,
                       c.province_code, c.canton_code, c.district_code,
                       c.is_active
                FROM clients c
                WHERE c.central_client_id = p_central_client_id AND c.deleted_at IS NULL
                LIMIT 1;
            $$;


--
-- Name: sp_client_find_by_tax_id(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_find_by_tax_id(p_tax_id character varying) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, province_code character varying, canton_code character varying, district_code character varying, created_at timestamp without time zone, updated_at timestamp without time zone, dias_credito integer, limite_credito numeric, estado_credito character varying, saldo_pendiente numeric, porcentaje_descuento numeric)
    LANGUAGE sql STABLE
    AS $$
                SELECT c.id, c.name, c.legal_name, c.tax_id_type, c.tax_id, c.email, c.phone, c.address, c.notes,
                       c.birth_date, c.is_active, c.actividad_economica_codigo, c.actividad_economica_descripcion,
                       c.province_code, c.canton_code, c.district_code,
                       c.created_at, c.updated_at,
                       c.dias_credito, c.limite_credito, c.estado_credito,
                       COALESCE((SELECT SUM(cxc.saldo_pendiente) FROM cuentas_por_cobrar cxc
                                 WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')), 0) AS saldo_pendiente,
                       c.porcentaje_descuento
                FROM   clients c WHERE c.tax_id = p_tax_id AND c.deleted_at IS NULL LIMIT 1;
            $$;


--
-- Name: sp_client_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_list(p_empresa_id bigint) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, province_code character varying, canton_code character varying, district_code character varying, created_at timestamp without time zone, updated_at timestamp without time zone, dias_credito integer, limite_credito numeric, estado_credito character varying, saldo_pendiente numeric, porcentaje_descuento numeric)
    LANGUAGE sql STABLE
    AS $$
                SELECT c.id, c.name, c.legal_name, c.tax_id_type, c.tax_id, c.email, c.phone, c.address, c.notes,
                       c.birth_date, c.is_active, c.actividad_economica_codigo, c.actividad_economica_descripcion,
                       c.province_code, c.canton_code, c.district_code,
                       c.created_at, c.updated_at,
                       c.dias_credito, c.limite_credito, c.estado_credito,
                       COALESCE((SELECT SUM(cxc.saldo_pendiente) FROM cuentas_por_cobrar cxc
                                 WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')), 0) AS saldo_pendiente,
                       c.porcentaje_descuento
                FROM   clients c WHERE c.deleted_at IS NULL ORDER BY c.name;
            $$;


--
-- Name: sp_client_list_eliminados(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_list_eliminados(p_empresa_id bigint) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id character varying, email character varying, phone character varying, deleted_at timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
                SELECT c.id, c.name, c.legal_name, c.tax_id, c.email, c.phone, c.deleted_at
                FROM clients c
                WHERE c.deleted_at IS NOT NULL
                ORDER BY c.deleted_at DESC;
            $$;


--
-- Name: sp_client_restore(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_restore(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE clients SET is_active = TRUE, deleted_at = NULL, updated_at = NOW()
                WHERE id = p_id AND deleted_at IS NOT NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END;
            $$;


--
-- Name: sp_client_search(bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_search(p_empresa_id bigint, p_query character varying) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, province_code character varying, canton_code character varying, district_code character varying, created_at timestamp without time zone, updated_at timestamp without time zone, dias_credito integer, limite_credito numeric, estado_credito character varying, saldo_pendiente numeric, porcentaje_descuento numeric)
    LANGUAGE sql STABLE
    AS $$
                SELECT c.id, c.name, c.legal_name, c.tax_id_type, c.tax_id, c.email, c.phone, c.address, c.notes,
                       c.birth_date, c.is_active, c.actividad_economica_codigo, c.actividad_economica_descripcion,
                       c.province_code, c.canton_code, c.district_code,
                       c.created_at, c.updated_at,
                       c.dias_credito, c.limite_credito, c.estado_credito,
                       COALESCE((SELECT SUM(cxc.saldo_pendiente) FROM cuentas_por_cobrar cxc
                                 WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')), 0) AS saldo_pendiente,
                       c.porcentaje_descuento
                FROM   clients c WHERE c.deleted_at IS NULL
                  AND  (c.name ILIKE '%'||p_query||'%' OR c.tax_id ILIKE '%'||p_query||'%'
                        OR c.legal_name ILIKE '%'||p_query||'%')
                ORDER BY c.name LIMIT 50;
            $$;


--
-- Name: sp_client_set_central_id(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_set_central_id(p_id bigint, p_central_client_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            DECLARE v_rows INT;
            BEGIN
                UPDATE clients SET central_client_id = p_central_client_id, updated_at = NOW()
                WHERE id = p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END;
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
-- Name: sp_client_toggle_by_central_id(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_toggle_by_central_id(p_central_client_id bigint, p_is_active boolean) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            DECLARE v_rows INT;
            BEGIN
                UPDATE clients SET is_active = p_is_active, updated_at = NOW()
                WHERE central_client_id = p_central_client_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
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
-- Name: sp_client_update(bigint, character varying, character varying, character varying, character varying, character varying, character varying, text, text, date, character varying, character varying, character varying, character varying, character varying, integer, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_update(p_id bigint, p_name character varying, p_legal_name character varying DEFAULT NULL::character varying, p_tax_id_type character varying DEFAULT NULL::character varying, p_tax_id character varying DEFAULT NULL::character varying, p_email character varying DEFAULT NULL::character varying, p_phone character varying DEFAULT NULL::character varying, p_address text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_birth_date date DEFAULT NULL::date, p_actividad_economica_codigo character varying DEFAULT NULL::character varying, p_actividad_economica_descripcion character varying DEFAULT NULL::character varying, p_province_code character varying DEFAULT NULL::character varying, p_canton_code character varying DEFAULT NULL::character varying, p_district_code character varying DEFAULT NULL::character varying, p_dias_credito integer DEFAULT 0, p_limite_credito numeric DEFAULT 0, p_porcentaje_descuento numeric DEFAULT 0) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            DECLARE v_rows INT;
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
                province_code                   = p_province_code,
                canton_code                     = p_canton_code,
                district_code                   = p_district_code,
                dias_credito                    = COALESCE(p_dias_credito, 0),
                limite_credito                  = COALESCE(p_limite_credito, 0),
                porcentaje_descuento             = COALESCE(p_porcentaje_descuento, 0),
                updated_at                      = NOW()
              WHERE id = p_id AND deleted_at IS NULL;
              GET DIAGNOSTICS v_rows = ROW_COUNT;
              RETURN v_rows > 0;
            END;
            $$;


--
-- Name: sp_cliente_historial(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cliente_historial(p_cliente_id bigint, p_empresa_id bigint) RETURNS TABLE(origen character varying, id bigint, fecha timestamp without time zone, tipo_documento character varying, estado character varying, titulo character varying, descripcion text, monto numeric, clave character varying, numero_consecutivo character varying)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    'documento'::VARCHAR                AS origen,
                    d.id,
                    d.fecha_emision                      AS fecha,
                    d.tipo_documento,
                    d.estado,
                    d.numero_consecutivo::VARCHAR         AS titulo,
                    NULL::TEXT                            AS descripcion,
                    d.total_comprobante                   AS monto,
                    d.clave,
                    d.numero_consecutivo
                FROM documentos_electronicos d
                WHERE d.receptor_cliente_id = p_cliente_id
                  AND d.empresa_id = p_empresa_id
                  AND d.deleted_at IS NULL

                UNION ALL

                SELECT
                    'agenda'::VARCHAR                     AS origen,
                    e.id,
                    e.fecha_inicio                        AS fecha,
                    NULL::VARCHAR                          AS tipo_documento,
                    e.estado,
                    e.titulo,
                    NULL::TEXT                             AS descripcion,
                    NULL::NUMERIC                          AS monto,
                    NULL::VARCHAR                           AS clave,
                    NULL::VARCHAR                           AS numero_consecutivo
                FROM agenda_eventos e
                WHERE e.cliente_id = p_cliente_id
                  AND e.empresa_id = p_empresa_id
                  AND e.deleted_at IS NULL
                
                UNION ALL

                SELECT
                    'cotizacion'::VARCHAR                 AS origen,
                    c.id,
                    COALESCE(c.aprobado_at, c.fecha_emision) AS fecha,
                    NULL::VARCHAR                          AS tipo_documento,
                    c.estado,
                    c.numero::VARCHAR                      AS titulo,
                    NULL::TEXT                             AS descripcion,
                    c.total_comprobante                    AS monto,
                    NULL::VARCHAR                           AS clave,
                    c.numero::VARCHAR                       AS numero_consecutivo
                FROM cotizaciones c
                WHERE c.receptor_cliente_id = p_cliente_id
                  AND c.empresa_id = p_empresa_id
                  AND c.deleted_at IS NULL
                  AND c.aprobado_at IS NOT NULL
                  AND c.estado IN ('aprobada','convertida','convertida_parcial')
        
                ORDER BY fecha DESC;
            END;
            $$;


--
-- Name: sp_cliente_resumen(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cliente_resumen(p_cliente_id bigint, p_empresa_id bigint) RETURNS TABLE(total_citas bigint, citas_completadas bigint, citas_canceladas bigint, citas_pendientes bigint, total_facturas bigint, total_facturado numeric, total_notas_credito bigint, top_servicios json, top_productos json, top_funcionarios json)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    (SELECT COUNT(*) FROM agenda_eventos e
                       WHERE e.cliente_id = p_cliente_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL),
                    (SELECT COUNT(*) FROM agenda_eventos e
                       WHERE e.cliente_id = p_cliente_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL
                         AND e.estado = 'completado'),
                    (SELECT COUNT(*) FROM agenda_eventos e
                       WHERE e.cliente_id = p_cliente_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL
                         AND e.estado = 'cancelado'),
                    (SELECT COUNT(*) FROM agenda_eventos e
                       WHERE e.cliente_id = p_cliente_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL
                         AND e.estado IN ('agendado','confirmado')),
                    (SELECT COUNT(*) FROM documentos_electronicos d
                       WHERE d.receptor_cliente_id = p_cliente_id AND d.empresa_id = p_empresa_id AND d.deleted_at IS NULL
                         AND d.tipo_documento = '01' AND d.estado = 'aceptado'),
                    (SELECT COALESCE(SUM(d.total_comprobante), 0) FROM documentos_electronicos d
                       WHERE d.receptor_cliente_id = p_cliente_id AND d.empresa_id = p_empresa_id AND d.deleted_at IS NULL
                         AND d.tipo_documento = '01' AND d.estado = 'aceptado'),
                    (SELECT COUNT(*) FROM documentos_electronicos d
                       WHERE d.receptor_cliente_id = p_cliente_id AND d.empresa_id = p_empresa_id AND d.deleted_at IS NULL
                         AND d.tipo_documento = '03' AND d.estado = 'aceptado'),
                    (SELECT COALESCE(json_agg(t), '[]'::json) FROM (
                        SELECT s.id, s.name, COUNT(*) AS veces
                        FROM agenda_evento_lineas ael
                        JOIN agenda_eventos e ON e.id = ael.evento_id
                        JOIN servicios s ON s.id = ael.servicio_id
                        WHERE e.cliente_id = p_cliente_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL
                          AND e.estado <> 'cancelado'
                        GROUP BY s.id, s.name
                        ORDER BY veces DESC
                        LIMIT 5
                    ) t),
                    (SELECT COALESCE(json_agg(t), '[]'::json) FROM (
                        SELECT p.id, p.name, SUM(dl.cantidad) AS cantidad
                        FROM documento_lineas dl
                        JOIN documentos_electronicos d ON d.id = dl.documento_id
                        JOIN productos p ON p.id = dl.producto_id
                        WHERE d.receptor_cliente_id = p_cliente_id AND d.empresa_id = p_empresa_id AND d.deleted_at IS NULL
                          AND d.estado = 'aceptado' AND dl.producto_id IS NOT NULL
                        GROUP BY p.id, p.name
                        ORDER BY cantidad DESC
                        LIMIT 5
                    ) t),
                    (SELECT COALESCE(json_agg(t), '[]'::json) FROM (
                        SELECT f.id, f.name, COUNT(*) AS veces
                        FROM agenda_evento_lineas ael
                        JOIN agenda_eventos e ON e.id = ael.evento_id
                        JOIN funcionarios f ON f.id = ael.funcionario_id
                        WHERE e.cliente_id = p_cliente_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL
                          AND e.estado <> 'cancelado' AND ael.funcionario_id IS NOT NULL
                        GROUP BY f.id, f.name
                        ORDER BY veces DESC
                        LIMIT 5
                    ) t);
            END;
            $$;


--
-- Name: sp_clientes_con_adelantos(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_clientes_con_adelantos(p_empresa_id bigint) RETURNS TABLE(cliente_id bigint, nombre character varying, tax_id character varying, tax_id_type character varying, correo character varying, cantidad_recibos bigint, saldo_disponible numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT c.id,
                       c.name,
                       c.tax_id,
                       c.tax_id_type,
                       c.email,
                       COUNT(ra.id),
                       COALESCE(SUM(ra.saldo_disponible), 0)
                FROM recibos_adelanto ra
                JOIN clients c ON c.id = ra.cliente_id
                WHERE ra.empresa_id = p_empresa_id
                  AND ra.estado = 'disponible'
                  AND ra.saldo_disponible > 0
                GROUP BY c.id, c.name, c.tax_id, c.tax_id_type, c.email
                ORDER BY c.name;
            END; $$;


--
-- Name: sp_company_settings_get(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_company_settings_get(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, legal_name character varying, commercial_name character varying, tax_id character varying, tax_id_type character varying, province_code character varying, canton_code character varying, district_code character varying, other_signs text, phone character varying, email character varying, actividad_economica character varying, leyenda_tributaria text, hacienda_environment character varying, has_hacienda_credentials boolean, has_certificate boolean, certificate_subject text, certificate_issuer text, certificate_serial character varying, certificate_valid_from timestamp without time zone, certificate_valid_to timestamp without time zone, certificate_tax_id character varying, certificate_validated_at timestamp without time zone, hacienda_token_tested_at timestamp without time zone, hacienda_token_expires_at timestamp without time zone, validation_status character varying, validation_errors jsonb, is_active boolean, updated_at timestamp without time zone, clients_managed_by_central boolean, has_onvo_card boolean, onvo_customer_id character varying, onvo_payment_method_id character varying, onvo_card_brand character varying, onvo_card_last4 character varying, onvo_card_exp_month smallint, onvo_card_exp_year smallint, logo_url text, logo_public_id text)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT cs.id, cs.empresa_id, cs.legal_name, cs.commercial_name,
                       cs.tax_id, cs.tax_id_type, cs.province_code, cs.canton_code,
                       cs.district_code, cs.other_signs, cs.phone, cs.email,
                       cs.actividad_economica, cs.leyenda_tributaria,
                       cs.hacienda_environment,
                       (cs.hacienda_username_encrypted IS NOT NULL AND cs.hacienda_password_encrypted IS NOT NULL),
                       (cs.certificate_p12_encrypted IS NOT NULL),
                       cs.certificate_subject, cs.certificate_issuer, cs.certificate_serial,
                       cs.certificate_valid_from, cs.certificate_valid_to, cs.certificate_tax_id,
                       cs.certificate_validated_at, cs.hacienda_token_tested_at,
                       cs.hacienda_token_expires_at, cs.validation_status, cs.validation_errors,
                       cs.is_active, cs.updated_at, cs.clients_managed_by_central,
                       (cs.onvo_payment_method_id IS NOT NULL),
                       cs.onvo_customer_id, cs.onvo_payment_method_id,
                       cs.onvo_card_brand, cs.onvo_card_last4, cs.onvo_card_exp_month, cs.onvo_card_exp_year,
                       cs.logo_url, cs.logo_public_id
                FROM company_settings cs
                WHERE cs.empresa_id = p_empresa_id AND cs.deleted_at IS NULL
                LIMIT 1;
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
-- Name: sp_company_settings_set_onvo_card(bigint, character varying, character varying, character varying, character varying, smallint, smallint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_company_settings_set_onvo_card(p_empresa_id bigint, p_customer_id character varying, p_payment_method_id character varying, p_card_brand character varying, p_card_last4 character varying, p_card_exp_month smallint, p_card_exp_year smallint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INT;
            BEGIN
                UPDATE company_settings SET
                    onvo_customer_id       = p_customer_id,
                    onvo_payment_method_id = p_payment_method_id,
                    onvo_card_brand        = p_card_brand,
                    onvo_card_last4        = p_card_last4,
                    onvo_card_exp_month    = p_card_exp_month,
                    onvo_card_exp_year     = p_card_exp_year,
                    updated_at = NOW()
                WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END; $$;


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
-- Name: sp_consecutivo_ajustar(bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_consecutivo_ajustar(p_empresa_id bigint, p_id bigint, p_nuevo_valor bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE documento_consecutivos
       SET ultimo_consecutivo = p_nuevo_valor,
           updated_at         = NOW()
     WHERE id = p_id AND empresa_id = p_empresa_id;

    RETURN FOUND;
END;
$$;


--
-- Name: sp_consecutivo_listar(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_consecutivo_listar(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, sucursal_id bigint, terminal character varying, tipo_documento character varying, ultimo_consecutivo bigint, updated_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT dc.id, dc.empresa_id, dc.sucursal_id, dc.terminal,
           dc.tipo_documento, dc.ultimo_consecutivo, dc.updated_at
    FROM documento_consecutivos dc
    WHERE dc.empresa_id = p_empresa_id
    ORDER BY dc.sucursal_id, dc.terminal, dc.tipo_documento;
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
-- Name: sp_cotizacion_create(bigint, bigint, bigint, bigint, character varying, timestamp without time zone, date, character varying, text, character varying, character varying, numeric, bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, text, character varying, character varying, character varying, jsonb, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cotizacion_create(p_empresa_id bigint, p_sucursal_id bigint, p_user_id bigint, p_funcionario_id bigint, p_numero character varying, p_fecha_emision timestamp without time zone, p_fecha_vigencia date, p_condicion_venta character varying, p_condicion_venta_otros text, p_plazo_credito character varying, p_moneda character varying, p_tipo_cambio numeric, p_receptor_cliente_id bigint, p_receptor_nombre character varying, p_receptor_tipo_id character varying, p_receptor_numero_id character varying, p_receptor_nombre_comercial character varying, p_receptor_provincia character varying, p_receptor_canton character varying, p_receptor_distrito character varying, p_receptor_barrio character varying, p_receptor_otras_senas text, p_receptor_codigo_pais character varying, p_receptor_telefono character varying, p_receptor_correo character varying, p_lineas jsonb, p_total_serv_gravados numeric, p_total_serv_exentos numeric, p_total_serv_exonerado numeric, p_total_serv_no_sujeto numeric, p_total_merc_gravadas numeric, p_total_merc_exentas numeric, p_total_merc_exonerada numeric, p_total_merc_no_sujeta numeric, p_total_gravado numeric, p_total_exento numeric, p_total_exonerado numeric, p_total_no_sujeto numeric, p_total_venta numeric, p_total_descuentos numeric, p_total_venta_neta numeric, p_total_impuesto numeric, p_total_imp_asumido_emisor numeric, p_total_iva_devuelto numeric, p_total_otros_cargos numeric, p_total_comprobante numeric, p_notas text, p_otros_texto text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO cotizaciones (
                    empresa_id, sucursal_id, user_id, funcionario_id,
                    numero, fecha_emision, fecha_vigencia,
                    condicion_venta, condicion_venta_otros, plazo_credito,
                    moneda, tipo_cambio,
                    receptor_cliente_id, receptor_nombre,
                    receptor_tipo_id, receptor_numero_id,
                    receptor_nombre_comercial,
                    receptor_provincia, receptor_canton, receptor_distrito,
                    receptor_barrio, receptor_otras_senas,
                    receptor_codigo_pais, receptor_telefono, receptor_correo,
                    lineas,
                    total_serv_gravados, total_serv_exentos, total_serv_exonerado, total_serv_no_sujeto,
                    total_merc_gravadas, total_merc_exentas, total_merc_exonerada, total_merc_no_sujeta,
                    total_gravado, total_exento, total_exonerado, total_no_sujeto,
                    total_venta, total_descuentos, total_venta_neta,
                    total_impuesto, total_imp_asumido_emisor, total_iva_devuelto,
                    total_otros_cargos, total_comprobante,
                    notas, otros_texto,
                    estado
                ) VALUES (
                    p_empresa_id, p_sucursal_id, p_user_id, p_funcionario_id,
                    p_numero, p_fecha_emision, p_fecha_vigencia,
                    p_condicion_venta, p_condicion_venta_otros, p_plazo_credito,
                    p_moneda, p_tipo_cambio,
                    p_receptor_cliente_id, p_receptor_nombre,
                    p_receptor_tipo_id, p_receptor_numero_id,
                    p_receptor_nombre_comercial,
                    p_receptor_provincia, p_receptor_canton, p_receptor_distrito,
                    p_receptor_barrio, p_receptor_otras_senas,
                    p_receptor_codigo_pais, p_receptor_telefono, p_receptor_correo,
                    p_lineas,
                    p_total_serv_gravados, p_total_serv_exentos, p_total_serv_exonerado, p_total_serv_no_sujeto,
                    p_total_merc_gravadas, p_total_merc_exentas, p_total_merc_exonerada, p_total_merc_no_sujeta,
                    p_total_gravado, p_total_exento, p_total_exonerado, p_total_no_sujeto,
                    p_total_venta, p_total_descuentos, p_total_venta_neta,
                    p_total_impuesto, p_total_imp_asumido_emisor, p_total_iva_devuelto,
                    p_total_otros_cargos, p_total_comprobante,
                    p_notas, p_otros_texto,
                    'borrador'
                ) RETURNING id INTO v_id;
                RETURN v_id;
            END;
            $$;


--
-- Name: sp_cotizacion_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cotizacion_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, sucursal_id bigint, user_id bigint, funcionario_id bigint, numero character varying, fecha_emision timestamp without time zone, fecha_vigencia date, condicion_venta character varying, condicion_venta_otros text, plazo_credito character varying, moneda character varying, tipo_cambio numeric, receptor_cliente_id bigint, receptor_nombre character varying, receptor_tipo_id character varying, receptor_numero_id character varying, receptor_nombre_comercial character varying, receptor_provincia character varying, receptor_canton character varying, receptor_distrito character varying, receptor_barrio character varying, receptor_otras_senas text, receptor_codigo_pais character varying, receptor_telefono character varying, receptor_correo character varying, lineas jsonb, total_serv_gravados numeric, total_serv_exentos numeric, total_serv_exonerado numeric, total_serv_no_sujeto numeric, total_merc_gravadas numeric, total_merc_exentas numeric, total_merc_exonerada numeric, total_merc_no_sujeta numeric, total_gravado numeric, total_exento numeric, total_exonerado numeric, total_no_sujeto numeric, total_venta numeric, total_descuentos numeric, total_venta_neta numeric, total_impuesto numeric, total_imp_asumido_emisor numeric, total_iva_devuelto numeric, total_otros_cargos numeric, total_comprobante numeric, notas text, motivo_rechazo text, otros_texto text, estado character varying, aprobado_por bigint, aprobado_at timestamp without time zone, rechazado_at timestamp without time zone, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    c.id, c.empresa_id, c.sucursal_id, c.user_id, c.funcionario_id,
                    c.numero, c.fecha_emision, c.fecha_vigencia,
                    c.condicion_venta, c.condicion_venta_otros, c.plazo_credito,
                    c.moneda, c.tipo_cambio,
                    c.receptor_cliente_id, c.receptor_nombre,
                    c.receptor_tipo_id, c.receptor_numero_id,
                    c.receptor_nombre_comercial,
                    c.receptor_provincia, c.receptor_canton, c.receptor_distrito,
                    c.receptor_barrio, c.receptor_otras_senas,
                    c.receptor_codigo_pais, c.receptor_telefono, c.receptor_correo,
                    c.lineas,
                    c.total_serv_gravados, c.total_serv_exentos, c.total_serv_exonerado, c.total_serv_no_sujeto,
                    c.total_merc_gravadas, c.total_merc_exentas, c.total_merc_exonerada, c.total_merc_no_sujeta,
                    c.total_gravado, c.total_exento, c.total_exonerado, c.total_no_sujeto,
                    c.total_venta, c.total_descuentos, c.total_venta_neta,
                    c.total_impuesto, c.total_imp_asumido_emisor, c.total_iva_devuelto,
                    c.total_otros_cargos, c.total_comprobante,
                    c.notas, c.motivo_rechazo, c.otros_texto,
                    CASE
                        WHEN c.estado IN ('borrador','enviada')
                             AND c.fecha_vigencia IS NOT NULL
                             AND c.fecha_vigencia < CURRENT_DATE
                        THEN 'vencida'
                        ELSE c.estado
                    END AS estado,
                    c.aprobado_por, c.aprobado_at, c.rechazado_at,
                    c.created_at, c.updated_at
                FROM cotizaciones c
                WHERE c.id = p_id
                  AND c.empresa_id = p_empresa_id
                  AND c.deleted_at IS NULL;
            END;
            $$;


--
-- Name: sp_cotizacion_list(bigint, character varying, text, date, date, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cotizacion_list(p_empresa_id bigint, p_estado character varying DEFAULT NULL::character varying, p_search text DEFAULT NULL::text, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date, p_page integer DEFAULT 1, p_per_page integer DEFAULT 20) RETURNS TABLE(id bigint, numero character varying, fecha_emision timestamp without time zone, fecha_vigencia date, receptor_nombre character varying, receptor_numero_id character varying, moneda character varying, total_comprobante numeric, estado character varying, created_at timestamp without time zone, total_rows bigint)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    c.id, c.numero, c.fecha_emision, c.fecha_vigencia,
                    c.receptor_nombre, c.receptor_numero_id,
                    c.moneda, c.total_comprobante,
                    CASE
                        WHEN c.estado IN ('borrador','enviada')
                             AND c.fecha_vigencia IS NOT NULL
                             AND c.fecha_vigencia < CURRENT_DATE
                        THEN 'vencida'
                        ELSE c.estado
                    END AS estado,
                    c.created_at,
                    COUNT(*) OVER()::BIGINT AS total_rows
                FROM cotizaciones c
                WHERE c.empresa_id = p_empresa_id
                  AND c.deleted_at IS NULL
                  AND (
                        p_estado IS NULL
                        OR (p_estado = 'vencida' AND c.estado IN ('borrador','enviada')
                            AND c.fecha_vigencia IS NOT NULL AND c.fecha_vigencia < CURRENT_DATE)
                        OR (p_estado <> 'vencida' AND c.estado = p_estado
                            AND NOT (c.estado IN ('borrador','enviada')
                                     AND c.fecha_vigencia IS NOT NULL AND c.fecha_vigencia < CURRENT_DATE))
                      )
                  AND (p_fecha_desde IS NULL OR c.fecha_emision::DATE >= p_fecha_desde)
                  AND (p_fecha_hasta IS NULL OR c.fecha_emision::DATE <= p_fecha_hasta)
                  AND (p_search IS NULL
                       OR c.numero ILIKE '%' || p_search || '%'
                       OR c.receptor_nombre ILIKE '%' || p_search || '%'
                       OR c.receptor_numero_id ILIKE '%' || p_search || '%')
                ORDER BY c.created_at DESC
                LIMIT p_per_page OFFSET (p_page - 1) * p_per_page;
            END;
            $$;


--
-- Name: sp_cotizacion_marcar_convertida(bigint, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cotizacion_marcar_convertida(p_id bigint, p_empresa_id bigint, p_tipo character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE cotizaciones SET
                    estado     = CASE WHEN p_tipo = 'parcial' THEN 'convertida_parcial' ELSE 'convertida' END,
                    updated_at = NOW()
                WHERE id = p_id
                  AND empresa_id = p_empresa_id
                  AND estado = 'aprobada'
                  AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_cotizacion_next_numero(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cotizacion_next_numero(p_empresa_id bigint) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_next   BIGINT;
                v_numero VARCHAR(20);
            BEGIN
                INSERT INTO cotizacion_consecutivos (empresa_id, ultimo_numero)
                VALUES (p_empresa_id, 1)
                ON CONFLICT (empresa_id)
                DO UPDATE SET
                    ultimo_numero = cotizacion_consecutivos.ultimo_numero + 1,
                    updated_at = NOW()
                RETURNING ultimo_numero INTO v_next;

                v_numero := 'COT-' || LPAD(v_next::VARCHAR, 7, '0');
                RETURN v_numero;
            END;
            $$;


--
-- Name: sp_cotizacion_set_estado(bigint, bigint, character varying, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cotizacion_set_estado(p_id bigint, p_empresa_id bigint, p_nuevo_estado character varying, p_user_id bigint, p_motivo_rechazo text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_estado_actual VARCHAR;
                v_ok            BOOLEAN := FALSE;
            BEGIN
                SELECT estado INTO v_estado_actual
                FROM cotizaciones
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL
                FOR UPDATE;

                IF v_estado_actual IS NULL THEN
                    RETURN FALSE;
                END IF;

                IF p_nuevo_estado = 'enviada' AND v_estado_actual = 'borrador' THEN
                    v_ok := TRUE;
                ELSIF p_nuevo_estado = 'aprobada' AND v_estado_actual = 'enviada' THEN
                    v_ok := TRUE;
                ELSIF p_nuevo_estado = 'rechazada' AND v_estado_actual = 'enviada' THEN
                    v_ok := TRUE;
                END IF;

                IF NOT v_ok THEN
                    RETURN FALSE;
                END IF;

                UPDATE cotizaciones SET
                    estado         = p_nuevo_estado,
                    motivo_rechazo = CASE WHEN p_nuevo_estado = 'rechazada' THEN p_motivo_rechazo ELSE motivo_rechazo END,
                    aprobado_por   = CASE WHEN p_nuevo_estado = 'aprobada' THEN p_user_id ELSE aprobado_por END,
                    aprobado_at    = CASE WHEN p_nuevo_estado = 'aprobada' THEN NOW() ELSE aprobado_at END,
                    rechazado_at   = CASE WHEN p_nuevo_estado = 'rechazada' THEN NOW() ELSE rechazado_at END,
                    updated_at     = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id;

                RETURN TRUE;
            END;
            $$;


--
-- Name: sp_cotizacion_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cotizacion_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE cotizaciones
                SET deleted_at = NOW(), updated_at = NOW()
                WHERE id = p_id
                  AND empresa_id = p_empresa_id
                  AND estado = 'borrador'
                  AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_cotizacion_update(bigint, bigint, bigint, timestamp without time zone, date, character varying, text, character varying, character varying, numeric, bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, text, character varying, character varying, character varying, jsonb, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cotizacion_update(p_id bigint, p_empresa_id bigint, p_funcionario_id bigint, p_fecha_emision timestamp without time zone, p_fecha_vigencia date, p_condicion_venta character varying, p_condicion_venta_otros text, p_plazo_credito character varying, p_moneda character varying, p_tipo_cambio numeric, p_receptor_cliente_id bigint, p_receptor_nombre character varying, p_receptor_tipo_id character varying, p_receptor_numero_id character varying, p_receptor_nombre_comercial character varying, p_receptor_provincia character varying, p_receptor_canton character varying, p_receptor_distrito character varying, p_receptor_barrio character varying, p_receptor_otras_senas text, p_receptor_codigo_pais character varying, p_receptor_telefono character varying, p_receptor_correo character varying, p_lineas jsonb, p_total_serv_gravados numeric, p_total_serv_exentos numeric, p_total_serv_exonerado numeric, p_total_serv_no_sujeto numeric, p_total_merc_gravadas numeric, p_total_merc_exentas numeric, p_total_merc_exonerada numeric, p_total_merc_no_sujeta numeric, p_total_gravado numeric, p_total_exento numeric, p_total_exonerado numeric, p_total_no_sujeto numeric, p_total_venta numeric, p_total_descuentos numeric, p_total_venta_neta numeric, p_total_impuesto numeric, p_total_imp_asumido_emisor numeric, p_total_iva_devuelto numeric, p_total_otros_cargos numeric, p_total_comprobante numeric, p_notas text, p_otros_texto text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE cotizaciones SET
                    funcionario_id              = p_funcionario_id,
                    fecha_emision               = p_fecha_emision,
                    fecha_vigencia              = p_fecha_vigencia,
                    condicion_venta             = p_condicion_venta,
                    condicion_venta_otros       = p_condicion_venta_otros,
                    plazo_credito               = p_plazo_credito,
                    moneda                      = p_moneda,
                    tipo_cambio                 = p_tipo_cambio,
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
                    lineas                      = p_lineas,
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
                    notas                       = p_notas,
                    otros_texto                 = p_otros_texto,
                    updated_at                  = NOW()
                WHERE id = p_id
                  AND empresa_id = p_empresa_id
                  AND estado IN ('borrador','enviada')
                  AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_cuenta_por_cobrar_create(bigint, bigint, bigint, numeric, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cuenta_por_cobrar_create(p_empresa_id bigint, p_documento_id bigint, p_cliente_id bigint, p_monto_total numeric, p_dias_credito integer DEFAULT NULL::integer) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_id BIGINT;
    v_dias INTEGER;
    v_fecha_emision TIMESTAMP;
    v_condicion_venta VARCHAR;
    v_origen_venta VARCHAR;
BEGIN
    SELECT d.fecha_emision, d.condicion_venta INTO v_fecha_emision, v_condicion_venta
    FROM documentos_electronicos d WHERE d.id = p_documento_id;

    v_origen_venta := CASE WHEN v_condicion_venta = '04' THEN 'apartado' ELSE 'credito' END;

    IF p_dias_credito IS NULL THEN
        SELECT c.dias_credito INTO v_dias FROM clients c WHERE c.id = p_cliente_id;
    ELSE
        v_dias := p_dias_credito;
    END IF;

    INSERT INTO cuentas_por_cobrar (
        empresa_id, documento_id, cliente_id,
        monto_total, saldo_pendiente,
        fecha_emision, fecha_vencimiento, estado, origen_venta
    ) VALUES (
        p_empresa_id, p_documento_id, p_cliente_id,
        p_monto_total, p_monto_total,
        v_fecha_emision, v_fecha_emision + (COALESCE(v_dias,0) || ' days')::INTERVAL, 'vigente', v_origen_venta
    ) RETURNING id INTO v_id;

    RETURN v_id;
END; $$;


--
-- Name: sp_documento_ajustar_inventario(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_ajustar_inventario(p_documento_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_doc            RECORD;
                v_tipo_mov       VARCHAR;
                v_linea          RECORD;
                v_delta          NUMERIC;
                v_stock_antes    NUMERIC;
                v_stock_despues  NUMERIC;
            BEGIN
                -- Idempotente: si ya se generaron movimientos para este documento, no repetir.
                IF EXISTS (SELECT 1 FROM movimientos_inventario WHERE documento_id = p_documento_id) THEN
                    RETURN;
                END IF;

                SELECT id, empresa_id, tipo_documento, clave, numero_consecutivo, user_id
                  INTO v_doc
                  FROM documentos_electronicos
                 WHERE id = p_documento_id;

                IF NOT FOUND THEN
                    RETURN;
                END IF;

                -- Factura (01) y Tiquete (04): salida por venta.
                -- Nota de Débito (02): salida adicional (aumenta lo vendido).
                -- Nota de Crédito (03): entrada por devolución.
                v_tipo_mov := CASE
                    WHEN v_doc.tipo_documento IN ('01', '04', '02') THEN 'venta'
                    WHEN v_doc.tipo_documento = '03'                THEN 'devolucion'
                    ELSE NULL
                END;

                IF v_tipo_mov IS NULL THEN
                    RETURN;
                END IF;

                FOR v_linea IN
                    SELECT dl.producto_id, dl.bodega_id, dl.cantidad
                      FROM documento_lineas dl
                      JOIN productos p ON p.id = dl.producto_id
                     WHERE dl.documento_id = p_documento_id
                       AND dl.producto_id IS NOT NULL
                       AND dl.bodega_id IS NOT NULL
                       AND dl.cantidad > 0
                       AND p.type = 'product'
                LOOP
                    v_delta := CASE WHEN v_tipo_mov = 'venta' THEN -v_linea.cantidad ELSE v_linea.cantidad END;

                    SELECT COALESCE(stock, 0) INTO v_stock_antes
                      FROM bodega_productos
                     WHERE bodega_id = v_linea.bodega_id AND producto_id = v_linea.producto_id;
                    v_stock_antes := COALESCE(v_stock_antes, 0);
                    v_stock_despues := v_stock_antes + v_delta;

                    PERFORM sp_bodega_producto_ajustar_stock(v_linea.bodega_id, v_linea.producto_id, v_delta);

                    INSERT INTO movimientos_inventario (
                        empresa_id, tipo, bodega_origen_id, bodega_destino_id,
                        producto_id, cantidad, stock_antes, stock_despues,
                        documento_id, referencia, notas, user_id
                    ) VALUES (
                        v_doc.empresa_id, v_tipo_mov, v_linea.bodega_id, NULL,
                        v_linea.producto_id, v_linea.cantidad, v_stock_antes, v_stock_despues,
                        v_doc.id, COALESCE(v_doc.clave, v_doc.numero_consecutivo),
                        'Generado automáticamente por documento ' || v_doc.tipo_documento,
                        v_doc.user_id
                    );
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


SET default_tablespace = '';

SET default_table_access_method = heap;

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
    pending_cxc_aplicaciones jsonb,
    cotizacion_id bigint,
    pending_adelanto_aplicaciones jsonb,
    adelanto_recibo_id bigint,
    adelanto_error text,
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
        AND tipo_documento IN ('01','04','09')
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

CREATE FUNCTION public.sp_documento_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, sucursal_id bigint, caja_id bigint, user_id bigint, tipo_documento character varying, clave character varying, numero_consecutivo character varying, sucursal_codigo character varying, terminal character varying, consecutivo_comercio bigint, situacion_comprobante smallint, fecha_emision timestamp without time zone, version character varying, condicion_venta character varying, condicion_venta_otros text, plazo_credito character varying, codigo_actividad_emisor character varying, codigo_actividad_receptor character varying, leyenda_tributaria text, proveedor_sistemas character varying, numero_seguridad character varying, emisor_nombre character varying, emisor_tipo_id character varying, emisor_numero_id character varying, emisor_nombre_comercial character varying, emisor_registro_fiscal character varying, emisor_provincia character varying, emisor_canton character varying, emisor_distrito character varying, emisor_barrio character varying, emisor_otras_senas text, emisor_codigo_pais character varying, emisor_telefono character varying, emisor_correos jsonb, receptor_cliente_id bigint, receptor_nombre character varying, receptor_tipo_id character varying, receptor_numero_id character varying, receptor_nombre_comercial character varying, receptor_provincia character varying, receptor_canton character varying, receptor_distrito character varying, receptor_barrio character varying, receptor_otras_senas text, receptor_codigo_pais character varying, receptor_telefono character varying, receptor_correo character varying, moneda character varying, tipo_cambio numeric, total_serv_gravados numeric, total_serv_exentos numeric, total_serv_exonerado numeric, total_serv_no_sujeto numeric, total_merc_gravadas numeric, total_merc_exentas numeric, total_merc_exonerada numeric, total_merc_no_sujeta numeric, total_gravado numeric, total_exento numeric, total_exonerado numeric, total_no_sujeto numeric, total_venta numeric, total_descuentos numeric, total_venta_neta numeric, total_impuesto numeric, total_imp_asumido_emisor numeric, total_iva_devuelto numeric, total_otros_cargos numeric, total_comprobante numeric, otros_texto text, otros_contenido text, estado character varying, xml_firmado text, xml_respuesta text, qr_url text, hacienda_mensaje text, hacienda_detalle_mensaje text, hacienda_attempts smallint, hacienda_last_attempt_at timestamp without time zone, enviado_at timestamp without time zone, aceptado_at timestamp without time zone, rechazado_at timestamp without time zone, created_at timestamp without time zone, updated_at timestamp without time zone, lineas jsonb, otros_cargos jsonb, medios_pago jsonb, referencias jsonb, desglose_impuesto jsonb, pending_adelanto_aplicaciones jsonb, adelanto_recibo_id bigint, adelanto_error text)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    d.id, d.empresa_id, d.sucursal_id, d.caja_id, d.user_id,
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
                        SELECT jsonb_agg(
                            jsonb_build_object(
                                'id', l.id,
                                'numero_linea', l.numero_linea,
                                'bodega_id', l.bodega_id,
                                'funcionario', l.funcionario,
                                'producto_id', l.producto_id,
                                'codigo_actividad', l.codigo_actividad,
                                'cabys_code', l.cabys_code,
                                'partida_arancelaria', l.partida_arancelaria,
                                'cantidad', l.cantidad,
                                'unidad_medida', l.unidad_medida,
                                'tipo_unidad', l.tipo_unidad,
                                'tipo_transaccion', l.tipo_transaccion,
                                'unidad_medida_comercial', l.unidad_medida_comercial,
                                'detalle', l.detalle,
                                'registro_medicamento', l.registro_medicamento,
                                'forma_farmaceutica', l.forma_farmaceutica,
                                'precio_unitario', l.precio_unitario,
                                'monto_total', l.monto_total,
                                'subtotal', l.subtotal,
                                'iva_cobrado_fabrica', l.iva_cobrado_fabrica,
                                'base_imponible', l.base_imponible,
                                'impuesto_asumido_emisor', l.impuesto_asumido_emisor,
                                'impuesto_neto', l.impuesto_neto,
                                'monto_total_linea', l.monto_total_linea,
                                'codigos_comerciales', l.codigos_comerciales,
                                'numeros_serie', l.numeros_serie,
                                'descuentos', COALESCE((
                                    SELECT jsonb_agg(to_jsonb(dd))
                                    FROM documento_linea_descuentos dd WHERE dd.linea_id = l.id
                                ), '[]'::jsonb),
                                'impuestos', COALESCE((
                                    SELECT jsonb_agg(to_jsonb(i))
                                    FROM documento_linea_impuestos i WHERE i.linea_id = l.id
                                ), '[]'::jsonb),
                                'surtidos', COALESCE((
                                    SELECT jsonb_agg(to_jsonb(s))
                                    FROM documento_linea_surtidos s WHERE s.linea_id = l.id
                                ), '[]'::jsonb)
                            ) ORDER BY l.numero_linea
                        )
                        FROM documento_lineas l WHERE l.documento_id = d.id
                    ), '[]'::jsonb),
                    COALESCE((
                        SELECT jsonb_agg(to_jsonb(oc))
                        FROM documento_otros_cargos oc WHERE oc.documento_id = d.id
                    ), '[]'::jsonb),
                    COALESCE((
                        SELECT jsonb_agg(to_jsonb(mp))
                        FROM documento_medios_pago mp WHERE mp.documento_id = d.id
                    ), '[]'::jsonb),
                    COALESCE((
                        SELECT jsonb_agg(to_jsonb(r))
                        FROM documento_referencias r WHERE r.documento_id = d.id
                    ), '[]'::jsonb),
                    COALESCE((
                        SELECT jsonb_agg(to_jsonb(di))
                        FROM documento_desglose_impuesto di WHERE di.documento_id = d.id
                    ), '[]'::jsonb),
                    d.pending_adelanto_aplicaciones, d.adelanto_recibo_id, d.adelanto_error
                FROM documentos_electronicos d
                WHERE d.id = p_id
                  AND (p_empresa_id = 0 OR d.empresa_id = p_empresa_id)
                  AND d.deleted_at IS NULL;
            END;
            $$;


--
-- Name: sp_documento_list(bigint, character varying, character varying, text, date, date, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_list(p_empresa_id bigint, p_tipo_documento character varying DEFAULT NULL::character varying, p_estado character varying DEFAULT NULL::character varying, p_search text DEFAULT NULL::text, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date, p_page integer DEFAULT 1, p_per_page integer DEFAULT 20) RETURNS TABLE(id bigint, tipo_documento character varying, clave character varying, numero_consecutivo character varying, fecha_emision timestamp without time zone, receptor_nombre character varying, receptor_numero_id character varying, moneda character varying, total_comprobante numeric, estado character varying, aceptado_at timestamp without time zone, created_at timestamp without time zone, condicion_venta character varying, receptor_cliente_id bigint, total_rows bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        d.id, d.tipo_documento, d.clave, d.numero_consecutivo,
        d.fecha_emision, d.receptor_nombre, d.receptor_numero_id,
        d.moneda, d.total_comprobante, d.estado, d.aceptado_at,
        d.created_at, d.condicion_venta, d.receptor_cliente_id,
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
                SET estado                = 'procesando',
                    hacienda_attempts     = 0,
                    hacienda_poll_attempts = 0,
                    hacienda_mensaje      = NULL,
                    updated_at            = NOW()
                WHERE id         = p_id
                  AND empresa_id = p_empresa_id
                  AND estado     = 'pendiente_manual';

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
-- Name: sp_emp_tipo_cambio_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_emp_tipo_cambio_delete(p_id bigint, p_empresa_id bigint) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE v_deleted int;
BEGIN
    DELETE FROM empresa_tipo_cambios WHERE id=p_id AND empresa_id=p_empresa_id;
    GET DIAGNOSTICS v_deleted = ROW_COUNT; RETURN v_deleted;
END; $$;


--
-- Name: sp_emp_tipo_cambio_list(bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_emp_tipo_cambio_list(p_empresa_id bigint, p_limit integer DEFAULT 60) RETURNS TABLE(id bigint, empresa_id bigint, fecha date, compra numeric, venta numeric, fuente character varying, created_by bigint, created_at timestamp with time zone, updated_at timestamp with time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT tc.id, tc.empresa_id, tc.fecha, tc.compra, tc.venta,
           tc.fuente, tc.created_by, tc.created_at, tc.updated_at
    FROM empresa_tipo_cambios tc
    WHERE tc.empresa_id = p_empresa_id
    ORDER BY tc.fecha DESC
    LIMIT p_limit;
END;
$$;


--
-- Name: sp_emp_tipo_cambio_upsert(bigint, date, numeric, numeric, character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_emp_tipo_cambio_upsert(p_empresa_id bigint, p_fecha date, p_compra numeric, p_venta numeric, p_fuente character varying DEFAULT 'Manual'::character varying, p_created_by bigint DEFAULT NULL::bigint) RETURNS TABLE(id bigint, empresa_id bigint, fecha date, compra numeric, venta numeric, fuente character varying, created_by bigint, created_at timestamp with time zone, updated_at timestamp with time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY INSERT INTO empresa_tipo_cambios AS e (empresa_id, fecha, compra, venta, fuente, created_by)
    VALUES (p_empresa_id, p_fecha, p_compra, p_venta, p_fuente, p_created_by)
    ON CONFLICT ON CONSTRAINT uq_emp_tipo_cambio DO UPDATE
        SET compra=EXCLUDED.compra, venta=EXCLUDED.venta, fuente=EXCLUDED.fuente, updated_at=now()
    RETURNING e.id, e.empresa_id, e.fecha, e.compra, e.venta, e.fuente, e.created_by, e.created_at, e.updated_at;
END;
$$;


--
-- Name: sp_emp_tipo_cambio_vigente(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_emp_tipo_cambio_vigente(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, fecha date, compra numeric, venta numeric, fuente character varying, created_by bigint, created_at timestamp with time zone, updated_at timestamp with time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT tc.id, tc.empresa_id, tc.fecha, tc.compra, tc.venta,
           tc.fuente, tc.created_by, tc.created_at, tc.updated_at
    FROM empresa_tipo_cambios tc
    WHERE tc.empresa_id = p_empresa_id
      AND tc.fecha <= CURRENT_DATE
    ORDER BY tc.fecha DESC
    LIMIT 1;
END;
$$;


--
-- Name: sp_empresa_condicion_venta_delete(integer, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_condicion_venta_delete(p_empresa_id integer, p_codigo character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                DELETE FROM empresa_condicion_ventas
                WHERE empresa_id = p_empresa_id AND codigo = p_codigo AND es_default = false;
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
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT * FROM empresa_hacienda_config
                WHERE empresa_id = p_empresa_id AND deleted_at IS NULL
                LIMIT 1;
            END;
            $$;


--
-- Name: sp_empresa_hacienda_save_certificado(bigint, text, text, character varying, date, date, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_hacienda_save_certificado(p_empresa_id bigint, p_cert_b64 text, p_cert_pin text, p_cert_cn character varying, p_fecha_inicio date, p_fecha_vence date, p_valido boolean, p_updated_by text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                UPDATE empresa_hacienda_config SET
                    certificado_p12           = p_cert_b64,
                    certificado_pin           = p_cert_pin,
                    certificado_cn            = p_cert_cn,
                    certificado_fecha_inicio  = p_fecha_inicio,
                    certificado_fecha_vence   = p_fecha_vence,
                    certificado_valido        = p_valido,
                    certificado_verificado_at = NOW(),
                    updated_by                = p_updated_by,
                    updated_at                = NOW()
                WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;
            END;
            $$;


--
-- Name: sp_empresa_hacienda_save_credenciales(bigint, character varying, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_hacienda_save_credenciales(p_empresa_id bigint, p_usuario character varying, p_contrasena text, p_updated_by text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                UPDATE empresa_hacienda_config SET
                    hacienda_usuario            = p_usuario,
                    hacienda_contrasena         = p_contrasena,
                    credenciales_validas        = FALSE,
                    credenciales_verificadas_at = NULL,
                    updated_by                  = p_updated_by,
                    updated_at                  = NOW()
                WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;
            END;
            $$;


--
-- Name: sp_empresa_hacienda_save_info(bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, text, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_hacienda_save_info(p_empresa_id bigint, p_tipo_id character varying, p_numero_id character varying, p_nombre_emisor character varying, p_nombre_comercial character varying, p_codigo_pais character varying, p_codigo_actividad character varying, p_telefono character varying, p_correo character varying, p_provincia character varying, p_canton character varying, p_distrito character varying, p_barrio character varying, p_otras_senas text, p_ambiente character varying, p_updated_by text) RETURNS SETOF public.empresa_hacienda_config
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                INSERT INTO empresa_hacienda_config (
                    empresa_id, tipo_identificacion, numero_identificacion,
                    nombre_emisor, nombre_comercial, codigo_pais, codigo_actividad,
                    telefono, correo_electronico, provincia, canton, distrito, barrio,
                    otras_senas, hacienda_ambiente, created_by, updated_by
                ) VALUES (
                    p_empresa_id, p_tipo_id, p_numero_id,
                    p_nombre_emisor, p_nombre_comercial, p_codigo_pais, p_codigo_actividad,
                    p_telefono, p_correo, p_provincia, p_canton, p_distrito, p_barrio,
                    p_otras_senas, p_ambiente, p_updated_by, p_updated_by
                )
                ON CONFLICT (empresa_id) DO UPDATE SET
                    tipo_identificacion   = EXCLUDED.tipo_identificacion,
                    numero_identificacion = EXCLUDED.numero_identificacion,
                    nombre_emisor         = EXCLUDED.nombre_emisor,
                    nombre_comercial      = EXCLUDED.nombre_comercial,
                    codigo_pais           = EXCLUDED.codigo_pais,
                    codigo_actividad      = EXCLUDED.codigo_actividad,
                    telefono              = EXCLUDED.telefono,
                    correo_electronico    = EXCLUDED.correo_electronico,
                    provincia             = EXCLUDED.provincia,
                    canton                = EXCLUDED.canton,
                    distrito              = EXCLUDED.distrito,
                    barrio                = EXCLUDED.barrio,
                    otras_senas           = EXCLUDED.otras_senas,
                    hacienda_ambiente     = EXCLUDED.hacienda_ambiente,
                    updated_by            = p_updated_by,
                    updated_at            = NOW();

                RETURN QUERY SELECT * FROM empresa_hacienda_config WHERE empresa_id = p_empresa_id;
            END;
            $$;


--
-- Name: sp_empresa_hacienda_set_credenciales_status(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_hacienda_set_credenciales_status(p_empresa_id bigint, p_validas boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                UPDATE empresa_hacienda_config SET
                    credenciales_validas        = p_validas,
                    credenciales_verificadas_at = NOW(),
                    updated_at                  = NOW()
                WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;
            END;
            $$;


--
-- Name: sp_empresa_tarifa_impuesto_create(bigint, character varying, character varying, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tarifa_impuesto_create(p_empresa_id bigint, p_codigo character varying, p_tarifa_impuesto character varying, p_tarifa numeric) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO empresa_tarifas_impuesto(empresa_id, codigo, tarifa_impuesto, tarifa)
    VALUES (p_empresa_id, p_codigo, p_tarifa_impuesto, p_tarifa)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;


--
-- Name: sp_empresa_tarifa_impuesto_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tarifa_impuesto_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE empresa_tarifas_impuesto SET deleted_at = NOW(), updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id
      AND deleted_at IS NULL AND is_default = FALSE;
    RETURN FOUND;
END;
$$;


--
-- Name: sp_empresa_tarifa_impuesto_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tarifa_impuesto_list(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, codigo character varying, tarifa_impuesto character varying, tarifa numeric, is_default boolean, is_active boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT t.id, t.empresa_id, t.codigo, t.tarifa_impuesto, t.tarifa,
           t.is_default, t.is_active, t.created_at, t.updated_at
    FROM empresa_tarifas_impuesto t
    WHERE t.empresa_id = p_empresa_id AND t.deleted_at IS NULL
    ORDER BY t.is_default DESC, t.codigo;
END;
$$;


--
-- Name: sp_empresa_tarifa_impuesto_set_default(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tarifa_impuesto_set_default(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE empresa_tarifas_impuesto SET is_default = FALSE, updated_at = NOW()
    WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;
    UPDATE empresa_tarifas_impuesto SET is_default = TRUE, updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END;
$$;


--
-- Name: sp_empresa_tipo_descuento_create(bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tipo_descuento_create(p_empresa_id bigint, p_codigo character varying, p_tipo_descuento character varying) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO empresa_tipos_descuento(empresa_id, codigo, tipo_descuento)
    VALUES (p_empresa_id, p_codigo, p_tipo_descuento)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;


--
-- Name: sp_empresa_tipo_descuento_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tipo_descuento_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE empresa_tipos_descuento SET deleted_at = NOW(), updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id
      AND deleted_at IS NULL AND is_default = FALSE;
    RETURN FOUND;
END;
$$;


--
-- Name: sp_empresa_tipo_descuento_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tipo_descuento_list(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, codigo character varying, tipo_descuento character varying, is_default boolean, is_active boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT t.id, t.empresa_id, t.codigo, t.tipo_descuento,
           t.is_default, t.is_active, t.created_at, t.updated_at
    FROM empresa_tipos_descuento t
    WHERE t.empresa_id = p_empresa_id AND t.deleted_at IS NULL
    ORDER BY t.is_default DESC, t.codigo;
END;
$$;


--
-- Name: sp_empresa_tipo_descuento_set_default(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tipo_descuento_set_default(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE empresa_tipos_descuento SET is_default = FALSE, updated_at = NOW()
    WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;
    UPDATE empresa_tipos_descuento SET is_default = TRUE, updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END;
$$;


--
-- Name: sp_empresa_tipo_impuesto_create(bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tipo_impuesto_create(p_empresa_id bigint, p_codigo character varying, p_nombre_impuesto character varying) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO empresa_tipos_impuesto(empresa_id, codigo, nombre_impuesto)
    VALUES (p_empresa_id, p_codigo, p_nombre_impuesto)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;


--
-- Name: sp_empresa_tipo_impuesto_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tipo_impuesto_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE empresa_tipos_impuesto SET deleted_at = NOW(), updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id
      AND deleted_at IS NULL AND is_default = FALSE;
    RETURN FOUND;
END;
$$;


--
-- Name: sp_empresa_tipo_impuesto_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tipo_impuesto_list(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, codigo character varying, nombre_impuesto character varying, is_default boolean, is_active boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT t.id, t.empresa_id, t.codigo, t.nombre_impuesto,
           t.is_default, t.is_active, t.created_at, t.updated_at
    FROM empresa_tipos_impuesto t
    WHERE t.empresa_id = p_empresa_id AND t.deleted_at IS NULL
    ORDER BY t.is_default DESC, t.codigo;
END;
$$;


--
-- Name: sp_empresa_tipo_impuesto_set_default(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_empresa_tipo_impuesto_set_default(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE empresa_tipos_impuesto SET is_default = FALSE, updated_at = NOW()
    WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;
    UPDATE empresa_tipos_impuesto SET is_default = TRUE, updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END;
$$;


--
-- Name: sp_factura_aplicar_adelantos(bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_aplicar_adelantos(p_documento_id bigint, p_monto numeric) RETURNS numeric
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_cxc            RECORD;
                v_ad             RECORD;
                v_restante       NUMERIC := ROUND(COALESCE(p_monto, 0), 2);
                v_aplicado_total NUMERIC := 0;
                v_aplicar        NUMERIC;
            BEGIN
                IF v_restante <= 0 THEN
                    RETURN 0;
                END IF;

                SELECT * INTO v_cxc
                FROM cuentas_por_cobrar
                WHERE documento_id = p_documento_id
                FOR UPDATE;

                IF v_cxc IS NULL THEN
                    RAISE EXCEPTION 'No existe cuenta por cobrar para el documento %', p_documento_id;
                END IF;

                IF v_restante > v_cxc.saldo_pendiente THEN
                    v_restante := v_cxc.saldo_pendiente;
                END IF;

                FOR v_ad IN
                    SELECT id, saldo_disponible, documento_id AS ra_documento_id
                    FROM recibos_adelanto
                    WHERE cliente_id = v_cxc.cliente_id
                      AND empresa_id = v_cxc.empresa_id
                      AND estado = 'disponible'
                      AND saldo_disponible > 0
                    ORDER BY created_at ASC
                    FOR UPDATE
                LOOP
                    EXIT WHEN v_restante <= 0;
                    v_aplicar := LEAST(v_ad.saldo_disponible, v_restante);

                    INSERT INTO recibos_adelanto_aplicaciones (recibo_adelanto_id, documento_id, monto_aplicado)
                    VALUES (v_ad.id, p_documento_id, v_aplicar);

                    UPDATE recibos_adelanto
                    SET saldo_disponible = saldo_disponible - v_aplicar,
                        estado = CASE WHEN saldo_disponible - v_aplicar <= 0 THEN 'agotado' ELSE estado END,
                        updated_at = NOW()
                    WHERE id = v_ad.id;

                    -- Historial del estado de cuenta: el documento que abona es el RA original
                    INSERT INTO documento_cxc_aplicaciones (documento_id, cuenta_por_cobrar_id, monto_aplicado)
                    VALUES (v_ad.ra_documento_id, v_cxc.id, v_aplicar);

                    v_restante       := v_restante - v_aplicar;
                    v_aplicado_total := v_aplicado_total + v_aplicar;
                END LOOP;

                IF v_aplicado_total > 0 THEN
                    UPDATE cuentas_por_cobrar
                    SET saldo_pendiente = saldo_pendiente - v_aplicado_total,
                        estado = CASE WHEN saldo_pendiente - v_aplicado_total <= 0 THEN 'pagada' ELSE estado END,
                        updated_at = NOW()
                    WHERE id = v_cxc.id;

                    PERFORM sp_refrescar_estado_credito_cliente(v_cxc.cliente_id);
                END IF;

                RETURN v_aplicado_total;
            END; $$;


--
-- Name: sp_factura_recibida_create(bigint, character varying, character varying, character varying, timestamp without time zone, character varying, character varying, character varying, character varying, character varying, character varying, character varying, numeric, numeric, text, character varying, text, character varying, smallint, bigint, jsonb, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_create(p_empresa_id bigint, p_clave character varying, p_tipo_documento character varying, p_numero_consecutivo character varying, p_fecha_emision timestamp without time zone, p_emisor_tipo_id character varying, p_emisor_numero_id character varying, p_emisor_nombre character varying, p_receptor_tipo_id character varying, p_receptor_numero_id character varying, p_receptor_nombre character varying, p_moneda character varying, p_total_comprobante numeric, p_total_impuesto numeric, p_xml_recibido text, p_estado_hacienda character varying, p_hacienda_mensaje text, p_condicion_pago character varying DEFAULT 'contado'::character varying, p_plazo_credito_dias smallint DEFAULT NULL::smallint, p_factura_referencia_id bigint DEFAULT NULL::bigint, p_referencias_pago jsonb DEFAULT '[]'::jsonb, p_monto_referencia_aplicado numeric DEFAULT NULL::numeric) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_id                 BIGINT;
                v_existing_estado    VARCHAR;
                v_fecha_vencimiento  DATE;
            BEGIN
                SELECT estado_recepcion INTO v_existing_estado
                FROM facturas_recibidas
                WHERE empresa_id = p_empresa_id AND clave = p_clave;

                IF FOUND AND v_existing_estado IN ('aceptado', 'aceptado_parcial') THEN
                    RAISE EXCEPTION 'YA_ACEPTADA: Ya existe un comprobante aceptado con esta clave (%).', p_clave;
                END IF;

                v_fecha_vencimiento := CASE
                    WHEN p_condicion_pago = 'credito' AND p_plazo_credito_dias IS NOT NULL
                    THEN (p_fecha_emision::date + (p_plazo_credito_dias || ' days')::interval)::date
                    ELSE NULL
                END;

                INSERT INTO facturas_recibidas(
                    empresa_id, clave, tipo_documento, numero_consecutivo_emisor,
                    fecha_emision, emisor_tipo_id, emisor_numero_id, emisor_nombre,
                    receptor_tipo_id, receptor_numero_id, receptor_nombre,
                    moneda, total_comprobante, total_impuesto,
                    xml_recibido, estado_hacienda, hacienda_mensaje,
                    condicion_pago, plazo_credito_dias, fecha_vencimiento, factura_referencia_id,
                    referencias_pago, monto_referencia_aplicado
                )
                VALUES(
                    p_empresa_id, p_clave, p_tipo_documento, p_numero_consecutivo,
                    p_fecha_emision, p_emisor_tipo_id, p_emisor_numero_id, p_emisor_nombre,
                    p_receptor_tipo_id, p_receptor_numero_id, p_receptor_nombre,
                    p_moneda, p_total_comprobante, p_total_impuesto,
                    p_xml_recibido, p_estado_hacienda, p_hacienda_mensaje,
                    p_condicion_pago, p_plazo_credito_dias, v_fecha_vencimiento, p_factura_referencia_id,
                    p_referencias_pago, p_monto_referencia_aplicado
                )
                ON CONFLICT (empresa_id, clave) WHERE (clave IS NOT NULL)
                DO UPDATE SET
                    estado_hacienda            = EXCLUDED.estado_hacienda,
                    hacienda_mensaje           = EXCLUDED.hacienda_mensaje,
                    condicion_pago             = EXCLUDED.condicion_pago,
                    plazo_credito_dias         = EXCLUDED.plazo_credito_dias,
                    fecha_vencimiento          = EXCLUDED.fecha_vencimiento,
                    factura_referencia_id      = EXCLUDED.factura_referencia_id,
                    referencias_pago           = EXCLUDED.referencias_pago,
                    monto_referencia_aplicado  = EXCLUDED.monto_referencia_aplicado,
                    updated_at                 = NOW()
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
    updated_at timestamp without time zone DEFAULT now(),
    proveedor_id bigint,
    lineas jsonb DEFAULT '[]'::jsonb NOT NULL,
    bodega_id bigint,
    inventario_procesado_at timestamp without time zone,
    hacienda_poll_attempts smallint DEFAULT 0 NOT NULL,
    condicion_pago character varying(10) DEFAULT 'contado'::character varying NOT NULL,
    plazo_credito_dias smallint,
    fecha_vencimiento date,
    monto_pagado numeric(18,5) DEFAULT 0 NOT NULL,
    factura_referencia_id bigint,
    referencias_pago jsonb DEFAULT '[]'::jsonb NOT NULL,
    monto_referencia_aplicado numeric(18,5),
    vinculos_pago jsonb DEFAULT '[]'::jsonb NOT NULL
);


--
-- Name: sp_factura_recibida_find_by_clave(bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_find_by_clave(p_empresa_id bigint, p_clave character varying) RETURNS SETOF public.facturas_recibidas
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT * FROM facturas_recibidas
                WHERE empresa_id = p_empresa_id AND clave = p_clave
                LIMIT 1;
            END;
            $$;


--
-- Name: sp_factura_recibida_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_get(p_id bigint, p_empresa_id bigint) RETURNS SETOF public.facturas_recibidas
    LANGUAGE sql
    AS $$
                SELECT * FROM facturas_recibidas
                WHERE id = p_id AND empresa_id = p_empresa_id;
            $$;


--
-- Name: sp_factura_recibida_list(bigint, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_list(p_empresa_id bigint, p_estado character varying DEFAULT NULL::character varying, p_search text DEFAULT NULL::text) RETURNS TABLE(id bigint, empresa_id bigint, clave character varying, tipo_documento character varying, numero_consecutivo_emisor character varying, fecha_emision timestamp without time zone, emisor_tipo_id character varying, emisor_numero_id character varying, emisor_nombre character varying, moneda character varying, total_comprobante numeric, total_impuesto numeric, estado_hacienda character varying, estado_recepcion character varying, mensaje_tipo smallint, respondido_at timestamp without time zone, condicion_pago character varying, plazo_credito_dias smallint, fecha_vencimiento date, monto_pagado numeric, factura_referencia_id bigint, referencias_pago jsonb, monto_referencia_aplicado numeric, vinculos_pago jsonb, created_at timestamp without time zone)
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
                       f.condicion_pago, f.plazo_credito_dias,
                       f.fecha_vencimiento, f.monto_pagado, f.factura_referencia_id,
                       f.referencias_pago, f.monto_referencia_aplicado, f.vinculos_pago,
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
-- Name: sp_factura_recibida_marcar_inventario_procesado(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_marcar_inventario_procesado(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE facturas_recibidas
                SET inventario_procesado_at = NOW()
                WHERE id = p_id
                  AND empresa_id = p_empresa_id
                  AND inventario_procesado_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_factura_recibida_marcar_servicio_linea(bigint, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_marcar_servicio_linea(p_id bigint, p_empresa_id bigint, p_numero_linea integer) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_lineas JSONB;
                v_nuevas JSONB := '[]'::JSONB;
                v_linea  JSONB;
            BEGIN
                SELECT lineas INTO v_lineas
                FROM facturas_recibidas
                WHERE id = p_id AND empresa_id = p_empresa_id
                FOR UPDATE;

                IF v_lineas IS NULL THEN
                    RETURN NULL;
                END IF;

                FOR v_linea IN SELECT * FROM jsonb_array_elements(v_lineas)
                LOOP
                    IF (v_linea->>'numero_linea')::INT = p_numero_linea THEN
                        v_linea := jsonb_set(v_linea, '{es_servicio}', 'true'::JSONB);
                        v_linea := jsonb_set(v_linea, '{estado_mapeo}', '"resuelto"'::JSONB);
                    END IF;
                    v_nuevas := v_nuevas || jsonb_build_array(v_linea);
                END LOOP;

                UPDATE facturas_recibidas SET lineas = v_nuevas
                WHERE id = p_id AND empresa_id = p_empresa_id;

                RETURN v_nuevas;
            END;
            $$;


--
-- Name: sp_factura_recibida_registrar_pago(bigint, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_registrar_pago(p_factura_id bigint, p_empresa_id bigint, p_monto numeric) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
            DECLARE v_monto_pagado NUMERIC;
            BEGIN
                UPDATE facturas_recibidas
                SET monto_pagado = monto_pagado + p_monto,
                    updated_at   = NOW()
                WHERE id = p_factura_id AND empresa_id = p_empresa_id
                RETURNING monto_pagado INTO v_monto_pagado;
                RETURN v_monto_pagado;
            END;
            $$;


--
-- Name: sp_factura_recibida_responder(bigint, integer, smallint, text, numeric, numeric, character varying, text, text, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_responder(p_id bigint, p_empresa_id integer, p_mensaje_tipo smallint, p_detalle_mensaje text, p_monto_impuesto_acreditar numeric, p_monto_total_linea_detalle numeric, p_numero_consecutivo_receptor character varying, p_xml_mensaje_receptor text, p_hacienda_respuesta_mr text, p_estado_recepcion character varying) RETURNS boolean
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
        estado_hacienda               = 'aceptado',
        respondido_at                 = NOW(),
        updated_at                    = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id;
    RETURN FOUND;
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
-- Name: sp_factura_recibida_set_compras_fields(bigint, bigint, bigint, jsonb, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_set_compras_fields(p_id bigint, p_empresa_id bigint, p_proveedor_id bigint, p_lineas jsonb, p_bodega_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE facturas_recibidas SET
                    proveedor_id = p_proveedor_id,
                    lineas       = p_lineas,
                    bodega_id    = p_bodega_id
                WHERE id = p_id AND empresa_id = p_empresa_id;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_factura_recibida_set_condicion_pago(bigint, bigint, character varying, smallint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_set_condicion_pago(p_id bigint, p_empresa_id bigint, p_condicion_pago character varying, p_plazo_credito_dias smallint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            DECLARE v_fecha_emision TIMESTAMP;
            BEGIN
                SELECT fecha_emision INTO v_fecha_emision
                FROM facturas_recibidas WHERE id = p_id AND empresa_id = p_empresa_id;

                UPDATE facturas_recibidas
                SET condicion_pago     = p_condicion_pago,
                    plazo_credito_dias = p_plazo_credito_dias,
                    fecha_vencimiento  = CASE
                        WHEN p_condicion_pago = 'credito' AND p_plazo_credito_dias IS NOT NULL
                        THEN (v_fecha_emision::date + (p_plazo_credito_dias || ' days')::interval)::date
                        ELSE NULL
                    END,
                    updated_at         = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_factura_recibida_set_referencia(bigint, bigint, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_set_referencia(p_id bigint, p_empresa_id bigint, p_factura_referencia_id bigint, p_monto_aplicado numeric DEFAULT NULL::numeric) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE facturas_recibidas
                SET factura_referencia_id     = p_factura_referencia_id,
                    monto_referencia_aplicado = p_monto_aplicado,
                    updated_at                = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_factura_recibida_set_vinculos_pago(bigint, bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_set_vinculos_pago(p_id bigint, p_empresa_id bigint, p_vinculos_pago jsonb) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE facturas_recibidas
                SET vinculos_pago             = p_vinculos_pago,
                    factura_referencia_id     = (p_vinculos_pago -> 0 ->> 'factura_referencia_id')::bigint,
                    monto_referencia_aplicado = (p_vinculos_pago -> 0 ->> 'monto')::numeric,
                    updated_at                = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_factura_recibida_update_estado_hacienda(bigint, bigint, character varying, text, smallint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_update_estado_hacienda(p_id bigint, p_empresa_id bigint, p_estado_hacienda character varying, p_hacienda_mensaje text, p_hacienda_poll_attempts smallint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE facturas_recibidas
                SET estado_hacienda         = p_estado_hacienda,
                    hacienda_mensaje        = p_hacienda_mensaje,
                    hacienda_poll_attempts  = p_hacienda_poll_attempts,
                    updated_at              = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_factura_recibida_vincular_linea(bigint, bigint, integer, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_factura_recibida_vincular_linea(p_id bigint, p_empresa_id bigint, p_numero_linea integer, p_producto_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_lineas JSONB;
                v_nuevas JSONB := '[]'::JSONB;
                v_linea  JSONB;
            BEGIN
                SELECT lineas INTO v_lineas
                FROM facturas_recibidas
                WHERE id = p_id AND empresa_id = p_empresa_id
                FOR UPDATE;

                IF v_lineas IS NULL THEN
                    RETURN NULL;
                END IF;

                FOR v_linea IN SELECT * FROM jsonb_array_elements(v_lineas)
                LOOP
                    IF (v_linea->>'numero_linea')::INT = p_numero_linea THEN
                        v_linea := jsonb_set(v_linea, '{producto_id}', to_jsonb(p_producto_id));
                        v_linea := jsonb_set(v_linea, '{estado_mapeo}', '"resuelto"'::JSONB);
                    END IF;
                    v_nuevas := v_nuevas || jsonb_build_array(v_linea);
                END LOOP;

                UPDATE facturas_recibidas SET lineas = v_nuevas
                WHERE id = p_id AND empresa_id = p_empresa_id;

                RETURN v_nuevas;
            END;
            $$;


--
-- Name: sp_funcionario_create(bigint, character varying, character varying, character varying, character varying, text, date, numeric, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_create(p_empresa_id bigint, p_name character varying, p_tax_id character varying, p_email character varying, p_phone character varying, p_address text, p_birth_date date DEFAULT NULL::date, p_commission_pct numeric DEFAULT 0.00, p_notes text DEFAULT NULL::text, p_horario_semanal jsonb DEFAULT '[]'::jsonb) RETURNS TABLE(id bigint, name character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_palette VARCHAR[] := ARRAY['#1976D2','#388E3C','#F57C00','#D32F2F','#7B1FA2','#00796B','#5D4037','#455A64'];
                v_color   VARCHAR;
            BEGIN
                SELECT c INTO v_color
                FROM unnest(v_palette) AS c
                WHERE c NOT IN (
                    SELECT color FROM funcionarios
                    WHERE empresa_id = p_empresa_id AND deleted_at IS NULL AND color IS NOT NULL
                )
                LIMIT 1;

                IF v_color IS NULL THEN
                    v_color := v_palette[1 + (floor(random() * array_length(v_palette,1)))::int];
                END IF;

                RETURN QUERY
                INSERT INTO funcionarios (
                    empresa_id, name, tax_id,
                    email, phone, address, birth_date, commission_pct, notes, color, horario_semanal
                )
                VALUES (
                    p_empresa_id, p_name, p_tax_id,
                    p_email, p_phone, p_address, p_birth_date, p_commission_pct, p_notes, v_color,
                    COALESCE(p_horario_semanal, '[]'::jsonb)
                )
                RETURNING funcionarios.id, funcionarios.name;
            END; $$;


--
-- Name: sp_funcionario_find(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_find(p_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, tax_id character varying, email character varying, phone character varying, address text, birth_date date, commission_pct numeric, notes text, is_default boolean, is_active boolean, color character varying, horario_semanal jsonb, sucursales jsonb, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT f.id, f.empresa_id,
                       f.name, f.tax_id,
                       f.email, f.phone, f.address,
                       f.birth_date, f.commission_pct, f.notes,
                       f.is_default, f.is_active, f.color,
                       f.horario_semanal,
                       COALESCE((
                           SELECT jsonb_agg(jsonb_build_object('id', fs.sucursal_id, 'name', fs.sucursal_name) ORDER BY fs.sucursal_name)
                           FROM funcionario_sucursales fs WHERE fs.funcionario_id = f.id
                       ), '[]'::jsonb) AS sucursales,
                       f.created_at, f.updated_at
                FROM funcionarios f
                WHERE f.id = p_id AND f.deleted_at IS NULL;
            END; $$;


--
-- Name: sp_funcionario_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_list(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, tax_id character varying, email character varying, phone character varying, address text, birth_date date, commission_pct numeric, notes text, is_default boolean, is_active boolean, color character varying, horario_semanal jsonb, sucursales jsonb, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT f.id, f.empresa_id,
                       f.name, f.tax_id,
                       f.email, f.phone, f.address,
                       f.birth_date, f.commission_pct, f.notes,
                       f.is_default, f.is_active, f.color,
                       f.horario_semanal,
                       COALESCE((
                           SELECT jsonb_agg(jsonb_build_object('id', fs.sucursal_id, 'name', fs.sucursal_name) ORDER BY fs.sucursal_name)
                           FROM funcionario_sucursales fs WHERE fs.funcionario_id = f.id
                       ), '[]'::jsonb) AS sucursales,
                       f.created_at, f.updated_at
                FROM funcionarios f
                WHERE f.empresa_id = p_empresa_id AND f.deleted_at IS NULL
                ORDER BY f.is_default DESC, f.name;
            END; $$;


--
-- Name: sp_funcionario_list_eliminados(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_list_eliminados(p_empresa_id bigint) RETURNS TABLE(id bigint, name character varying, tax_id character varying, email character varying, phone character varying, deleted_at timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
                SELECT f.id, f.name, f.tax_id, f.email, f.phone, f.deleted_at
                FROM funcionarios f
                WHERE f.deleted_at IS NOT NULL AND f.empresa_id = p_empresa_id
                ORDER BY f.deleted_at DESC;
            $$;


--
-- Name: sp_funcionario_restore(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_restore(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE funcionarios SET is_active = TRUE, is_default = FALSE, deleted_at = NULL, updated_at = NOW()
                WHERE id = p_id AND deleted_at IS NOT NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END;
            $$;


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
-- Name: sp_funcionario_sucursales_set(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_sucursales_set(p_funcionario_id bigint, p_sucursales jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_horario JSONB;
                v_item    JSONB;
            BEGIN
                SELECT horario_semanal INTO v_horario FROM funcionarios WHERE id = p_funcionario_id AND deleted_at IS NULL;

                FOR v_item IN SELECT elem FROM jsonb_array_elements(COALESCE(p_sucursales, '[]'::jsonb)) elem
                LOOP
                    PERFORM fn_valida_horario_funcionario_vs_sucursal(v_horario, (v_item->>'id')::BIGINT);
                END LOOP;

                DELETE FROM funcionario_sucursales WHERE funcionario_id = p_funcionario_id;

                INSERT INTO funcionario_sucursales (funcionario_id, sucursal_id, sucursal_name)
                SELECT p_funcionario_id, (elem->>'id')::BIGINT, elem->>'name'
                FROM jsonb_array_elements(COALESCE(p_sucursales, '[]'::jsonb)) elem;
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
-- Name: sp_funcionario_update(bigint, character varying, character varying, character varying, character varying, text, date, numeric, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_funcionario_update(p_id bigint, p_name character varying, p_tax_id character varying, p_email character varying, p_phone character varying, p_address text, p_birth_date date DEFAULT NULL::date, p_commission_pct numeric DEFAULT 0.00, p_notes text DEFAULT NULL::text, p_horario_semanal jsonb DEFAULT NULL::jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_rows        INTEGER;
                v_horario     JSONB;
                v_sucursal_id BIGINT;
            BEGIN
                v_horario := COALESCE(p_horario_semanal, (SELECT horario_semanal FROM funcionarios WHERE id = p_id));

                FOR v_sucursal_id IN SELECT sucursal_id FROM funcionario_sucursales WHERE funcionario_id = p_id
                LOOP
                    PERFORM fn_valida_horario_funcionario_vs_sucursal(v_horario, v_sucursal_id);
                END LOOP;

                UPDATE funcionarios SET
                    name             = p_name,
                    tax_id           = p_tax_id,
                    email            = p_email,
                    phone            = p_phone,
                    address          = p_address,
                    birth_date       = p_birth_date,
                    commission_pct   = p_commission_pct,
                    notes            = p_notes,
                    horario_semanal  = COALESCE(p_horario_semanal, horario_semanal),
                    updated_at       = NOW()
                WHERE id = p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_inventario_kardex(bigint, bigint, bigint, date, date, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_inventario_kardex(p_empresa_id bigint, p_producto_id bigint DEFAULT NULL::bigint, p_bodega_id bigint DEFAULT NULL::bigint, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date, p_page integer DEFAULT 1, p_per_page integer DEFAULT 50) RETURNS TABLE(id bigint, fecha timestamp without time zone, tipo character varying, referencia character varying, documento_id bigint, producto_id bigint, producto_codigo character varying, producto_nombre character varying, bodega_origen_id bigint, bodega_origen character varying, bodega_destino character varying, cantidad numeric, entrada numeric, salida numeric, stock_antes numeric, stock_despues numeric, user_id bigint, notas text, total_rows bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    m.id,
                    m.created_at,
                    m.tipo,
                    m.referencia,
                    m.documento_id,
                    m.producto_id,
                    p.code AS producto_codigo,
                    p.name AS producto_nombre,
                    m.bodega_origen_id,
                    bo.name AS bodega_origen,
                    bd.name AS bodega_destino,
                    m.cantidad,
                    CASE WHEN m.tipo IN ('entrada','devolucion')
                           OR (m.tipo = 'ajuste'   AND m.stock_despues >= m.stock_antes)
                           OR (m.tipo = 'traslado' AND m.stock_despues >  m.stock_antes)
                         THEN m.cantidad ELSE 0 END AS entrada,
                    CASE WHEN m.tipo IN ('salida','venta','danio')
                           OR (m.tipo = 'ajuste'   AND m.stock_despues < m.stock_antes)
                           OR (m.tipo = 'traslado' AND m.stock_despues <= m.stock_antes)
                         THEN m.cantidad ELSE 0 END AS salida,
                    m.stock_antes,
                    m.stock_despues,
                    m.user_id,
                    m.notas,
                    COUNT(*) OVER()::BIGINT AS total_rows
                FROM movimientos_inventario m
                LEFT JOIN productos p ON p.id = m.producto_id
                LEFT JOIN bodegas   bo ON bo.id = m.bodega_origen_id
                LEFT JOIN bodegas   bd ON bd.id = m.bodega_destino_id
                WHERE m.empresa_id       = p_empresa_id
                  AND (p_producto_id IS NULL OR m.producto_id      = p_producto_id)
                  AND (p_bodega_id   IS NULL OR m.bodega_origen_id = p_bodega_id)
                  AND (p_fecha_desde IS NULL OR m.created_at::date >= p_fecha_desde)
                  AND (p_fecha_hasta IS NULL OR m.created_at::date <= p_fecha_hasta)
                ORDER BY m.created_at DESC
                LIMIT GREATEST(p_per_page, 1) OFFSET GREATEST(p_page - 1, 0) * GREATEST(p_per_page, 1);
            END;
            $$;


--
-- Name: sp_inventario_movimientos(bigint, bigint, bigint, character varying, date, date, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_inventario_movimientos(p_empresa_id bigint, p_bodega_id bigint DEFAULT NULL::bigint, p_producto_id bigint DEFAULT NULL::bigint, p_tipo character varying DEFAULT NULL::character varying, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0) RETURNS TABLE(id bigint, fecha timestamp without time zone, tipo character varying, bodega_origen character varying, bodega_destino character varying, producto_codigo character varying, producto_nombre character varying, cantidad numeric, stock_antes numeric, stock_despues numeric, precio_base numeric, monto_total numeric, referencia character varying, notas text, documento_id bigint, user_id bigint, proveedor_nombre character varying, total_count bigint)
    LANGUAGE sql SECURITY DEFINER
    AS $$
                SELECT
                    m.id,
                    m.created_at,
                    m.tipo,
                    bo.name   AS bodega_origen,
                    bd.name   AS bodega_destino,
                    p.code    AS producto_codigo,
                    p.name    AS producto_nombre,
                    m.cantidad,
                    m.stock_antes,
                    m.stock_despues,
                    m.precio_base,
                    m.monto_total,
                    m.referencia,
                    m.notas,
                    m.documento_id,
                    m.user_id,
                    prov.name AS proveedor_nombre,
                    COUNT(*) OVER() AS total_count
                FROM movimientos_inventario m
                JOIN bodegas bo  ON bo.id = m.bodega_origen_id
                LEFT JOIN bodegas bd ON bd.id = m.bodega_destino_id
                JOIN productos p ON p.id = m.producto_id
                LEFT JOIN proveedores prov ON prov.id = m.proveedor_id
                WHERE m.empresa_id = p_empresa_id
                  AND (p_bodega_id   IS NULL OR m.bodega_origen_id = p_bodega_id)
                  AND (p_producto_id IS NULL OR m.producto_id      = p_producto_id)
                  AND (p_tipo        IS NULL OR m.tipo             = p_tipo)
                  AND (p_fecha_desde IS NULL OR m.created_at::date >= p_fecha_desde)
                  AND (p_fecha_hasta IS NULL OR m.created_at::date <= p_fecha_hasta)
                ORDER BY m.created_at DESC
                LIMIT p_limit OFFSET p_offset;
            $$;


--
-- Name: sp_inventario_registrar_desde_documento(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_inventario_registrar_desde_documento(p_documento_id bigint, p_user_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_tipo_doc  VARCHAR(2);
    v_empresa   BIGINT;
    v_tipo_mov  VARCHAR(20);
    v_delta     NUMERIC;
    r           RECORD;
    v_stock_antes NUMERIC;
BEGIN
    SELECT tipo_documento, empresa_id INTO v_tipo_doc, v_empresa
      FROM documentos_electronicos WHERE id = p_documento_id;

    IF v_tipo_doc IN ('01','04') THEN
        v_tipo_mov := 'venta';    v_delta := -1;
    ELSIF v_tipo_doc = '03' THEN
        v_tipo_mov := 'devolucion'; v_delta := 1;
    ELSE RETURN;
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
        SELECT COALESCE(stock, 0) INTO v_stock_antes
          FROM bodega_productos
         WHERE bodega_id = r.bodega_id AND producto_id = r.producto_id;

        INSERT INTO movimientos_inventario (
            empresa_id, tipo, bodega_origen_id, producto_id,
            cantidad, stock_antes, stock_despues,
            documento_id, referencia, user_id
        ) VALUES (
            v_empresa, v_tipo_mov, r.bodega_id, r.producto_id,
            r.cantidad, v_stock_antes, v_stock_antes + (v_delta * r.cantidad),
            p_documento_id,
            'Doc #' || p_documento_id,
            p_user_id
        );
    END LOOP;
END;
$$;


--
-- Name: sp_inventario_registrar_movimiento(bigint, character varying, bigint, bigint, bigint, numeric, character varying, text, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_inventario_registrar_movimiento(p_empresa_id bigint, p_tipo character varying, p_bodega_origen_id bigint, p_bodega_destino_id bigint, p_producto_id bigint, p_cantidad numeric, p_referencia character varying, p_notas text, p_user_id bigint, p_proveedor_id bigint DEFAULT NULL::bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_stock_antes   NUMERIC;
                v_stock_despues NUMERIC;
                v_delta         NUMERIC;
                v_mov_id        BIGINT;
                v_stock_antes_dest NUMERIC;
                v_precio_base   NUMERIC;
            BEGIN
                IF p_tipo IN ('venta', 'devolucion') THEN
                    RAISE EXCEPTION 'El tipo % solo puede ser registrado por el sistema', p_tipo;
                END IF;

                SELECT COALESCE(price, 0) INTO v_precio_base
                  FROM productos
                 WHERE id = p_producto_id;
                v_precio_base := COALESCE(v_precio_base, 0);

                SELECT COALESCE(stock, 0) INTO v_stock_antes
                  FROM bodega_productos
                 WHERE bodega_id = p_bodega_origen_id AND producto_id = p_producto_id;
                v_stock_antes := COALESCE(v_stock_antes, 0);

                v_delta := CASE
                    WHEN p_tipo IN ('entrada', 'entrada_ajuste')                THEN  p_cantidad
                    WHEN p_tipo IN ('salida', 'salida_ajuste', 'danio', 'dano_merma') THEN -p_cantidad
                    WHEN p_tipo = 'ajuste'               THEN  p_cantidad
                    WHEN p_tipo = 'traslado'              THEN -p_cantidad
                    ELSE 0
                END;

                v_stock_despues := v_stock_antes + v_delta;

                PERFORM sp_bodega_producto_ajustar_stock(p_bodega_origen_id, p_producto_id, v_delta);

                INSERT INTO movimientos_inventario (
                    empresa_id, tipo, bodega_origen_id, bodega_destino_id,
                    producto_id, cantidad, stock_antes, stock_despues,
                    referencia, notas, user_id, precio_base, monto_total, proveedor_id
                ) VALUES (
                    p_empresa_id, p_tipo, p_bodega_origen_id, p_bodega_destino_id,
                    p_producto_id, p_cantidad, v_stock_antes, v_stock_despues,
                    p_referencia, p_notas, p_user_id, v_precio_base, v_precio_base * p_cantidad, p_proveedor_id
                ) RETURNING id INTO v_mov_id;

                IF p_tipo = 'traslado' AND p_bodega_destino_id IS NOT NULL THEN
                    SELECT COALESCE(stock, 0) INTO v_stock_antes_dest
                      FROM bodega_productos
                     WHERE bodega_id = p_bodega_destino_id AND producto_id = p_producto_id;
                    v_stock_antes_dest := COALESCE(v_stock_antes_dest, 0);

                    PERFORM sp_bodega_producto_ajustar_stock(p_bodega_destino_id, p_producto_id, p_cantidad);

                    INSERT INTO movimientos_inventario (
                        empresa_id, tipo, bodega_origen_id, bodega_destino_id,
                        producto_id, cantidad, stock_antes, stock_despues,
                        referencia, notas, user_id, precio_base, monto_total, proveedor_id
                    ) VALUES (
                        p_empresa_id, p_tipo, p_bodega_destino_id, p_bodega_origen_id,
                        p_producto_id, p_cantidad, v_stock_antes_dest, v_stock_antes_dest + p_cantidad,
                        p_referencia, p_notas, p_user_id, v_precio_base, v_precio_base * p_cantidad, p_proveedor_id
                    );
                END IF;

                RETURN v_mov_id;
            END;
            $$;


--
-- Name: sp_inventario_registrar_movimiento_lote(bigint, character varying, bigint, bigint, jsonb, character varying, text, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_inventario_registrar_movimiento_lote(p_empresa_id bigint, p_tipo character varying, p_bodega_origen_id bigint, p_bodega_destino_id bigint, p_lineas jsonb, p_referencia character varying, p_notas text, p_user_id bigint, p_proveedor_id bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_linea JSONB;
                v_id    BIGINT;
                v_ids   JSONB := '[]'::jsonb;
            BEGIN
                IF p_lineas IS NULL OR jsonb_array_length(p_lineas) = 0 THEN
                    RAISE EXCEPTION 'Debe incluir al menos una línea';
                END IF;

                FOR v_linea IN SELECT * FROM jsonb_array_elements(p_lineas)
                LOOP
                    v_id := sp_inventario_registrar_movimiento(
                        p_empresa_id, p_tipo, p_bodega_origen_id, p_bodega_destino_id,
                        (v_linea->>'producto_id')::BIGINT,
                        (v_linea->>'cantidad')::NUMERIC,
                        p_referencia, p_notas, p_user_id, p_proveedor_id
                    );
                    v_ids := v_ids || to_jsonb(v_id);
                END LOOP;

                RETURN v_ids;
            END;
            $$;


--
-- Name: sp_medio_pago_create(bigint, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_medio_pago_create(p_empresa_id bigint, p_nombre character varying, p_tipo_hacienda_codigo character varying, p_tipo_hacienda_nombre character varying) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO empresa_medios_pago(empresa_id, nombre, tipo_hacienda_codigo, tipo_hacienda_nombre, orden)
                VALUES (
                    p_empresa_id, p_nombre, p_tipo_hacienda_codigo, p_tipo_hacienda_nombre,
                    COALESCE((SELECT MAX(orden) FROM empresa_medios_pago
                              WHERE empresa_id = p_empresa_id
                                AND tipo_hacienda_codigo = p_tipo_hacienda_codigo
                                AND deleted_at IS NULL), 0) + 1
                )
                RETURNING id INTO v_id;
                RETURN v_id;
            END;
            $$;


--
-- Name: sp_medio_pago_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_medio_pago_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                UPDATE empresa_medios_pago SET deleted_at = NOW(), updated_at = NOW()
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
              SELECT tipo_hacienda_codigo INTO v_tipo
              FROM empresa_medios_pago
              WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;

              IF NOT FOUND THEN RETURN false; END IF;

              -- Normalizar el orden del grupo (evita duplicados)
              UPDATE empresa_medios_pago m SET orden = n.rn
              FROM (
                SELECT id, ROW_NUMBER() OVER (ORDER BY orden, id) AS rn
                FROM empresa_medios_pago
                WHERE empresa_id = p_empresa_id AND tipo_hacienda_codigo = v_tipo AND deleted_at IS NULL
              ) n
              WHERE m.id = n.id AND m.orden IS DISTINCT FROM n.rn;

              SELECT orden INTO v_orden_actual FROM empresa_medios_pago WHERE id = p_id;

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
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                UPDATE empresa_medios_pago SET
                    nombre               = p_nombre,
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
-- Name: sp_mercadeo_campana_create(bigint, bigint, character varying, character varying, jsonb, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_campana_create(p_empresa_id bigint, p_plantilla_id bigint, p_nombre character varying, p_canal character varying, p_filtro_destinatarios jsonb, p_enviado_por bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO mercadeo_campanas (
                    empresa_id, plantilla_id, nombre, canal, filtro_destinatarios, enviado_por
                ) VALUES (
                    p_empresa_id, p_plantilla_id, p_nombre, p_canal, p_filtro_destinatarios, p_enviado_por
                ) RETURNING id INTO v_id;
                RETURN v_id;
            END; $$;


--
-- Name: sp_mercadeo_campana_envio_bulk_insert(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_campana_envio_bulk_insert(p_campana_id bigint, p_destinatarios jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_count INTEGER;
            BEGIN
                INSERT INTO mercadeo_campana_envios (campana_id, cliente_id, destino)
                SELECT p_campana_id, (d->>'cliente_id')::BIGINT, d->>'destino'
                FROM jsonb_array_elements(p_destinatarios) AS d;

                GET DIAGNOSTICS v_count = ROW_COUNT;

                UPDATE mercadeo_campanas
                SET total_destinatarios = v_count, estado = 'enviando'
                WHERE id = p_campana_id;

                RETURN v_count;
            END; $$;


--
-- Name: sp_mercadeo_campana_envio_marcar(bigint, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_campana_envio_marcar(p_envio_id bigint, p_estado character varying, p_error_mensaje text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_campana_id BIGINT;
                v_pendientes INTEGER;
            BEGIN
                UPDATE mercadeo_campana_envios
                SET estado = p_estado, error_mensaje = p_error_mensaje, enviado_at = NOW()
                WHERE id = p_envio_id
                RETURNING campana_id INTO v_campana_id;

                IF v_campana_id IS NULL THEN
                    RETURN FALSE;
                END IF;

                UPDATE mercadeo_campanas c SET
                    total_enviados = (SELECT COUNT(*) FROM mercadeo_campana_envios WHERE campana_id = v_campana_id AND estado = 'enviado'),
                    total_fallidos = (SELECT COUNT(*) FROM mercadeo_campana_envios WHERE campana_id = v_campana_id AND estado = 'fallido')
                WHERE c.id = v_campana_id;

                SELECT COUNT(*) INTO v_pendientes FROM mercadeo_campana_envios
                WHERE campana_id = v_campana_id AND estado = 'pendiente';

                IF v_pendientes = 0 THEN
                    UPDATE mercadeo_campanas SET
                        estado = CASE WHEN total_fallidos > 0 AND total_enviados = 0 THEN 'fallida' ELSE 'enviada' END,
                        enviado_at = COALESCE(enviado_at, NOW())
                    WHERE id = v_campana_id;
                END IF;

                RETURN TRUE;
            END; $$;


--
-- Name: sp_mercadeo_campana_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_campana_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, plantilla_id bigint, plantilla_nombre character varying, nombre character varying, canal character varying, estado character varying, total_destinatarios integer, total_enviados integer, total_fallidos integer, filtro_destinatarios jsonb, enviado_at timestamp without time zone, created_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT c.id, c.plantilla_id, p.nombre, c.nombre, c.canal, c.estado,
                       c.total_destinatarios, c.total_enviados, c.total_fallidos,
                       c.filtro_destinatarios, c.enviado_at, c.created_at
                FROM mercadeo_campanas c
                JOIN mercadeo_plantillas p ON p.id = c.plantilla_id
                WHERE c.id = p_id AND c.empresa_id = p_empresa_id AND c.deleted_at IS NULL;
            END; $$;


--
-- Name: sp_mercadeo_campana_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_campana_list(p_empresa_id bigint) RETURNS TABLE(id bigint, plantilla_id bigint, plantilla_nombre character varying, nombre character varying, canal character varying, estado character varying, total_destinatarios integer, total_enviados integer, total_fallidos integer, enviado_at timestamp without time zone, created_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT c.id, c.plantilla_id, p.nombre, c.nombre, c.canal, c.estado,
                       c.total_destinatarios, c.total_enviados, c.total_fallidos, c.enviado_at, c.created_at
                FROM mercadeo_campanas c
                JOIN mercadeo_plantillas p ON p.id = c.plantilla_id
                WHERE c.empresa_id = p_empresa_id AND c.deleted_at IS NULL
                ORDER BY c.created_at DESC;
            END; $$;


--
-- Name: sp_mercadeo_destinatarios_resolver(bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_destinatarios_resolver(p_empresa_id bigint, p_filtro character varying, p_canal character varying) RETURNS TABLE(cliente_id bigint, nombre character varying, destino character varying, saldo_pendiente numeric, birth_date date)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT DISTINCT c.id, c.name,
                       CASE WHEN p_canal = 'whatsapp' THEN c.phone ELSE c.email END,
                       COALESCE(cxc_totales.saldo, 0),
                       c.birth_date
                FROM clients c
                LEFT JOIN (
                    SELECT cuentas_por_cobrar.cliente_id AS cxc_cliente_id, SUM(cuentas_por_cobrar.saldo_pendiente) AS saldo
                    FROM cuentas_por_cobrar
                    WHERE cuentas_por_cobrar.empresa_id = p_empresa_id AND cuentas_por_cobrar.estado IN ('vigente','mora')
                    GROUP BY cuentas_por_cobrar.cliente_id
                ) cxc_totales ON cxc_totales.cxc_cliente_id = c.id
                WHERE (p_canal = 'whatsapp' AND c.phone IS NOT NULL AND c.phone <> ''
                       OR p_canal = 'email' AND c.email IS NOT NULL AND c.email <> '')
                  AND (
                        p_filtro = 'todos'
                        OR (p_filtro = 'con_saldo_pendiente' AND COALESCE(cxc_totales.saldo, 0) > 0)
                        OR (p_filtro = 'cumpleanos_mes' AND c.birth_date IS NOT NULL
                            AND EXTRACT(MONTH FROM c.birth_date) = EXTRACT(MONTH FROM CURRENT_DATE))
                      );
            END; $$;


--
-- Name: sp_mercadeo_plantilla_create(bigint, character varying, character varying, character varying, character varying, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_plantilla_create(p_empresa_id bigint, p_categoria character varying, p_canal character varying, p_nombre character varying, p_asunto character varying, p_contenido_html text, p_contenido_texto text, p_variables_usadas jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO mercadeo_plantillas (
                    empresa_id, categoria, canal, nombre, asunto, contenido_html, contenido_texto, variables_usadas
                ) VALUES (
                    p_empresa_id, p_categoria, p_canal, p_nombre, p_asunto, p_contenido_html, p_contenido_texto, p_variables_usadas
                ) RETURNING id INTO v_id;
                RETURN v_id;
            END; $$;


--
-- Name: sp_mercadeo_plantilla_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_plantilla_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE mercadeo_plantillas SET deleted_at = NOW(), updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_mercadeo_plantilla_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_plantilla_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, categoria character varying, canal character varying, nombre character varying, asunto character varying, contenido_html text, contenido_texto text, variables_usadas jsonb, activo boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT p.id, p.categoria, p.canal, p.nombre, p.asunto, p.contenido_html,
                       p.contenido_texto, p.variables_usadas, p.activo, p.created_at, p.updated_at
                FROM mercadeo_plantillas p
                WHERE p.id = p_id AND p.empresa_id = p_empresa_id AND p.deleted_at IS NULL;
            END; $$;


--
-- Name: sp_mercadeo_plantilla_list(bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_plantilla_list(p_empresa_id bigint, p_categoria character varying DEFAULT NULL::character varying, p_canal character varying DEFAULT NULL::character varying) RETURNS TABLE(id bigint, categoria character varying, canal character varying, nombre character varying, asunto character varying, contenido_html text, contenido_texto text, variables_usadas jsonb, activo boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT p.id, p.categoria, p.canal, p.nombre, p.asunto, p.contenido_html,
                       p.contenido_texto, p.variables_usadas, p.activo, p.created_at, p.updated_at
                FROM mercadeo_plantillas p
                WHERE p.empresa_id = p_empresa_id AND p.deleted_at IS NULL
                  AND (p_categoria IS NULL OR p.categoria = p_categoria)
                  AND (p_canal IS NULL OR p.canal = p_canal)
                ORDER BY p.nombre;
            END; $$;


--
-- Name: sp_mercadeo_plantilla_update(bigint, bigint, character varying, character varying, character varying, character varying, text, text, jsonb, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_plantilla_update(p_id bigint, p_empresa_id bigint, p_categoria character varying, p_canal character varying, p_nombre character varying, p_asunto character varying, p_contenido_html text, p_contenido_texto text, p_variables_usadas jsonb, p_activo boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE mercadeo_plantillas SET
                    categoria = p_categoria, canal = p_canal, nombre = p_nombre, asunto = p_asunto,
                    contenido_html = p_contenido_html, contenido_texto = p_contenido_texto,
                    variables_usadas = p_variables_usadas, activo = p_activo, updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_moneda_create(bigint, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_moneda_create(p_empresa_id bigint, p_codigo character varying, p_nombre character varying, p_simbolo character varying DEFAULT ''::character varying) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_id BIGINT;
BEGIN
  INSERT INTO empresa_monedas(empresa_id, codigo, nombre, simbolo) VALUES (p_empresa_id, p_codigo, p_nombre, p_simbolo) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;


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
-- Name: sp_moneda_update(bigint, bigint, character varying, character varying, boolean, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_moneda_update(p_id bigint, p_empresa_id bigint, p_codigo character varying, p_nombre character varying, p_is_active boolean, p_simbolo character varying DEFAULT ''::character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE empresa_monedas SET codigo=p_codigo, nombre=p_nombre, simbolo=p_simbolo, is_active=p_is_active, updated_at=NOW()
  WHERE id=p_id AND empresa_id=p_empresa_id AND deleted_at IS NULL;
  RETURN FOUND;
END; $$;


--
-- Name: sp_monedas_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_monedas_list(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, codigo character varying, nombre character varying, simbolo character varying, is_default boolean, is_active boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
  RETURN QUERY SELECT m.id, m.empresa_id, m.codigo, m.nombre, m.simbolo, m.is_default, m.is_active, m.created_at, m.updated_at
  FROM empresa_monedas m WHERE m.empresa_id = p_empresa_id AND m.deleted_at IS NULL ORDER BY m.is_default DESC, m.codigo;
END; $$;


--
-- Name: sp_orden_pedido_create(bigint, bigint, bigint, character varying, timestamp without time zone, date, bigint, bigint, character varying, numeric, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_orden_pedido_create(p_empresa_id bigint, p_sucursal_id bigint, p_user_id bigint, p_numero character varying, p_fecha timestamp without time zone, p_fecha_entrega_esperada date, p_proveedor_id bigint, p_bodega_id bigint, p_moneda character varying, p_tipo_cambio numeric, p_lineas jsonb, p_notas text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO ordenes_pedido (
                    empresa_id, sucursal_id, user_id,
                    numero, fecha, fecha_entrega_esperada,
                    proveedor_id, bodega_id, moneda, tipo_cambio,
                    lineas, notas, estado
                ) VALUES (
                    p_empresa_id, p_sucursal_id, p_user_id,
                    p_numero, p_fecha, p_fecha_entrega_esperada,
                    p_proveedor_id, p_bodega_id, p_moneda, p_tipo_cambio,
                    p_lineas, p_notas, 'borrador'
                ) RETURNING id INTO v_id;
                RETURN v_id;
            END;
            $$;


--
-- Name: sp_orden_pedido_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_orden_pedido_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, sucursal_id bigint, user_id bigint, numero character varying, fecha timestamp without time zone, fecha_entrega_esperada date, proveedor_id bigint, proveedor_nombre character varying, proveedor_email character varying, bodega_id bigint, bodega_nombre character varying, moneda character varying, tipo_cambio numeric, lineas jsonb, notas text, estado character varying, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    o.id, o.empresa_id, o.sucursal_id, o.user_id,
                    o.numero, o.fecha, o.fecha_entrega_esperada,
                    o.proveedor_id, p.name AS proveedor_nombre, p.email AS proveedor_email,
                    o.bodega_id, b.name AS bodega_nombre,
                    o.moneda, o.tipo_cambio,
                    o.lineas, o.notas, o.estado,
                    o.created_at, o.updated_at
                FROM ordenes_pedido o
                LEFT JOIN proveedores p ON p.id = o.proveedor_id
                LEFT JOIN bodegas b ON b.id = o.bodega_id
                WHERE o.id = p_id
                  AND o.empresa_id = p_empresa_id
                  AND o.deleted_at IS NULL;
            END;
            $$;


--
-- Name: sp_orden_pedido_list(bigint, character varying, text, date, date, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_orden_pedido_list(p_empresa_id bigint, p_estado character varying DEFAULT NULL::character varying, p_search text DEFAULT NULL::text, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date, p_page integer DEFAULT 1, p_per_page integer DEFAULT 20) RETURNS TABLE(id bigint, numero character varying, fecha timestamp without time zone, proveedor_id bigint, proveedor_nombre character varying, bodega_id bigint, bodega_nombre character varying, moneda character varying, estado character varying, created_at timestamp without time zone, total_rows bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        o.id, o.numero, o.fecha,
        o.proveedor_id, p.name AS proveedor_nombre,
        o.bodega_id, b.name AS bodega_nombre,
        o.moneda, o.estado, o.created_at,
        COUNT(*) OVER()::BIGINT AS total_rows
    FROM ordenes_pedido o
    LEFT JOIN proveedores p ON p.id = o.proveedor_id
    LEFT JOIN bodegas b ON b.id = o.bodega_id
    WHERE o.empresa_id = p_empresa_id
      AND o.deleted_at IS NULL
      AND (p_estado IS NULL OR o.estado = p_estado)
      AND (p_fecha_desde IS NULL OR o.fecha::DATE >= p_fecha_desde)
      AND (p_fecha_hasta IS NULL OR o.fecha::DATE <= p_fecha_hasta)
      AND (p_search IS NULL
           OR o.numero ILIKE '%' || p_search || '%'
           OR p.name ILIKE '%' || p_search || '%')
    ORDER BY o.created_at DESC
    LIMIT p_per_page OFFSET (p_page - 1) * p_per_page;
END;
$$;


--
-- Name: sp_orden_pedido_next_numero(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_orden_pedido_next_numero(p_empresa_id bigint) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_next   BIGINT;
                v_numero VARCHAR(20);
            BEGIN
                INSERT INTO orden_pedido_consecutivos (empresa_id, ultimo_numero)
                VALUES (p_empresa_id, 1)
                ON CONFLICT (empresa_id)
                DO UPDATE SET
                    ultimo_numero = orden_pedido_consecutivos.ultimo_numero + 1,
                    updated_at = NOW()
                RETURNING ultimo_numero INTO v_next;

                v_numero := 'OP-' || LPAD(v_next::VARCHAR, 7, '0');
                RETURN v_numero;
            END;
            $$;


--
-- Name: sp_orden_pedido_recibir_lineas(bigint, bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_orden_pedido_recibir_lineas(p_id bigint, p_empresa_id bigint, p_lineas_recibidas jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_lineas        JSONB;
                v_estado_actual VARCHAR;
                v_nuevas        JSONB := '[]'::JSONB;
                v_linea         JSONB;
                v_recibir       JSONB;
                v_pendiente     NUMERIC;
                v_cantidad      NUMERIC;
                v_completas     INT := 0;
                v_total_lineas  INT := 0;
            BEGIN
                SELECT lineas, estado INTO v_lineas, v_estado_actual
                FROM ordenes_pedido
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL
                FOR UPDATE;

                IF v_lineas IS NULL THEN
                    RETURN NULL;
                END IF;

                IF v_estado_actual NOT IN ('enviada','recibida_parcial') THEN
                    RAISE EXCEPTION 'La orden debe estar enviada o recibida parcialmente para recibir mercancía.';
                END IF;

                FOR v_linea IN SELECT * FROM jsonb_array_elements(v_lineas)
                LOOP
                    v_total_lineas := v_total_lineas + 1;

                    SELECT le INTO v_recibir
                    FROM jsonb_array_elements(p_lineas_recibidas) le
                    WHERE (le->>'numero_linea')::INT = (v_linea->>'numero_linea')::INT
                    LIMIT 1;

                    IF v_recibir IS NOT NULL THEN
                        v_cantidad  := COALESCE((v_recibir->>'cantidad')::NUMERIC, 0);
                        v_pendiente := COALESCE((v_linea->>'cantidad')::NUMERIC, 0) - COALESCE((v_linea->>'cantidad_recibida')::NUMERIC, 0);

                        IF v_cantidad < 0 OR v_cantidad > v_pendiente THEN
                            RAISE EXCEPTION 'Cantidad a recibir inválida en línea %: pendiente %, solicitado %',
                                (v_linea->>'numero_linea'), v_pendiente, v_cantidad;
                        END IF;

                        v_linea := jsonb_set(
                            v_linea,
                            '{cantidad_recibida}',
                            to_jsonb(COALESCE((v_linea->>'cantidad_recibida')::NUMERIC, 0) + v_cantidad)
                        );
                    END IF;

                    IF COALESCE((v_linea->>'cantidad_recibida')::NUMERIC, 0) >= COALESCE((v_linea->>'cantidad')::NUMERIC, 0) THEN
                        v_completas := v_completas + 1;
                    END IF;

                    v_nuevas := v_nuevas || jsonb_build_array(v_linea);
                END LOOP;

                UPDATE ordenes_pedido SET
                    lineas     = v_nuevas,
                    estado     = CASE
                                    WHEN v_completas >= v_total_lineas THEN 'recibida_total'
                                    ELSE 'recibida_parcial'
                                 END,
                    updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id;

                RETURN v_nuevas;
            END;
            $$;


--
-- Name: sp_orden_pedido_set_estado(bigint, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_orden_pedido_set_estado(p_id bigint, p_empresa_id bigint, p_nuevo_estado character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_estado_actual VARCHAR;
                v_ok            BOOLEAN := FALSE;
            BEGIN
                SELECT estado INTO v_estado_actual
                FROM ordenes_pedido
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL
                FOR UPDATE;

                IF v_estado_actual IS NULL THEN
                    RETURN FALSE;
                END IF;

                IF p_nuevo_estado = 'enviada' AND v_estado_actual = 'borrador' THEN
                    v_ok := TRUE;
                ELSIF p_nuevo_estado = 'cancelada' AND v_estado_actual IN ('borrador','enviada') THEN
                    v_ok := TRUE;
                END IF;

                IF NOT v_ok THEN
                    RETURN FALSE;
                END IF;

                UPDATE ordenes_pedido SET
                    estado     = p_nuevo_estado,
                    updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id;

                RETURN TRUE;
            END;
            $$;


--
-- Name: sp_orden_pedido_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_orden_pedido_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE ordenes_pedido
                SET deleted_at = NOW(), updated_at = NOW()
                WHERE id = p_id
                  AND empresa_id = p_empresa_id
                  AND estado = 'borrador'
                  AND deleted_at IS NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_orden_pedido_update(bigint, bigint, timestamp without time zone, date, bigint, bigint, character varying, numeric, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_orden_pedido_update(p_id bigint, p_empresa_id bigint, p_fecha timestamp without time zone, p_fecha_entrega_esperada date, p_proveedor_id bigint, p_bodega_id bigint, p_moneda character varying, p_tipo_cambio numeric, p_lineas jsonb, p_notas text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE ordenes_pedido SET
                    fecha                  = p_fecha,
                    fecha_entrega_esperada = p_fecha_entrega_esperada,
                    proveedor_id           = p_proveedor_id,
                    bodega_id              = p_bodega_id,
                    moneda                 = p_moneda,
                    tipo_cambio            = p_tipo_cambio,
                    lineas                 = p_lineas,
                    notas                  = p_notas,
                    updated_at             = NOW()
                WHERE id = p_id
                  AND empresa_id = p_empresa_id
                  AND estado = 'borrador'
                  AND deleted_at IS NULL;
                RETURN FOUND;
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
-- Name: sp_producto_create(bigint, character varying, character varying, text, character varying, character varying, numeric, character varying, character varying, numeric, character varying, text, character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_create(p_empresa_id bigint, p_code character varying, p_name character varying, p_description text, p_unit_measure character varying, p_cabys_code character varying, p_price numeric, p_tax_type character varying, p_tax_code character varying, p_tax_rate numeric, p_tax_tarifa_codigo character varying, p_image_url text, p_image_public_id character varying, p_moneda character varying, p_codigo_barras character varying, p_partida_arancelaria character varying DEFAULT NULL::character varying) RETURNS TABLE(id bigint, code character varying, name character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_id BIGINT;
            BEGIN
                INSERT INTO productos (
                    empresa_id, code, name, description, type, unit_measure,
                    cabys_code, partida_arancelaria, price, tax_type, tax_code, tax_rate, tax_tarifa_codigo,
                    image_url, image_public_id, moneda, codigo_barras
                ) VALUES (
                    p_empresa_id, p_code, p_name, p_description, 'product', p_unit_measure,
                    p_cabys_code, p_partida_arancelaria, p_price, p_tax_type, p_tax_code, p_tax_rate, p_tax_tarifa_codigo,
                    p_image_url, p_image_public_id, p_moneda, p_codigo_barras
                ) RETURNING productos.id INTO v_id;

                INSERT INTO bodega_productos (bodega_id, producto_id, stock, stock_min)
                SELECT b.id, v_id, 0, 0 FROM bodegas b WHERE b.empresa_id = p_empresa_id;

                RETURN QUERY SELECT v_id, p_code, p_name;
            END;
            $$;


--
-- Name: sp_producto_create(bigint, character varying, character varying, text, character varying, character varying, numeric, character varying, character varying, numeric, character varying, text, character varying, character varying, character varying, character varying, boolean, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_create(p_empresa_id bigint, p_code character varying, p_name character varying, p_description text, p_unit_measure character varying, p_cabys_code character varying, p_price numeric, p_tax_type character varying, p_tax_code character varying, p_tax_rate numeric, p_tax_tarifa_codigo character varying, p_image_url text, p_image_public_id character varying, p_moneda character varying, p_codigo_barras character varying, p_partida_arancelaria character varying DEFAULT NULL::character varying, p_comision_activa boolean DEFAULT false, p_comision_pct numeric DEFAULT NULL::numeric) RETURNS TABLE(id bigint, code character varying, name character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_id BIGINT;
            BEGIN
                INSERT INTO productos (
                    empresa_id, code, name, description, type, unit_measure,
                    cabys_code, partida_arancelaria, price, tax_type, tax_code, tax_rate, tax_tarifa_codigo,
                    image_url, image_public_id, moneda, codigo_barras,
                    comision_activa, comision_pct
                ) VALUES (
                    p_empresa_id, p_code, p_name, p_description, 'product', p_unit_measure,
                    p_cabys_code, p_partida_arancelaria, p_price, p_tax_type, p_tax_code, p_tax_rate, p_tax_tarifa_codigo,
                    p_image_url, p_image_public_id, p_moneda, p_codigo_barras,
                    COALESCE(p_comision_activa, FALSE), p_comision_pct
                ) RETURNING productos.id INTO v_id;

                INSERT INTO bodega_productos (bodega_id, producto_id, stock, stock_min)
                SELECT b.id, v_id, 0, 0 FROM bodegas b WHERE b.empresa_id = p_empresa_id;

                RETURN QUERY SELECT v_id, p_code, p_name;
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
-- Name: sp_producto_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, code character varying, name character varying, description text, type character varying, unit_measure character varying, cabys_code character varying, partida_arancelaria character varying, codigo_barras character varying, price numeric, price_with_tax numeric, tax_type character varying, tax_code character varying, tax_rate numeric, tax_tarifa_codigo character varying, image_url text, image_public_id character varying, moneda character varying, is_active boolean, comision_activa boolean, comision_pct numeric, bodega_id bigint, stock numeric, stock_min numeric)
    LANGUAGE sql STABLE
    AS $$
                SELECT
                    p.id, p.empresa_id,
                    p.code, p.name, p.description, p.type, p.unit_measure,
                    p.cabys_code, p.partida_arancelaria, p.codigo_barras,
                    p.price, ROUND(p.price * (1 + p.tax_rate / 100), 5) AS price_with_tax,
                    p.tax_type, p.tax_code, p.tax_rate, p.tax_tarifa_codigo,
                    p.image_url, p.image_public_id, p.moneda, p.is_active,
                    p.comision_activa, p.comision_pct,
                    bp.bodega_id, bp.stock, bp.stock_min
                FROM productos p
                LEFT JOIN bodega_productos bp ON bp.producto_id = p.id
                    AND bp.bodega_id = (
                        SELECT b.id FROM bodegas b
                        WHERE b.empresa_id = p_empresa_id AND b.is_active
                        ORDER BY b.is_default DESC, b.id
                        LIMIT 1
                    )
                WHERE p.id = p_id
                  AND p.empresa_id = p_empresa_id
                  AND p.deleted_at IS NULL;
            $$;


--
-- Name: sp_producto_list(bigint, bigint, character varying, character varying, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_list(p_empresa_id bigint, p_bodega_id bigint DEFAULT NULL::bigint, p_search character varying DEFAULT NULL::character varying, p_estado character varying DEFAULT 'todos'::character varying, p_page integer DEFAULT 1, p_per_page integer DEFAULT 20) RETURNS TABLE(id bigint, empresa_id bigint, code character varying, name character varying, description text, type character varying, unit_measure character varying, cabys_code character varying, partida_arancelaria character varying, codigo_barras character varying, price numeric, price_with_tax numeric, tax_type character varying, tax_code character varying, tax_rate numeric, tax_tarifa_codigo character varying, image_url text, image_public_id character varying, moneda character varying, duracion_minutos integer, is_active boolean, comision_activa boolean, comision_pct numeric, bodega_id bigint, stock numeric, stock_min numeric, bodega_active boolean, total_rows bigint)
    LANGUAGE sql STABLE
    AS $$
                SELECT
                    p.id, p.empresa_id,
                    p.code, p.name, p.description, p.type, p.unit_measure,
                    p.cabys_code, p.partida_arancelaria, p.codigo_barras,
                    p.price, ROUND(p.price * (1 + p.tax_rate / 100), 5) AS price_with_tax,
                    p.tax_type, p.tax_code, p.tax_rate, p.tax_tarifa_codigo,
                    p.image_url, p.image_public_id, p.moneda, p.duracion_minutos, p.is_active,
                    p.comision_activa, p.comision_pct,
                    bp.bodega_id, bp.stock, bp.stock_min, bp.is_active AS bodega_active,
                    COUNT(*) OVER()::BIGINT AS total_rows
                FROM productos p
                LEFT JOIN bodega_productos bp ON bp.producto_id = p.id
                    AND (p_bodega_id IS NULL OR bp.bodega_id = p_bodega_id)
                WHERE p.empresa_id = p_empresa_id
                  AND p.deleted_at IS NULL
                  AND (p_search IS NULL OR p.name ILIKE '%' || p_search || '%' OR p.code ILIKE '%' || p_search || '%' OR p.cabys_code ILIKE '%' || p_search || '%')
                  AND (p_estado = 'todos' OR (p_estado = 'activos' AND p.is_active) OR (p_estado = 'inactivos' AND NOT p.is_active))
                ORDER BY p.name
                LIMIT GREATEST(p_per_page, 1) OFFSET GREATEST(p_page - 1, 0) * GREATEST(p_per_page, 1);
            $$;


--
-- Name: sp_producto_proveedor_resolver(bigint, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_proveedor_resolver(p_empresa_id bigint, p_proveedor_id bigint, p_codigo_proveedor character varying) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE v_producto_id BIGINT;
            BEGIN
                SELECT producto_id INTO v_producto_id
                FROM producto_proveedor_equivalencias
                WHERE empresa_id = p_empresa_id
                  AND proveedor_id = p_proveedor_id
                  AND codigo_proveedor = p_codigo_proveedor;
                RETURN v_producto_id;
            END;
            $$;


--
-- Name: sp_producto_proveedor_vincular(bigint, bigint, character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_proveedor_vincular(p_empresa_id bigint, p_proveedor_id bigint, p_codigo_proveedor character varying, p_producto_id bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO producto_proveedor_equivalencias (
                    empresa_id, proveedor_id, codigo_proveedor, producto_id
                ) VALUES (
                    p_empresa_id, p_proveedor_id, p_codigo_proveedor, p_producto_id
                )
                ON CONFLICT (empresa_id, proveedor_id, codigo_proveedor)
                DO UPDATE SET producto_id = p_producto_id, updated_at = NOW()
                RETURNING id INTO v_id;
                RETURN v_id;
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
-- Name: sp_producto_update(bigint, character varying, character varying, text, character varying, character varying, numeric, character varying, character varying, numeric, character varying, text, character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_update(p_id bigint, p_code character varying, p_name character varying, p_description text, p_unit_measure character varying, p_cabys_code character varying, p_price numeric, p_tax_type character varying, p_tax_code character varying, p_tax_rate numeric, p_tax_tarifa_codigo character varying, p_image_url text, p_image_public_id character varying, p_moneda character varying, p_codigo_barras character varying, p_partida_arancelaria character varying DEFAULT NULL::character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE productos SET
                    code         = p_code,
                    name         = p_name,
                    description  = p_description,
                    unit_measure = p_unit_measure,
                    cabys_code   = p_cabys_code,
                    partida_arancelaria = p_partida_arancelaria,
                    price        = p_price,
                    tax_type     = p_tax_type,
                    tax_code     = p_tax_code,
                    tax_rate     = p_tax_rate,
                    tax_tarifa_codigo = p_tax_tarifa_codigo,
                    image_url        = p_image_url,
                    image_public_id  = p_image_public_id,
                    moneda           = p_moneda,
                    codigo_barras    = p_codigo_barras,
                    updated_at   = NOW()
                WHERE id = p_id AND deleted_at IS NULL;

                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END;
            $$;


--
-- Name: sp_producto_update(bigint, character varying, character varying, text, character varying, character varying, numeric, character varying, character varying, numeric, character varying, text, character varying, character varying, character varying, character varying, boolean, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_update(p_id bigint, p_code character varying, p_name character varying, p_description text, p_unit_measure character varying, p_cabys_code character varying, p_price numeric, p_tax_type character varying, p_tax_code character varying, p_tax_rate numeric, p_tax_tarifa_codigo character varying, p_image_url text, p_image_public_id character varying, p_moneda character varying, p_codigo_barras character varying, p_partida_arancelaria character varying DEFAULT NULL::character varying, p_comision_activa boolean DEFAULT false, p_comision_pct numeric DEFAULT NULL::numeric) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE productos SET
                    code         = p_code,
                    name         = p_name,
                    description  = p_description,
                    unit_measure = p_unit_measure,
                    cabys_code   = p_cabys_code,
                    partida_arancelaria = p_partida_arancelaria,
                    price        = p_price,
                    tax_type     = p_tax_type,
                    tax_code     = p_tax_code,
                    tax_rate     = p_tax_rate,
                    tax_tarifa_codigo = p_tax_tarifa_codigo,
                    image_url        = p_image_url,
                    image_public_id  = p_image_public_id,
                    moneda           = p_moneda,
                    codigo_barras    = p_codigo_barras,
                    comision_activa  = COALESCE(p_comision_activa, FALSE),
                    comision_pct     = p_comision_pct,
                    updated_at   = NOW()
                WHERE id = p_id AND deleted_at IS NULL;

                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
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
-- Name: sp_proveedor_create(bigint, character varying, character varying, character varying, character varying, character varying, character varying, text, text, character varying, character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_create(p_empresa_id bigint, p_name character varying, p_legal_name character varying, p_tipo_id character varying, p_tax_id character varying, p_email character varying, p_phone character varying, p_address text, p_notes text, p_actividad_economica_codigo character varying DEFAULT NULL::character varying, p_actividad_economica_descripcion character varying DEFAULT NULL::character varying, p_province_code character varying DEFAULT NULL::character varying, p_canton_code character varying DEFAULT NULL::character varying, p_district_code character varying DEFAULT NULL::character varying) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO proveedores(empresa_id, name, legal_name, tipo_id, tax_id, email, phone,
                          address, notes, actividad_economica_codigo, actividad_economica_descripcion,
                          province_code, canton_code, district_code)
  VALUES (p_empresa_id, p_name, p_legal_name, p_tipo_id, p_tax_id, p_email, p_phone,
          p_address, p_notes, p_actividad_economica_codigo, p_actividad_economica_descripcion,
          p_province_code, p_canton_code, p_district_code)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;


--
-- Name: sp_proveedor_find_by_tax_id(character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_find_by_tax_id(p_tax_id character varying, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, legal_name character varying, tipo_id character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, province_code character varying, canton_code character varying, district_code character varying, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
  SELECT id, empresa_id, name, legal_name, tipo_id, tax_id, email, phone, address, notes,
         is_active, actividad_economica_codigo, actividad_economica_descripcion,
         province_code, canton_code, district_code,
         created_at, updated_at
  FROM   proveedores
  WHERE  tax_id = p_tax_id AND empresa_id = p_empresa_id AND deleted_at IS NULL LIMIT 1;
$$;


--
-- Name: sp_proveedor_list(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_list(p_empresa_id bigint, p_search text DEFAULT NULL::text) RETURNS TABLE(id bigint, empresa_id bigint, name character varying, legal_name character varying, tipo_id character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, is_active boolean, created_at timestamp without time zone, updated_at timestamp without time zone, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, province_code character varying, canton_code character varying, district_code character varying)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT p.id, p.empresa_id, p.name, p.legal_name, p.tipo_id, p.tax_id,
                       p.email, p.phone, p.address, p.notes, p.is_active,
                       p.created_at, p.updated_at,
                       p.actividad_economica_codigo, p.actividad_economica_descripcion,
                       p.province_code, p.canton_code, p.district_code
                FROM proveedores p
                WHERE p.empresa_id = p_empresa_id
                  AND p.deleted_at IS NULL
                  AND (
                    p_search IS NULL OR p_search = ''
                    OR p.name      ILIKE '%' || p_search || '%'
                    OR p.legal_name ILIKE '%' || p_search || '%'
                    OR p.tax_id    ILIKE '%' || p_search || '%'
                    OR p.email     ILIKE '%' || p_search || '%'
                  )
                ORDER BY p.name;
            END;
            $$;


--
-- Name: sp_proveedor_list_eliminados(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_list_eliminados(p_empresa_id bigint) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id character varying, email character varying, phone character varying, deleted_at timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT p.id, p.name, p.legal_name, p.tax_id, p.email, p.phone, p.deleted_at
                FROM proveedores p
                WHERE p.empresa_id = p_empresa_id AND p.deleted_at IS NOT NULL
                ORDER BY p.deleted_at DESC;
            END;
            $$;


--
-- Name: sp_proveedor_restore(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_restore(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                UPDATE proveedores
                SET deleted_at = NULL, is_active = TRUE, updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NOT NULL;
                RETURN FOUND;
            END;
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
-- Name: sp_proveedor_update(bigint, bigint, character varying, character varying, character varying, character varying, character varying, character varying, text, text, boolean, character varying, character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_update(p_id bigint, p_empresa_id bigint, p_name character varying, p_legal_name character varying, p_tipo_id character varying, p_tax_id character varying, p_email character varying, p_phone character varying, p_address text, p_notes text, p_is_active boolean, p_actividad_economica_codigo character varying DEFAULT NULL::character varying, p_actividad_economica_descripcion character varying DEFAULT NULL::character varying, p_province_code character varying DEFAULT NULL::character varying, p_canton_code character varying DEFAULT NULL::character varying, p_district_code character varying DEFAULT NULL::character varying) RETURNS boolean
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
    province_code                   = p_province_code,
    canton_code                     = p_canton_code,
    district_code                   = p_district_code,
    updated_at                      = NOW()
  WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
  RETURN FOUND;
END;
$$;


--
-- Name: sp_recibo_adelanto_aplicar(bigint, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_recibo_adelanto_aplicar(p_recibo_adelanto_id bigint, p_documento_id bigint, p_monto numeric) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_saldo NUMERIC;
            BEGIN
                SELECT saldo_disponible INTO v_saldo FROM recibos_adelanto WHERE id = p_recibo_adelanto_id FOR UPDATE;
                IF v_saldo IS NULL THEN
                    RAISE EXCEPTION 'Recibo de adelanto % no existe', p_recibo_adelanto_id;
                END IF;
                IF p_monto > v_saldo THEN
                    RAISE EXCEPTION 'El monto a aplicar (%) excede el saldo disponible (%)', p_monto, v_saldo;
                END IF;

                INSERT INTO recibos_adelanto_aplicaciones (recibo_adelanto_id, documento_id, monto_aplicado)
                VALUES (p_recibo_adelanto_id, p_documento_id, p_monto);

                UPDATE recibos_adelanto
                SET saldo_disponible = saldo_disponible - p_monto,
                    estado = CASE WHEN saldo_disponible - p_monto <= 0 THEN 'agotado' ELSE estado END,
                    updated_at = NOW()
                WHERE id = p_recibo_adelanto_id;

                RETURN TRUE;
            END; $$;


--
-- Name: sp_recibo_adelanto_create(bigint, bigint, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_recibo_adelanto_create(p_documento_id bigint, p_empresa_id bigint, p_cliente_id bigint, p_monto numeric) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO recibos_adelanto (empresa_id, documento_id, cliente_id, monto_original, saldo_disponible, estado)
                VALUES (p_empresa_id, p_documento_id, p_cliente_id, p_monto, p_monto, 'disponible')
                RETURNING id INTO v_id;
                RETURN v_id;
            END; $$;


--
-- Name: sp_recibo_pago_create(bigint, bigint, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_recibo_pago_create(p_documento_id bigint, p_empresa_id bigint, p_aplicaciones jsonb, p_medios_pago jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_item JSONB;
                v_cxc_id BIGINT;
                v_monto NUMERIC;
                v_saldo NUMERIC;
                v_medio JSONB;
            BEGIN
                IF EXISTS (SELECT 1 FROM documento_cxc_aplicaciones WHERE documento_id = p_documento_id) THEN
                    RETURN p_documento_id;
                END IF;

                FOR v_item IN SELECT * FROM jsonb_array_elements(p_aplicaciones) LOOP
                    v_cxc_id := (v_item->>'cuenta_por_cobrar_id')::BIGINT;
                    v_monto  := (v_item->>'monto')::NUMERIC;

                    SELECT saldo_pendiente INTO v_saldo FROM cuentas_por_cobrar WHERE id = v_cxc_id FOR UPDATE;
                    IF v_saldo IS NULL THEN
                        RAISE EXCEPTION 'Cuenta por cobrar % no existe', v_cxc_id;
                    END IF;
                    IF v_monto > v_saldo THEN
                        RAISE EXCEPTION 'El monto aplicado (%) excede el saldo pendiente (%) de la cuenta %', v_monto, v_saldo, v_cxc_id;
                    END IF;

                    INSERT INTO documento_cxc_aplicaciones (documento_id, cuenta_por_cobrar_id, monto_aplicado)
                    VALUES (p_documento_id, v_cxc_id, v_monto);

                    UPDATE cuentas_por_cobrar
                    SET saldo_pendiente = saldo_pendiente - v_monto,
                        estado = CASE WHEN saldo_pendiente - v_monto <= 0 THEN 'pagada' ELSE estado END,
                        updated_at = NOW()
                    WHERE id = v_cxc_id;
                END LOOP;

                FOR v_medio IN SELECT * FROM jsonb_array_elements(p_medios_pago) LOOP
                    INSERT INTO documento_medios_pago (
                        documento_id, tipo_medio_pago, medio_pago_otros, total_medio_pago,
                        id_tipo_pago, tipo_pago, referencia, autorizado
                    ) VALUES (
                        p_documento_id,
                        v_medio->>'tipo_medio_pago',
                        v_medio->>'medio_pago_otros',
                        (v_medio->>'total_medio_pago')::NUMERIC,
                        (v_medio->>'id_tipo_pago')::BIGINT,
                        v_medio->>'tipo_pago',
                        v_medio->>'referencia',
                        v_medio->>'autorizado'
                    );
                END LOOP;

                PERFORM sp_refrescar_estado_credito_cliente(
                    (SELECT cliente_id FROM cuentas_por_cobrar WHERE id = (p_aplicaciones->0->>'cuenta_por_cobrar_id')::BIGINT)
                );

                RETURN p_documento_id;
            END; $$;


--
-- Name: sp_refrescar_estado_credito_cliente(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_refrescar_estado_credito_cliente(p_cliente_id bigint) RETURNS character varying
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_max_atraso INTEGER;
    v_nuevo_estado VARCHAR;
BEGIN
    SELECT COALESCE(MAX(EXTRACT(DAY FROM NOW() - cxc.fecha_vencimiento))::INTEGER, 0)
    INTO v_max_atraso
    FROM cuentas_por_cobrar cxc
    WHERE cxc.cliente_id = p_cliente_id AND cxc.estado IN ('vigente','mora')
      AND cxc.fecha_vencimiento IS NOT NULL AND cxc.fecha_vencimiento < NOW()
      AND cxc.origen_venta = 'credito';

    v_nuevo_estado := CASE WHEN v_max_atraso > 0 THEN 'mora' ELSE 'al_dia' END;

    UPDATE clients SET estado_credito = v_nuevo_estado, updated_at = NOW()
    WHERE id = p_cliente_id AND estado_credito <> 'bloqueado';

    RETURN v_nuevo_estado;
END; $$;


--
-- Name: sp_reporte_cxc_mora(bigint, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_cxc_mora(p_empresa_id bigint, p_fecha_corte date DEFAULT CURRENT_DATE) RETURNS TABLE(id bigint, cliente_id bigint, cliente_nombre character varying, cliente_cedula character varying, documento_id bigint, moneda character varying, monto_total numeric, saldo_pendiente numeric, fecha_emision timestamp without time zone, fecha_vencimiento timestamp without time zone, dias_atraso integer, estado character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        cxc.id,
        cxc.cliente_id,
        c.name::VARCHAR,
        c.tax_id::VARCHAR,
        cxc.documento_id,
        COALESCE(d.moneda, 'CRC')::VARCHAR AS moneda,
        cxc.monto_total,
        cxc.saldo_pendiente,
        cxc.fecha_emision,
        cxc.fecha_vencimiento,
        GREATEST(0, (p_fecha_corte - cxc.fecha_vencimiento::date))::INTEGER AS dias_atraso,
        cxc.estado
    FROM cuentas_por_cobrar cxc
    JOIN clients c ON c.id = cxc.cliente_id
    LEFT JOIN documentos_electronicos d ON d.id = cxc.documento_id
    WHERE cxc.empresa_id = p_empresa_id
      AND cxc.estado IN ('vigente','mora')
      AND cxc.saldo_pendiente > 0
    ORDER BY COALESCE(d.moneda, 'CRC'), c.name, dias_atraso DESC, cxc.saldo_pendiente DESC;
END;
$$;


--
-- Name: sp_reporte_cxp(bigint, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_cxp(p_empresa_id bigint, p_fecha_corte date DEFAULT CURRENT_DATE) RETURNS TABLE(id bigint, proveedor_nombre character varying, proveedor_cedula character varying, numero_consecutivo_emisor character varying, clave character varying, moneda character varying, total_comprobante numeric, monto_pagado numeric, saldo_pendiente numeric, fecha_emision timestamp without time zone, fecha_vencimiento date, dias_atraso integer, estado character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    fr.id,
                    fr.emisor_nombre::VARCHAR,
                    fr.emisor_numero_id::VARCHAR,
                    fr.numero_consecutivo_emisor::VARCHAR,
                    fr.clave::VARCHAR,
                    fr.moneda::VARCHAR,
                    fr.total_comprobante::NUMERIC,
                    fr.monto_pagado::NUMERIC,
                    GREATEST(fr.total_comprobante - fr.monto_pagado, 0)::NUMERIC AS saldo_pendiente,
                    fr.fecha_emision,
                    fr.fecha_vencimiento,
                    CASE WHEN fr.fecha_vencimiento IS NULL THEN 0
                         ELSE GREATEST(0, (p_fecha_corte - fr.fecha_vencimiento))::INTEGER
                    END AS dias_atraso,
                    (CASE WHEN fr.fecha_vencimiento IS NOT NULL AND fr.fecha_vencimiento < p_fecha_corte
                          THEN 'vencida' ELSE 'vigente'
                     END)::VARCHAR AS estado
                FROM facturas_recibidas fr
                WHERE fr.empresa_id = p_empresa_id
                  AND fr.condicion_pago = 'credito'
                  AND fr.tipo_documento <> '10'
                  AND fr.estado_recepcion IN ('aceptado', 'aceptado_parcial')
                  AND fr.fecha_emision::date <= p_fecha_corte
                  AND fr.monto_pagado < fr.total_comprobante
                ORDER BY dias_atraso DESC, saldo_pendiente DESC;
            END; $$;


--
-- Name: sp_reporte_documentos_estado(bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_documentos_estado(p_empresa_id bigint, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date) RETURNS TABLE(estado character varying, tipo_documento character varying, tipo_label character varying, moneda character varying, cantidad bigint, total_comprobante numeric)
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
        END::VARCHAR                       AS tipo_label,
        COALESCE(d.moneda, 'CRC')::VARCHAR AS moneda,
        COUNT(*)::BIGINT                   AS cantidad,
        SUM(d.total_comprobante)           AS total_comprobante
    FROM documentos_electronicos d
    WHERE d.empresa_id  = p_empresa_id
      AND d.deleted_at  IS NULL
      AND (p_fecha_desde IS NULL OR d.fecha_emision::DATE >= p_fecha_desde)
      AND (p_fecha_hasta IS NULL OR d.fecha_emision::DATE <= p_fecha_hasta)
    GROUP BY d.estado, d.tipo_documento, COALESCE(d.moneda, 'CRC')
    ORDER BY d.estado, d.tipo_documento, COALESCE(d.moneda, 'CRC');
END;
$$;


--
-- Name: sp_reporte_facturas_recibidas_resumen(bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_facturas_recibidas_resumen(p_empresa_id bigint, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date) RETURNS TABLE(emisor_numero_id character varying, emisor_nombre character varying, estado_recepcion character varying, estado_hacienda character varying, moneda character varying, cantidad bigint, total_comprobante numeric, total_impuesto numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        COALESCE(f.emisor_numero_id, '')::VARCHAR          AS emisor_numero_id,
        COALESCE(MAX(f.emisor_nombre), 'Sin nombre')::VARCHAR AS emisor_nombre,
        f.estado_recepcion,
        f.estado_hacienda,
        COALESCE(f.moneda, 'CRC')::VARCHAR                 AS moneda,
        COUNT(*)::BIGINT                                   AS cantidad,
        SUM(f.total_comprobante)                           AS total_comprobante,
        SUM(f.total_impuesto)                              AS total_impuesto
    FROM facturas_recibidas f
    WHERE f.empresa_id = p_empresa_id
      AND (p_fecha_desde IS NULL OR f.created_at::DATE >= p_fecha_desde)
      AND (p_fecha_hasta IS NULL OR f.created_at::DATE <= p_fecha_hasta)
    GROUP BY COALESCE(f.emisor_numero_id, ''), f.estado_recepcion, f.estado_hacienda, COALESCE(f.moneda, 'CRC')
    ORDER BY MAX(f.emisor_nombre), f.estado_recepcion, COALESCE(f.moneda, 'CRC');
END;
$$;


--
-- Name: sp_reporte_inventario(bigint, bigint, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_inventario(p_empresa_id bigint, p_bodega_id bigint DEFAULT NULL::bigint, p_bajo_minimo boolean DEFAULT false, p_search text DEFAULT NULL::text) RETURNS TABLE(bodega_id bigint, bodega_nombre character varying, producto_id bigint, codigo character varying, nombre character varying, unidad_medida character varying, precio numeric, stock numeric, stock_min numeric, bajo_minimo boolean)
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
        COALESCE(p.unit_measure, '') AS unidad_medida,
        COALESCE(p.price, 0) AS precio,
        COALESCE(bp.stock, 0) AS stock,
        COALESCE(bp.stock_min, 0) AS stock_min,
        (COALESCE(bp.stock, 0) < 0
         OR (COALESCE(bp.stock_min, 0) > 0 AND COALESCE(bp.stock, 0) < bp.stock_min)) AS bajo_minimo
    FROM bodegas b
    JOIN bodega_productos bp ON bp.bodega_id = b.id
    JOIN productos p         ON p.id = bp.producto_id
    WHERE b.empresa_id  = p_empresa_id
      AND p.empresa_id  = p_empresa_id
      AND p.type        = 'product'
      AND (p_bodega_id IS NULL OR b.id = p_bodega_id)
      AND (
        NOT p_bajo_minimo
        OR COALESCE(bp.stock, 0) <= 0
        OR (COALESCE(bp.stock_min, 0) > 0 AND COALESCE(bp.stock, 0) < bp.stock_min)
      )
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
        COUNT(*) FILTER (WHERE COALESCE(bp.stock, 0) < 0
                            OR (COALESCE(bp.stock_min, 0) > 0 AND COALESCE(bp.stock, 0) < bp.stock_min)) AS bajo_minimo,
        COUNT(*) FILTER (WHERE COALESCE(bp.stock, 0) = 0) AS sin_stock
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
-- Name: sp_reporte_libro_compras(bigint, date, date, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_libro_compras(p_empresa_id bigint, p_fecha_desde date, p_fecha_hasta date, p_estado_recepcion character varying DEFAULT NULL::character varying) RETURNS TABLE(id bigint, fecha_emision timestamp without time zone, tipo_documento character varying, numero_consecutivo_emisor character varying, clave character varying, emisor_nombre character varying, emisor_numero_id character varying, moneda character varying, total_comprobante numeric, total_impuesto numeric, estado_recepcion character varying, estado_hacienda character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT
                    fr.id,
                    fr.fecha_emision,
                    fr.tipo_documento,
                    fr.numero_consecutivo_emisor,
                    fr.clave,
                    fr.emisor_nombre,
                    fr.emisor_numero_id,
                    fr.moneda,
                    fr.total_comprobante,
                    fr.total_impuesto,
                    fr.estado_recepcion,
                    fr.estado_hacienda
                FROM facturas_recibidas fr
                WHERE fr.empresa_id = p_empresa_id
                  AND fr.fecha_emision::date BETWEEN p_fecha_desde AND p_fecha_hasta
                  AND (p_estado_recepcion IS NULL OR fr.estado_recepcion = p_estado_recepcion)
                ORDER BY fr.fecha_emision;
            END; $$;


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
-- Name: sp_reporte_ranking_clientes(bigint, date, date, integer, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_ranking_clientes(p_empresa_id bigint, p_fecha_desde date, p_fecha_hasta date, p_limit integer DEFAULT 20, p_moneda character varying DEFAULT 'CRC'::character varying) RETURNS TABLE(posicion bigint, receptor_nombre character varying, receptor_numero_id character varying, cantidad_docs bigint, total_venta_neta numeric, total_impuesto numeric, total_comprobante numeric)
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
      AND COALESCE(d.moneda, 'CRC') = COALESCE(p_moneda, 'CRC')
      AND d.fecha_emision::DATE BETWEEN p_fecha_desde AND p_fecha_hasta
    GROUP BY d.receptor_nombre, d.receptor_numero_id
    ORDER BY SUM(d.total_comprobante) DESC
    LIMIT p_limit;
END;
$$;


--
-- Name: sp_reporte_ventas_periodo(bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_ventas_periodo(p_empresa_id bigint, p_fecha_desde date, p_fecha_hasta date) RETURNS TABLE(tipo_documento character varying, tipo_label character varying, moneda character varying, cantidad bigint, total_venta_neta numeric, total_impuesto numeric, total_comprobante numeric)
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
        END::VARCHAR                       AS tipo_label,
        COALESCE(d.moneda, 'CRC')::VARCHAR AS moneda,
        COUNT(*)::BIGINT                   AS cantidad,
        SUM(d.total_venta_neta)            AS total_venta_neta,
        SUM(d.total_impuesto)              AS total_impuesto,
        SUM(d.total_comprobante)           AS total_comprobante
    FROM documentos_electronicos d
    WHERE d.empresa_id  = p_empresa_id
      AND d.estado      = 'aceptado'
      AND d.deleted_at  IS NULL
      AND d.fecha_emision::DATE BETWEEN p_fecha_desde AND p_fecha_hasta
    GROUP BY d.tipo_documento, COALESCE(d.moneda, 'CRC')
    ORDER BY COALESCE(d.moneda, 'CRC'), SUM(d.total_comprobante) DESC;
END;
$$;


--
-- Name: sp_servicio_create(bigint, character varying, character varying, text, character varying, character varying, numeric, character varying, character varying, numeric, character varying, text, character varying, character varying, character varying, character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_servicio_create(p_empresa_id bigint, p_code character varying, p_name character varying, p_description text, p_unit_measure character varying, p_cabys_code character varying, p_price numeric, p_tax_type character varying, p_tax_code character varying, p_tax_rate numeric, p_tax_tarifa_codigo character varying, p_image_url text, p_image_public_id character varying, p_moneda character varying, p_codigo_barras character varying, p_partida_arancelaria character varying DEFAULT NULL::character varying, p_duracion_minutos integer DEFAULT NULL::integer) RETURNS TABLE(id bigint, code character varying, name character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_id BIGINT;
            BEGIN
                INSERT INTO servicios (
                    empresa_id, code, name, description, unit_measure,
                    cabys_code, partida_arancelaria, price, tax_type, tax_code, tax_rate, tax_tarifa_codigo,
                    image_url, image_public_id, moneda, codigo_barras, duracion_minutos
                ) VALUES (
                    p_empresa_id, p_code, p_name, p_description, p_unit_measure,
                    p_cabys_code, p_partida_arancelaria, p_price, p_tax_type, p_tax_code, p_tax_rate, p_tax_tarifa_codigo,
                    p_image_url, p_image_public_id, p_moneda, p_codigo_barras, p_duracion_minutos
                ) RETURNING servicios.id INTO v_id;

                RETURN QUERY SELECT v_id, p_code, p_name;
            END;
            $$;


--
-- Name: sp_servicio_create(bigint, character varying, character varying, text, character varying, character varying, numeric, character varying, character varying, numeric, character varying, text, character varying, character varying, character varying, character varying, integer, boolean, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_servicio_create(p_empresa_id bigint, p_code character varying, p_name character varying, p_description text, p_unit_measure character varying, p_cabys_code character varying, p_price numeric, p_tax_type character varying, p_tax_code character varying, p_tax_rate numeric, p_tax_tarifa_codigo character varying, p_image_url text, p_image_public_id character varying, p_moneda character varying, p_codigo_barras character varying, p_partida_arancelaria character varying DEFAULT NULL::character varying, p_duracion_minutos integer DEFAULT NULL::integer, p_comision_activa boolean DEFAULT false, p_comision_pct numeric DEFAULT NULL::numeric) RETURNS TABLE(id bigint, code character varying, name character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE
                v_id BIGINT;
            BEGIN
                INSERT INTO servicios (
                    empresa_id, code, name, description, unit_measure,
                    cabys_code, partida_arancelaria, price, tax_type, tax_code, tax_rate, tax_tarifa_codigo,
                    image_url, image_public_id, moneda, codigo_barras, duracion_minutos,
                    comision_activa, comision_pct
                ) VALUES (
                    p_empresa_id, p_code, p_name, p_description, p_unit_measure,
                    p_cabys_code, p_partida_arancelaria, p_price, p_tax_type, p_tax_code, p_tax_rate, p_tax_tarifa_codigo,
                    p_image_url, p_image_public_id, p_moneda, p_codigo_barras, p_duracion_minutos,
                    COALESCE(p_comision_activa, FALSE), p_comision_pct
                ) RETURNING servicios.id INTO v_id;

                RETURN QUERY SELECT v_id, p_code, p_name;
            END;
            $$;


--
-- Name: sp_servicio_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_servicio_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, code character varying, name character varying, description text, type character varying, unit_measure character varying, cabys_code character varying, partida_arancelaria character varying, codigo_barras character varying, price numeric, price_with_tax numeric, tax_type character varying, tax_code character varying, tax_rate numeric, tax_tarifa_codigo character varying, image_url text, image_public_id character varying, moneda character varying, duracion_minutos integer, is_active boolean, comision_activa boolean, comision_pct numeric)
    LANGUAGE sql STABLE
    AS $$
                SELECT
                    s.id, s.empresa_id,
                    s.code, s.name, s.description, 'service'::VARCHAR, s.unit_measure,
                    s.cabys_code, s.partida_arancelaria, s.codigo_barras,
                    s.price, ROUND(s.price * (1 + s.tax_rate / 100), 5) AS price_with_tax,
                    s.tax_type, s.tax_code, s.tax_rate, s.tax_tarifa_codigo,
                    s.image_url, s.image_public_id, s.moneda, s.duracion_minutos, s.is_active,
                    s.comision_activa, s.comision_pct
                FROM servicios s
                WHERE s.id = p_id
                  AND s.empresa_id = p_empresa_id
                  AND s.deleted_at IS NULL;
            $$;


--
-- Name: sp_servicio_list(bigint, character varying, character varying, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_servicio_list(p_empresa_id bigint, p_search character varying DEFAULT NULL::character varying, p_estado character varying DEFAULT 'todos'::character varying, p_page integer DEFAULT 1, p_per_page integer DEFAULT 20) RETURNS TABLE(id bigint, empresa_id bigint, code character varying, name character varying, description text, type character varying, unit_measure character varying, cabys_code character varying, partida_arancelaria character varying, codigo_barras character varying, price numeric, price_with_tax numeric, tax_type character varying, tax_code character varying, tax_rate numeric, tax_tarifa_codigo character varying, image_url text, image_public_id character varying, moneda character varying, duracion_minutos integer, is_active boolean, comision_activa boolean, comision_pct numeric, total_rows bigint)
    LANGUAGE sql STABLE
    AS $$
                SELECT
                    s.id, s.empresa_id,
                    s.code, s.name, s.description, 'service'::VARCHAR, s.unit_measure,
                    s.cabys_code, s.partida_arancelaria, s.codigo_barras,
                    s.price, ROUND(s.price * (1 + s.tax_rate / 100), 5) AS price_with_tax,
                    s.tax_type, s.tax_code, s.tax_rate, s.tax_tarifa_codigo,
                    s.image_url, s.image_public_id, s.moneda, s.duracion_minutos, s.is_active,
                    s.comision_activa, s.comision_pct,
                    COUNT(*) OVER()::BIGINT AS total_rows
                FROM servicios s
                WHERE s.empresa_id = p_empresa_id
                  AND s.deleted_at IS NULL
                  AND (p_search IS NULL OR s.name ILIKE '%' || p_search || '%' OR s.code ILIKE '%' || p_search || '%' OR s.cabys_code ILIKE '%' || p_search || '%')
                  AND (p_estado = 'todos' OR (p_estado = 'activos' AND s.is_active) OR (p_estado = 'inactivos' AND NOT s.is_active))
                ORDER BY s.name
                LIMIT GREATEST(p_per_page, 1) OFFSET GREATEST(p_page - 1, 0) * GREATEST(p_per_page, 1);
            $$;


--
-- Name: sp_servicio_soft_delete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_servicio_soft_delete(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE servicios SET is_active = FALSE, deleted_at = NOW(), updated_at = NOW()
                WHERE id = p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_servicio_toggle(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_servicio_toggle(p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE servicios SET is_active = NOT is_active, updated_at = NOW()
                WHERE id = p_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_servicio_update(bigint, character varying, character varying, text, character varying, character varying, numeric, character varying, character varying, numeric, character varying, text, character varying, character varying, character varying, character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_servicio_update(p_id bigint, p_code character varying, p_name character varying, p_description text, p_unit_measure character varying, p_cabys_code character varying, p_price numeric, p_tax_type character varying, p_tax_code character varying, p_tax_rate numeric, p_tax_tarifa_codigo character varying, p_image_url text, p_image_public_id character varying, p_moneda character varying, p_codigo_barras character varying, p_partida_arancelaria character varying DEFAULT NULL::character varying, p_duracion_minutos integer DEFAULT NULL::integer) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE servicios SET
                    code                = p_code,
                    name                = p_name,
                    description         = p_description,
                    unit_measure        = p_unit_measure,
                    cabys_code          = p_cabys_code,
                    partida_arancelaria = p_partida_arancelaria,
                    price               = p_price,
                    tax_type            = p_tax_type,
                    tax_code            = p_tax_code,
                    tax_rate            = p_tax_rate,
                    tax_tarifa_codigo   = p_tax_tarifa_codigo,
                    image_url           = p_image_url,
                    image_public_id     = p_image_public_id,
                    moneda              = p_moneda,
                    codigo_barras       = p_codigo_barras,
                    duracion_minutos    = p_duracion_minutos,
                    updated_at          = NOW()
                WHERE id = p_id AND deleted_at IS NULL;

                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END;
            $$;


--
-- Name: sp_servicio_update(bigint, character varying, character varying, text, character varying, character varying, numeric, character varying, character varying, numeric, character varying, text, character varying, character varying, character varying, character varying, integer, boolean, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_servicio_update(p_id bigint, p_code character varying, p_name character varying, p_description text, p_unit_measure character varying, p_cabys_code character varying, p_price numeric, p_tax_type character varying, p_tax_code character varying, p_tax_rate numeric, p_tax_tarifa_codigo character varying, p_image_url text, p_image_public_id character varying, p_moneda character varying, p_codigo_barras character varying, p_partida_arancelaria character varying DEFAULT NULL::character varying, p_duracion_minutos integer DEFAULT NULL::integer, p_comision_activa boolean DEFAULT false, p_comision_pct numeric DEFAULT NULL::numeric) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE servicios SET
                    code                = p_code,
                    name                = p_name,
                    description         = p_description,
                    unit_measure        = p_unit_measure,
                    cabys_code          = p_cabys_code,
                    partida_arancelaria = p_partida_arancelaria,
                    price               = p_price,
                    tax_type            = p_tax_type,
                    tax_code            = p_tax_code,
                    tax_rate            = p_tax_rate,
                    tax_tarifa_codigo   = p_tax_tarifa_codigo,
                    image_url           = p_image_url,
                    image_public_id     = p_image_public_id,
                    moneda              = p_moneda,
                    codigo_barras       = p_codigo_barras,
                    duracion_minutos    = p_duracion_minutos,
                    comision_activa     = COALESCE(p_comision_activa, FALSE),
                    comision_pct        = p_comision_pct,
                    updated_at          = NOW()
                WHERE id = p_id AND deleted_at IS NULL;

                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END;
            $$;


--
-- Name: sp_sucursal_bodega_sync(bigint, bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_sucursal_bodega_sync(p_bodega_id bigint, p_sucursal_ids bigint[]) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  DELETE FROM sucursal_bodegas WHERE bodega_id = p_bodega_id;
  INSERT INTO sucursal_bodegas (sucursal_id, bodega_id)
  SELECT unnest(p_sucursal_ids), p_bodega_id
  ON CONFLICT DO NOTHING;
END;
$$;


--
-- Name: sp_sucursal_horario_get(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_sucursal_horario_get(p_sucursal_id bigint) RETURNS TABLE(sucursal_id bigint, horario_semanal jsonb)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                SELECT sh.sucursal_id, sh.horario_semanal
                FROM sucursal_horarios sh
                WHERE sh.sucursal_id = p_sucursal_id;
            END; $$;


--
-- Name: sp_sucursal_horario_upsert(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_sucursal_horario_upsert(p_sucursal_id bigint, p_horario_semanal jsonb) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            BEGIN
                INSERT INTO sucursal_horarios (sucursal_id, horario_semanal, updated_at)
                VALUES (p_sucursal_id, COALESCE(p_horario_semanal, '[]'::jsonb), NOW())
                ON CONFLICT (sucursal_id) DO UPDATE
                    SET horario_semanal = EXCLUDED.horario_semanal,
                        updated_at = NOW();
                RETURN TRUE;
            END; $$;


--
-- Name: sp_tipo_cod_ref_delete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_tipo_cod_ref_delete(p_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    UPDATE tipos_codigo_referencia SET deleted_at = NOW() WHERE id = p_id AND deleted_at IS NULL;
END;
$$;


--
-- Name: sp_tipo_cod_ref_list(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_tipo_cod_ref_list(p_solo_activos boolean DEFAULT true) RETURNS TABLE(id bigint, codigo character varying, nombre character varying, activo boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
        SELECT r.id, r.codigo, r.nombre, r.activo, r.created_at, r.updated_at
          FROM tipos_codigo_referencia r
         WHERE r.deleted_at IS NULL
           AND (p_solo_activos = FALSE OR r.activo = TRUE)
         ORDER BY r.codigo;
END;
$$;


--
-- Name: sp_tipo_cod_ref_save(bigint, character varying, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_tipo_cod_ref_save(p_id bigint, p_codigo character varying, p_nombre character varying, p_activo boolean DEFAULT true) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE v_id BIGINT;
BEGIN
    IF p_id IS NULL OR p_id = 0 THEN
        INSERT INTO tipos_codigo_referencia (codigo, nombre, activo, created_at, updated_at)
        VALUES (p_codigo, p_nombre, p_activo, NOW(), NOW())
        RETURNING id INTO v_id;
    ELSE
        UPDATE tipos_codigo_referencia
           SET codigo = p_codigo, nombre = p_nombre, activo = p_activo, updated_at = NOW()
         WHERE id = p_id AND deleted_at IS NULL
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;


--
-- Name: sp_tipo_doc_ref_delete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_tipo_doc_ref_delete(p_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    UPDATE tipos_documento_referencia SET deleted_at = NOW() WHERE id = p_id AND deleted_at IS NULL;
END;
$$;


--
-- Name: sp_tipo_doc_ref_list(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_tipo_doc_ref_list(p_solo_activos boolean DEFAULT true) RETURNS TABLE(id bigint, codigo character varying, nombre character varying, activo boolean, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
        SELECT r.id, r.codigo, r.nombre, r.activo, r.created_at, r.updated_at
          FROM tipos_documento_referencia r
         WHERE r.deleted_at IS NULL
           AND (p_solo_activos = FALSE OR r.activo = TRUE)
         ORDER BY r.codigo;
END;
$$;


--
-- Name: sp_tipo_doc_ref_save(bigint, character varying, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_tipo_doc_ref_save(p_id bigint, p_codigo character varying, p_nombre character varying, p_activo boolean DEFAULT true) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE v_id BIGINT;
BEGIN
    IF p_id IS NULL OR p_id = 0 THEN
        INSERT INTO tipos_documento_referencia (codigo, nombre, activo, created_at, updated_at)
        VALUES (p_codigo, p_nombre, p_activo, NOW(), NOW())
        RETURNING id INTO v_id;
    ELSE
        UPDATE tipos_documento_referencia
           SET codigo = p_codigo, nombre = p_nombre, activo = p_activo, updated_at = NOW()
         WHERE id = p_id AND deleted_at IS NULL
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;


--
-- Name: sp_validar_credito_cliente(bigint, bigint, numeric, character varying, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_validar_credito_cliente(p_empresa_id bigint, p_cliente_id bigint, p_monto_nuevo numeric, p_moneda character varying DEFAULT 'CRC'::character varying, p_tipo_cambio numeric DEFAULT 1) RETURNS TABLE(permitido boolean, motivo character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_limite     NUMERIC;
    v_saldo      NUMERIC;
    v_estado     VARCHAR;
    v_gracia     INTEGER;
    v_bloqueo    INTEGER;
    v_max_atraso INTEGER;
    v_tc_doc     NUMERIC := COALESCE(NULLIF(p_tipo_cambio, 0), 1);
    v_tc_vigente NUMERIC;
    v_nuevo_crc  NUMERIC;
BEGIN
    SELECT c.limite_credito, c.estado_credito
    INTO v_limite, v_estado
    FROM clients c WHERE c.id = p_cliente_id;

    SELECT tc.venta INTO v_tc_vigente
    FROM empresa_tipo_cambios tc
    WHERE tc.empresa_id = p_empresa_id AND tc.fecha <= CURRENT_DATE
    ORDER BY tc.fecha DESC
    LIMIT 1;

    v_nuevo_crc := p_monto_nuevo * CASE WHEN COALESCE(p_moneda, 'CRC') = 'CRC' THEN 1 ELSE v_tc_doc END;

    SELECT COALESCE(SUM(
               cxc.saldo_pendiente * CASE
                   WHEN COALESCE(d.moneda, 'CRC') = 'CRC'      THEN 1
                   WHEN d.moneda = COALESCE(p_moneda, 'CRC')    THEN v_tc_doc
                   WHEN d.moneda = 'USD' AND v_tc_vigente > 0   THEN v_tc_vigente
                   ELSE COALESCE(NULLIF(d.tipo_cambio, 0), 1)
               END
           ), 0)
    INTO v_saldo
    FROM cuentas_por_cobrar cxc
    JOIN documentos_electronicos d ON d.id = cxc.documento_id
    WHERE cxc.cliente_id = p_cliente_id AND cxc.estado IN ('vigente','mora')
      AND cxc.origen_venta = 'credito';

    SELECT cs.dias_gracia_mora, cs.dias_bloqueo_venta
    INTO v_gracia, v_bloqueo
    FROM company_settings cs WHERE cs.empresa_id = p_empresa_id;

    SELECT COALESCE(MAX(EXTRACT(DAY FROM NOW() - cxc.fecha_vencimiento))::INTEGER, 0)
    INTO v_max_atraso
    FROM cuentas_por_cobrar cxc
    WHERE cxc.cliente_id = p_cliente_id AND cxc.estado IN ('vigente','mora')
      AND cxc.fecha_vencimiento IS NOT NULL
      AND cxc.origen_venta = 'credito';

    IF v_estado = 'bloqueado' OR v_max_atraso > COALESCE(v_gracia,0) + COALESCE(v_bloqueo,0) THEN
        RETURN QUERY SELECT FALSE, 'Cliente en mora, bloqueado para ventas a crédito'::VARCHAR;
        RETURN;
    END IF;

    IF v_saldo + v_nuevo_crc > v_limite THEN
        RETURN QUERY SELECT FALSE, (
            'Excede el límite de crédito autorizado (₡' || to_char(v_limite, 'FM999G999G999G990D00') ||
            '): saldo ₡' || to_char(v_saldo, 'FM999G999G999G990D00') ||
            ' + esta venta ₡' || to_char(v_nuevo_crc, 'FM999G999G999G990D00') ||
            CASE WHEN COALESCE(p_moneda, 'CRC') <> 'CRC'
                 THEN ' (' || p_moneda || ' ' || to_char(p_monto_nuevo, 'FM999G999G999G990D00') ||
                      ' a tipo de cambio ' || to_char(v_tc_doc, 'FM999990D00') || ')'
                 ELSE '' END
        )::VARCHAR;
        RETURN;
    END IF;

    RETURN QUERY SELECT TRUE, NULL::VARCHAR;
END; $$;


--
-- Name: agenda_avisos_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agenda_avisos_config (
    empresa_id bigint NOT NULL,
    aviso_creacion_activo boolean DEFAULT true NOT NULL,
    aviso_creacion_mensaje text,
    aviso_dia_antes_activo boolean DEFAULT true NOT NULL,
    aviso_dia_antes_mensaje text,
    aviso_discrecional_activo boolean DEFAULT false NOT NULL,
    aviso_discrecional_dias integer DEFAULT 3 NOT NULL,
    aviso_discrecional_mensaje text,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: agenda_avisos_envios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agenda_avisos_envios (
    id bigint NOT NULL,
    evento_id bigint NOT NULL,
    tipo character varying(20) NOT NULL,
    enviado_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_agenda_avisos_envios_tipo CHECK (((tipo)::text = ANY ((ARRAY['creacion'::character varying, 'dia_antes'::character varying, 'discrecional'::character varying])::text[])))
);


--
-- Name: agenda_avisos_envios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agenda_avisos_envios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agenda_avisos_envios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agenda_avisos_envios_id_seq OWNED BY public.agenda_avisos_envios.id;


--
-- Name: agenda_avisos_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agenda_avisos_tokens (
    id bigint NOT NULL,
    evento_id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    token character varying(64) NOT NULL,
    expira_at timestamp without time zone NOT NULL,
    usado_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: agenda_avisos_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agenda_avisos_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agenda_avisos_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agenda_avisos_tokens_id_seq OWNED BY public.agenda_avisos_tokens.id;


--
-- Name: agenda_evento_linea_productos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agenda_evento_linea_productos (
    id bigint NOT NULL,
    linea_id bigint NOT NULL,
    producto_id bigint NOT NULL,
    cantidad numeric(15,4) DEFAULT 1 NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: agenda_evento_linea_productos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agenda_evento_linea_productos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agenda_evento_linea_productos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agenda_evento_linea_productos_id_seq OWNED BY public.agenda_evento_linea_productos.id;


--
-- Name: agenda_evento_lineas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agenda_evento_lineas (
    id bigint NOT NULL,
    evento_id bigint NOT NULL,
    servicio_id bigint NOT NULL,
    funcionario_id bigint,
    comentario text,
    ubicacion character varying(200),
    orden integer DEFAULT 0 NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    fecha_inicio timestamp without time zone NOT NULL,
    fecha_fin timestamp without time zone NOT NULL
);


--
-- Name: agenda_evento_lineas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agenda_evento_lineas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agenda_evento_lineas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agenda_evento_lineas_id_seq OWNED BY public.agenda_evento_lineas.id;


--
-- Name: agenda_eventos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agenda_eventos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    sucursal_id bigint,
    user_id bigint NOT NULL,
    titulo character varying(200) NOT NULL,
    fecha_inicio timestamp without time zone NOT NULL,
    fecha_fin timestamp without time zone NOT NULL,
    todo_el_dia boolean DEFAULT false NOT NULL,
    cliente_id bigint,
    color character varying(20),
    estado character varying(20) DEFAULT 'agendado'::character varying NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    documento_id bigint,
    CONSTRAINT chk_agenda_evento_estado CHECK (((estado)::text = ANY ((ARRAY['agendado'::character varying, 'confirmado'::character varying, 'cancelado'::character varying, 'completado'::character varying])::text[])))
);


--
-- Name: agenda_eventos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agenda_eventos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'agenda_eventos'::character varying NOT NULL,
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
-- Name: agenda_eventos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agenda_eventos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agenda_eventos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agenda_eventos_auditoria_id_seq OWNED BY public.agenda_eventos_auditoria.id;


--
-- Name: agenda_eventos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agenda_eventos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agenda_eventos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agenda_eventos_id_seq OWNED BY public.agenda_eventos.id;


--
-- Name: bitacora_api; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bitacora_api (
    id bigint NOT NULL,
    user_id bigint,
    empresa_id bigint,
    sucursal_id bigint,
    metodo character varying(10) NOT NULL,
    endpoint character varying(500) NOT NULL,
    request_headers jsonb,
    request_body jsonb,
    response_status integer,
    response_body jsonb,
    ip_address character varying(45),
    user_agent text,
    duracion_ms integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: bitacora_api_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bitacora_api_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bitacora_api_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bitacora_api_id_seq OWNED BY public.bitacora_api.id;


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
-- Name: caja_cierre_medios_pago; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.caja_cierre_medios_pago (
    id bigint NOT NULL,
    cierre_id bigint NOT NULL,
    tipo_medio_pago character varying(2) NOT NULL,
    descripcion character varying(100),
    monto_sistema numeric(15,5) DEFAULT 0 NOT NULL,
    monto_declarado numeric(15,5) DEFAULT 0 NOT NULL,
    diferencia numeric(15,5) DEFAULT 0 NOT NULL,
    moneda character varying(3) DEFAULT 'CRC'::character varying NOT NULL
);


--
-- Name: caja_cierre_medios_pago_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.caja_cierre_medios_pago_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: caja_cierre_medios_pago_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.caja_cierre_medios_pago_id_seq OWNED BY public.caja_cierre_medios_pago.id;


--
-- Name: caja_cierres; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.caja_cierres (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    sucursal_id bigint NOT NULL,
    caja_id bigint NOT NULL,
    user_id bigint NOT NULL,
    user_nombre character varying(200),
    fecha_inicio timestamp without time zone NOT NULL,
    fecha_fin timestamp without time zone NOT NULL,
    total_documentos integer DEFAULT 0 NOT NULL,
    total_sistema numeric(15,5) DEFAULT 0 NOT NULL,
    total_declarado numeric(15,5) DEFAULT 0 NOT NULL,
    diferencia numeric(15,5) DEFAULT 0 NOT NULL,
    observaciones text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    fondo_inicial jsonb DEFAULT '{}'::jsonb NOT NULL,
    efectivo_denominaciones jsonb DEFAULT '[]'::jsonb NOT NULL,
    egresos jsonb DEFAULT '[]'::jsonb NOT NULL,
    totales_moneda jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: COLUMN caja_cierres.fondo_inicial; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caja_cierres.fondo_inicial IS 'Monto base recibido al abrir turno, por moneda. Ej: {"CRC": 50000, "USD": 100}';


--
-- Name: COLUMN caja_cierres.efectivo_denominaciones; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caja_cierres.efectivo_denominaciones IS 'Conteo físico de billetes/monedas: [{moneda, denominacion, cantidad, subtotal}]';


--
-- Name: COLUMN caja_cierres.egresos; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caja_cierres.egresos IS 'Gastos/retiros de efectivo durante el turno: [{concepto, monto, moneda}]';


--
-- Name: COLUMN caja_cierres.totales_moneda; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.caja_cierres.totales_moneda IS 'Conciliación completa por moneda: {"CRC": {total_sistema, total_declarado, diferencia, total_efectivo_fisico, total_egresos, total_general_ingresado, total_ventas_netas_fisicas}, "USD": {...}}';


--
-- Name: caja_cierres_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.caja_cierres_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: caja_cierres_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.caja_cierres_id_seq OWNED BY public.caja_cierres.id;


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
    birth_date date,
    province_code character varying(1),
    canton_code character varying(2),
    district_code character varying(2),
    dias_credito integer DEFAULT 0 NOT NULL,
    limite_credito numeric(18,5) DEFAULT 0 NOT NULL,
    estado_credito character varying(20) DEFAULT 'al_dia'::character varying NOT NULL,
    porcentaje_descuento numeric(5,2) DEFAULT 0 NOT NULL,
    central_client_id bigint,
    CONSTRAINT chk_clients_estado_credito CHECK (((estado_credito)::text = ANY ((ARRAY['al_dia'::character varying, 'mora'::character varying, 'bloqueado'::character varying])::text[])))
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
    dias_gracia_mora integer DEFAULT 0 NOT NULL,
    dias_bloqueo_venta integer DEFAULT 0 NOT NULL,
    clients_managed_by_central boolean DEFAULT false NOT NULL,
    onvo_customer_id character varying(50),
    onvo_payment_method_id character varying(50),
    onvo_card_brand character varying(20),
    onvo_card_last4 character varying(4),
    onvo_card_exp_month smallint,
    onvo_card_exp_year smallint,
    CONSTRAINT company_settings_hacienda_environment_check CHECK (((hacienda_environment)::text = ANY ((ARRAY['stag'::character varying, 'prod'::character varying])::text[]))),
    CONSTRAINT company_settings_validation_status_check CHECK (((validation_status)::text = ANY ((ARRAY['pending'::character varying, 'valid'::character varying, 'invalid'::character varying])::text[])))
);


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
-- Name: cotizacion_consecutivos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cotizacion_consecutivos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    ultimo_numero bigint DEFAULT 0 NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: cotizacion_consecutivos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cotizacion_consecutivos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cotizacion_consecutivos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cotizacion_consecutivos_id_seq OWNED BY public.cotizacion_consecutivos.id;


--
-- Name: cotizaciones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cotizaciones (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    sucursal_id bigint NOT NULL,
    user_id bigint NOT NULL,
    funcionario_id bigint,
    numero character varying(20) NOT NULL,
    fecha_emision timestamp without time zone DEFAULT now() NOT NULL,
    fecha_vigencia date,
    condicion_venta character varying(2),
    condicion_venta_otros text,
    plazo_credito character varying(10),
    moneda character varying(3) DEFAULT 'CRC'::character varying NOT NULL,
    tipo_cambio numeric(18,5) DEFAULT 1 NOT NULL,
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
    lineas jsonb DEFAULT '[]'::jsonb NOT NULL,
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
    notas text,
    motivo_rechazo text,
    otros_texto text,
    estado character varying(20) DEFAULT 'borrador'::character varying NOT NULL,
    aprobado_por bigint,
    aprobado_at timestamp without time zone,
    rechazado_at timestamp without time zone,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_cotizacion_estado CHECK (((estado)::text = ANY ((ARRAY['borrador'::character varying, 'enviada'::character varying, 'aprobada'::character varying, 'rechazada'::character varying, 'convertida'::character varying, 'convertida_parcial'::character varying])::text[])))
);


--
-- Name: cotizaciones_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cotizaciones_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'cotizaciones'::character varying NOT NULL,
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
-- Name: cotizaciones_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cotizaciones_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cotizaciones_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cotizaciones_auditoria_id_seq OWNED BY public.cotizaciones_auditoria.id;


--
-- Name: cotizaciones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cotizaciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cotizaciones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cotizaciones_id_seq OWNED BY public.cotizaciones.id;


--
-- Name: cuentas_por_cobrar; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cuentas_por_cobrar (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    documento_id bigint NOT NULL,
    cliente_id bigint NOT NULL,
    monto_total numeric(18,5) NOT NULL,
    saldo_pendiente numeric(18,5) NOT NULL,
    fecha_emision timestamp without time zone NOT NULL,
    fecha_vencimiento timestamp without time zone,
    estado character varying(20) DEFAULT 'vigente'::character varying NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    origen_venta character varying(10) DEFAULT 'credito'::character varying NOT NULL,
    CONSTRAINT chk_cxc_estado CHECK (((estado)::text = ANY ((ARRAY['vigente'::character varying, 'mora'::character varying, 'pagada'::character varying, 'anulada'::character varying])::text[]))),
    CONSTRAINT chk_cxc_origen_venta CHECK (((origen_venta)::text = ANY ((ARRAY['credito'::character varying, 'apartado'::character varying])::text[])))
);


--
-- Name: cuentas_por_cobrar_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cuentas_por_cobrar_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cuentas_por_cobrar_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cuentas_por_cobrar_id_seq OWNED BY public.cuentas_por_cobrar.id;


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
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    terminal character varying(5) DEFAULT '00001'::character varying NOT NULL
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
-- Name: documento_cxc_aplicaciones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_cxc_aplicaciones (
    id bigint NOT NULL,
    documento_id bigint NOT NULL,
    cuenta_por_cobrar_id bigint NOT NULL,
    monto_aplicado numeric(18,5) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: documento_cxc_aplicaciones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_cxc_aplicaciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_cxc_aplicaciones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documento_cxc_aplicaciones_id_seq OWNED BY public.documento_cxc_aplicaciones.id;


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
    funcionario_id bigint,
    partida_arancelaria character varying(12)
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
    medio_pago_otros character varying(100),
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
    tipo_doc_ref_otro character varying(100),
    numero character varying(50) NOT NULL,
    fecha_emision_ir timestamp without time zone NOT NULL,
    codigo character varying(2) NOT NULL,
    codigo_referencia_otro character varying(100),
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
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    simbolo character varying(10) DEFAULT ''::character varying NOT NULL
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
-- Name: empresa_tarifas_impuesto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_tarifas_impuesto (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    codigo character varying(10) NOT NULL,
    tarifa_impuesto character varying(150) NOT NULL,
    tarifa numeric(8,4) DEFAULT 0 NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: empresa_tarifas_impuesto_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_tarifas_impuesto_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_tarifas_impuesto_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_tarifas_impuesto_id_seq OWNED BY public.empresa_tarifas_impuesto.id;


--
-- Name: empresa_tipo_cambios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_tipo_cambios (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    fecha date NOT NULL,
    compra numeric(12,4) NOT NULL,
    venta numeric(12,4) NOT NULL,
    fuente character varying(100) DEFAULT 'Manual'::character varying NOT NULL,
    created_by bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: empresa_tipo_cambios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_tipo_cambios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_tipo_cambios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_tipo_cambios_id_seq OWNED BY public.empresa_tipo_cambios.id;


--
-- Name: empresa_tipos_descuento; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_tipos_descuento (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    codigo character varying(10) NOT NULL,
    tipo_descuento character varying(150) NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: empresa_tipos_descuento_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_tipos_descuento_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_tipos_descuento_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_tipos_descuento_id_seq OWNED BY public.empresa_tipos_descuento.id;


--
-- Name: empresa_tipos_impuesto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_tipos_impuesto (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    codigo character varying(10) NOT NULL,
    nombre_impuesto character varying(150) NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: empresa_tipos_impuesto_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_tipos_impuesto_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_tipos_impuesto_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_tipos_impuesto_id_seq OWNED BY public.empresa_tipos_impuesto.id;


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
-- Name: funcionario_sucursales; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.funcionario_sucursales (
    id bigint NOT NULL,
    funcionario_id bigint NOT NULL,
    sucursal_id bigint NOT NULL,
    sucursal_name character varying(150),
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: funcionario_sucursales_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.funcionario_sucursales_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: funcionario_sucursales_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.funcionario_sucursales_id_seq OWNED BY public.funcionario_sucursales.id;


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
    is_default boolean DEFAULT false NOT NULL,
    color character varying(20),
    horario_semanal jsonb DEFAULT '[]'::jsonb NOT NULL
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
-- Name: mercadeo_campana_envios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mercadeo_campana_envios (
    id bigint NOT NULL,
    campana_id bigint NOT NULL,
    cliente_id bigint NOT NULL,
    destino character varying(255) NOT NULL,
    estado character varying(20) DEFAULT 'pendiente'::character varying NOT NULL,
    error_mensaje text,
    enviado_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_mercadeo_campana_envios_estado CHECK (((estado)::text = ANY ((ARRAY['pendiente'::character varying, 'enviado'::character varying, 'fallido'::character varying, 'pendiente_integracion'::character varying])::text[])))
);


--
-- Name: mercadeo_campana_envios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mercadeo_campana_envios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mercadeo_campana_envios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mercadeo_campana_envios_id_seq OWNED BY public.mercadeo_campana_envios.id;


--
-- Name: mercadeo_campanas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mercadeo_campanas (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    plantilla_id bigint NOT NULL,
    nombre character varying(150) NOT NULL,
    canal character varying(10) NOT NULL,
    estado character varying(20) DEFAULT 'borrador'::character varying NOT NULL,
    total_destinatarios integer DEFAULT 0 NOT NULL,
    total_enviados integer DEFAULT 0 NOT NULL,
    total_fallidos integer DEFAULT 0 NOT NULL,
    filtro_destinatarios jsonb,
    enviado_por bigint,
    enviado_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    deleted_at timestamp without time zone,
    CONSTRAINT chk_mercadeo_campanas_canal CHECK (((canal)::text = ANY ((ARRAY['email'::character varying, 'whatsapp'::character varying])::text[]))),
    CONSTRAINT chk_mercadeo_campanas_estado CHECK (((estado)::text = ANY ((ARRAY['borrador'::character varying, 'enviando'::character varying, 'enviada'::character varying, 'fallida'::character varying])::text[])))
);


--
-- Name: mercadeo_campanas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mercadeo_campanas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mercadeo_campanas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mercadeo_campanas_id_seq OWNED BY public.mercadeo_campanas.id;


--
-- Name: mercadeo_plantillas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mercadeo_plantillas (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    categoria character varying(20) NOT NULL,
    canal character varying(10) NOT NULL,
    nombre character varying(150) NOT NULL,
    asunto character varying(200),
    contenido_html text,
    contenido_texto text,
    variables_usadas jsonb,
    activo boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    deleted_at timestamp without time zone,
    CONSTRAINT chk_mercadeo_plantillas_canal CHECK (((canal)::text = ANY ((ARRAY['email'::character varying, 'whatsapp'::character varying])::text[]))),
    CONSTRAINT chk_mercadeo_plantillas_categoria CHECK (((categoria)::text = ANY ((ARRAY['promocion'::character varying, 'dia_especial'::character varying, 'cobro'::character varying])::text[])))
);


--
-- Name: mercadeo_plantillas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mercadeo_plantillas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mercadeo_plantillas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mercadeo_plantillas_id_seq OWNED BY public.mercadeo_plantillas.id;


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
-- Name: movimientos_inventario; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.movimientos_inventario (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    tipo character varying(20) NOT NULL,
    bodega_origen_id bigint NOT NULL,
    bodega_destino_id bigint,
    producto_id bigint NOT NULL,
    cantidad numeric(15,4) NOT NULL,
    stock_antes numeric(15,4) DEFAULT 0 NOT NULL,
    stock_despues numeric(15,4) DEFAULT 0 NOT NULL,
    documento_id bigint,
    referencia character varying(255),
    notas text,
    user_id bigint NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    precio_base numeric(15,5) DEFAULT 0 NOT NULL,
    monto_total numeric(15,5) DEFAULT 0 NOT NULL,
    proveedor_id bigint,
    CONSTRAINT movimientos_inventario_cantidad_check CHECK ((cantidad > (0)::numeric))
);


--
-- Name: movimientos_inventario_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.movimientos_inventario_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: movimientos_inventario_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.movimientos_inventario_id_seq OWNED BY public.movimientos_inventario.id;


--
-- Name: orden_pedido_consecutivos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orden_pedido_consecutivos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    ultimo_numero bigint DEFAULT 0 NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: orden_pedido_consecutivos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.orden_pedido_consecutivos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: orden_pedido_consecutivos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.orden_pedido_consecutivos_id_seq OWNED BY public.orden_pedido_consecutivos.id;


--
-- Name: ordenes_pedido; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ordenes_pedido (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    sucursal_id bigint NOT NULL,
    user_id bigint NOT NULL,
    numero character varying(20) NOT NULL,
    fecha timestamp without time zone DEFAULT now() NOT NULL,
    fecha_entrega_esperada date,
    proveedor_id bigint NOT NULL,
    bodega_id bigint NOT NULL,
    moneda character varying(3) DEFAULT 'CRC'::character varying NOT NULL,
    tipo_cambio numeric(18,5) DEFAULT 1 NOT NULL,
    lineas jsonb DEFAULT '[]'::jsonb NOT NULL,
    notas text,
    estado character varying(20) DEFAULT 'borrador'::character varying NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_orden_pedido_estado CHECK (((estado)::text = ANY ((ARRAY['borrador'::character varying, 'enviada'::character varying, 'recibida_parcial'::character varying, 'recibida_total'::character varying, 'cancelada'::character varying])::text[])))
);


--
-- Name: ordenes_pedido_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ordenes_pedido_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'ordenes_pedido'::character varying NOT NULL,
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
-- Name: ordenes_pedido_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ordenes_pedido_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ordenes_pedido_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ordenes_pedido_auditoria_id_seq OWNED BY public.ordenes_pedido_auditoria.id;


--
-- Name: ordenes_pedido_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ordenes_pedido_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ordenes_pedido_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ordenes_pedido_id_seq OWNED BY public.ordenes_pedido.id;


--
-- Name: producto_proveedor_equivalencias; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.producto_proveedor_equivalencias (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    proveedor_id bigint NOT NULL,
    codigo_proveedor character varying(100) NOT NULL,
    producto_id bigint NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: producto_proveedor_equivalencias_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.producto_proveedor_equivalencias_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: producto_proveedor_equivalencias_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.producto_proveedor_equivalencias_id_seq OWNED BY public.producto_proveedor_equivalencias.id;


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
    tax_tarifa_codigo character varying(2),
    moneda character varying(3) DEFAULT 'CRC'::character varying NOT NULL,
    codigo_barras character varying(50),
    partida_arancelaria character varying(12),
    duracion_minutos integer,
    comision_activa boolean DEFAULT false NOT NULL,
    comision_pct numeric(5,2),
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
    actividad_economica_descripcion character varying(255),
    province_code character varying(1),
    canton_code character varying(2),
    district_code character varying(2)
);


--
-- Name: proveedores_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.proveedores_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'proveedores'::character varying NOT NULL,
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
-- Name: proveedores_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.proveedores_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: proveedores_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.proveedores_auditoria_id_seq OWNED BY public.proveedores_auditoria.id;


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
-- Name: recibos_adelanto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recibos_adelanto (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    documento_id bigint NOT NULL,
    cliente_id bigint NOT NULL,
    monto_original numeric(18,5) NOT NULL,
    saldo_disponible numeric(18,5) NOT NULL,
    estado character varying(20) DEFAULT 'disponible'::character varying NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_adelanto_estado CHECK (((estado)::text = ANY ((ARRAY['disponible'::character varying, 'agotado'::character varying, 'anulado'::character varying])::text[])))
);


--
-- Name: recibos_adelanto_aplicaciones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recibos_adelanto_aplicaciones (
    id bigint NOT NULL,
    recibo_adelanto_id bigint NOT NULL,
    documento_id bigint NOT NULL,
    monto_aplicado numeric(18,5) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: recibos_adelanto_aplicaciones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.recibos_adelanto_aplicaciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recibos_adelanto_aplicaciones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.recibos_adelanto_aplicaciones_id_seq OWNED BY public.recibos_adelanto_aplicaciones.id;


--
-- Name: recibos_adelanto_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.recibos_adelanto_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recibos_adelanto_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.recibos_adelanto_id_seq OWNED BY public.recibos_adelanto.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    id integer NOT NULL,
    version character varying(20) NOT NULL,
    description text NOT NULL,
    applied_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: schema_migrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.schema_migrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: schema_migrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.schema_migrations_id_seq OWNED BY public.schema_migrations.id;


--
-- Name: servicios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.servicios (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    code character varying(50) NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    unit_measure character varying(20) DEFAULT 'Unid'::character varying NOT NULL,
    cabys_code character varying(13),
    partida_arancelaria character varying(12),
    codigo_barras character varying(50),
    price numeric(15,5) DEFAULT 0 NOT NULL,
    tax_type character varying(30) DEFAULT 'IVA'::character varying NOT NULL,
    tax_code character varying(2) DEFAULT '01'::character varying NOT NULL,
    tax_rate numeric(5,2) DEFAULT 13.00 NOT NULL,
    tax_tarifa_codigo character varying(2),
    image_url text,
    image_public_id character varying(255),
    moneda character varying(3) DEFAULT 'CRC'::character varying NOT NULL,
    duracion_minutos integer,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    comision_activa boolean DEFAULT false NOT NULL,
    comision_pct numeric(5,2)
);


--
-- Name: servicios_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.servicios_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'servicios'::character varying NOT NULL,
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
-- Name: servicios_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.servicios_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: servicios_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.servicios_auditoria_id_seq OWNED BY public.servicios_auditoria.id;


--
-- Name: servicios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.servicios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: servicios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.servicios_id_seq OWNED BY public.servicios.id;


--
-- Name: sucursal_bodegas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sucursal_bodegas (
    id bigint NOT NULL,
    sucursal_id bigint NOT NULL,
    bodega_id bigint NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: sucursal_bodegas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sucursal_bodegas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sucursal_bodegas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sucursal_bodegas_id_seq OWNED BY public.sucursal_bodegas.id;


--
-- Name: sucursal_horarios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sucursal_horarios (
    sucursal_id bigint NOT NULL,
    horario_semanal jsonb DEFAULT '[]'::jsonb NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: tipos_codigo_referencia; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tipos_codigo_referencia (
    id bigint NOT NULL,
    codigo character varying(2) NOT NULL,
    nombre character varying(200) NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    deleted_at timestamp without time zone
);


--
-- Name: tipos_codigo_referencia_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tipos_codigo_referencia_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tipos_codigo_referencia_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tipos_codigo_referencia_id_seq OWNED BY public.tipos_codigo_referencia.id;


--
-- Name: tipos_documento_referencia; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tipos_documento_referencia (
    id bigint NOT NULL,
    codigo character varying(2) NOT NULL,
    nombre character varying(200) NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    deleted_at timestamp without time zone
);


--
-- Name: tipos_documento_referencia_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tipos_documento_referencia_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tipos_documento_referencia_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tipos_documento_referencia_id_seq OWNED BY public.tipos_documento_referencia.id;


--
-- Name: agenda_avisos_envios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_avisos_envios ALTER COLUMN id SET DEFAULT nextval('public.agenda_avisos_envios_id_seq'::regclass);


--
-- Name: agenda_avisos_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_avisos_tokens ALTER COLUMN id SET DEFAULT nextval('public.agenda_avisos_tokens_id_seq'::regclass);


--
-- Name: agenda_evento_linea_productos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_evento_linea_productos ALTER COLUMN id SET DEFAULT nextval('public.agenda_evento_linea_productos_id_seq'::regclass);


--
-- Name: agenda_evento_lineas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_evento_lineas ALTER COLUMN id SET DEFAULT nextval('public.agenda_evento_lineas_id_seq'::regclass);


--
-- Name: agenda_eventos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_eventos ALTER COLUMN id SET DEFAULT nextval('public.agenda_eventos_id_seq'::regclass);


--
-- Name: agenda_eventos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_eventos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.agenda_eventos_auditoria_id_seq'::regclass);


--
-- Name: bitacora_api id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bitacora_api ALTER COLUMN id SET DEFAULT nextval('public.bitacora_api_id_seq'::regclass);


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
-- Name: caja_cierre_medios_pago id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caja_cierre_medios_pago ALTER COLUMN id SET DEFAULT nextval('public.caja_cierre_medios_pago_id_seq'::regclass);


--
-- Name: caja_cierres id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caja_cierres ALTER COLUMN id SET DEFAULT nextval('public.caja_cierres_id_seq'::regclass);


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
-- Name: cotizacion_consecutivos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cotizacion_consecutivos ALTER COLUMN id SET DEFAULT nextval('public.cotizacion_consecutivos_id_seq'::regclass);


--
-- Name: cotizaciones id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cotizaciones ALTER COLUMN id SET DEFAULT nextval('public.cotizaciones_id_seq'::regclass);


--
-- Name: cotizaciones_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cotizaciones_auditoria ALTER COLUMN id SET DEFAULT nextval('public.cotizaciones_auditoria_id_seq'::regclass);


--
-- Name: cuentas_por_cobrar id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cuentas_por_cobrar ALTER COLUMN id SET DEFAULT nextval('public.cuentas_por_cobrar_id_seq'::regclass);


--
-- Name: documento_consecutivos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_consecutivos ALTER COLUMN id SET DEFAULT nextval('public.documento_consecutivos_id_seq'::regclass);


--
-- Name: documento_cxc_aplicaciones id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_cxc_aplicaciones ALTER COLUMN id SET DEFAULT nextval('public.documento_cxc_aplicaciones_id_seq'::regclass);


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
-- Name: empresa_tarifas_impuesto id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tarifas_impuesto ALTER COLUMN id SET DEFAULT nextval('public.empresa_tarifas_impuesto_id_seq'::regclass);


--
-- Name: empresa_tipo_cambios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipo_cambios ALTER COLUMN id SET DEFAULT nextval('public.empresa_tipo_cambios_id_seq'::regclass);


--
-- Name: empresa_tipos_descuento id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_descuento ALTER COLUMN id SET DEFAULT nextval('public.empresa_tipos_descuento_id_seq'::regclass);


--
-- Name: empresa_tipos_impuesto id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_impuesto ALTER COLUMN id SET DEFAULT nextval('public.empresa_tipos_impuesto_id_seq'::regclass);


--
-- Name: facturas_recibidas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facturas_recibidas ALTER COLUMN id SET DEFAULT nextval('public.facturas_recibidas_id_seq'::regclass);


--
-- Name: funcionario_sucursales id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionario_sucursales ALTER COLUMN id SET DEFAULT nextval('public.funcionario_sucursales_id_seq'::regclass);


--
-- Name: funcionarios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionarios ALTER COLUMN id SET DEFAULT nextval('public.funcionarios_id_seq'::regclass);


--
-- Name: funcionarios_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionarios_auditoria ALTER COLUMN id SET DEFAULT nextval('public.funcionarios_auditoria_id_seq'::regclass);


--
-- Name: mercadeo_campana_envios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_campana_envios ALTER COLUMN id SET DEFAULT nextval('public.mercadeo_campana_envios_id_seq'::regclass);


--
-- Name: mercadeo_campanas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_campanas ALTER COLUMN id SET DEFAULT nextval('public.mercadeo_campanas_id_seq'::regclass);


--
-- Name: mercadeo_plantillas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_plantillas ALTER COLUMN id SET DEFAULT nextval('public.mercadeo_plantillas_id_seq'::regclass);


--
-- Name: migrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.migrations ALTER COLUMN id SET DEFAULT nextval('public.migrations_id_seq'::regclass);


--
-- Name: movimientos_inventario id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.movimientos_inventario ALTER COLUMN id SET DEFAULT nextval('public.movimientos_inventario_id_seq'::regclass);


--
-- Name: orden_pedido_consecutivos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orden_pedido_consecutivos ALTER COLUMN id SET DEFAULT nextval('public.orden_pedido_consecutivos_id_seq'::regclass);


--
-- Name: ordenes_pedido id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ordenes_pedido ALTER COLUMN id SET DEFAULT nextval('public.ordenes_pedido_id_seq'::regclass);


--
-- Name: ordenes_pedido_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ordenes_pedido_auditoria ALTER COLUMN id SET DEFAULT nextval('public.ordenes_pedido_auditoria_id_seq'::regclass);


--
-- Name: producto_proveedor_equivalencias id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.producto_proveedor_equivalencias ALTER COLUMN id SET DEFAULT nextval('public.producto_proveedor_equivalencias_id_seq'::regclass);


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
-- Name: proveedores_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proveedores_auditoria ALTER COLUMN id SET DEFAULT nextval('public.proveedores_auditoria_id_seq'::regclass);


--
-- Name: recibos_adelanto id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto ALTER COLUMN id SET DEFAULT nextval('public.recibos_adelanto_id_seq'::regclass);


--
-- Name: recibos_adelanto_aplicaciones id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto_aplicaciones ALTER COLUMN id SET DEFAULT nextval('public.recibos_adelanto_aplicaciones_id_seq'::regclass);


--
-- Name: schema_migrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations ALTER COLUMN id SET DEFAULT nextval('public.schema_migrations_id_seq'::regclass);


--
-- Name: servicios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.servicios ALTER COLUMN id SET DEFAULT nextval('public.servicios_id_seq'::regclass);


--
-- Name: servicios_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.servicios_auditoria ALTER COLUMN id SET DEFAULT nextval('public.servicios_auditoria_id_seq'::regclass);


--
-- Name: sucursal_bodegas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_bodegas ALTER COLUMN id SET DEFAULT nextval('public.sucursal_bodegas_id_seq'::regclass);


--
-- Name: tipos_codigo_referencia id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tipos_codigo_referencia ALTER COLUMN id SET DEFAULT nextval('public.tipos_codigo_referencia_id_seq'::regclass);


--
-- Name: tipos_documento_referencia id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tipos_documento_referencia ALTER COLUMN id SET DEFAULT nextval('public.tipos_documento_referencia_id_seq'::regclass);


--
-- Name: agenda_avisos_config agenda_avisos_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_avisos_config
    ADD CONSTRAINT agenda_avisos_config_pkey PRIMARY KEY (empresa_id);


--
-- Name: agenda_avisos_envios agenda_avisos_envios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_avisos_envios
    ADD CONSTRAINT agenda_avisos_envios_pkey PRIMARY KEY (id);


--
-- Name: agenda_avisos_tokens agenda_avisos_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_avisos_tokens
    ADD CONSTRAINT agenda_avisos_tokens_pkey PRIMARY KEY (id);


--
-- Name: agenda_evento_linea_productos agenda_evento_linea_productos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_evento_linea_productos
    ADD CONSTRAINT agenda_evento_linea_productos_pkey PRIMARY KEY (id);


--
-- Name: agenda_evento_lineas agenda_evento_lineas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_evento_lineas
    ADD CONSTRAINT agenda_evento_lineas_pkey PRIMARY KEY (id);


--
-- Name: agenda_eventos_auditoria agenda_eventos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_eventos_auditoria
    ADD CONSTRAINT agenda_eventos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: agenda_eventos agenda_eventos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_eventos
    ADD CONSTRAINT agenda_eventos_pkey PRIMARY KEY (id);


--
-- Name: bitacora_api bitacora_api_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bitacora_api
    ADD CONSTRAINT bitacora_api_pkey PRIMARY KEY (id);


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
-- Name: caja_cierre_medios_pago caja_cierre_medios_pago_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caja_cierre_medios_pago
    ADD CONSTRAINT caja_cierre_medios_pago_pkey PRIMARY KEY (id);


--
-- Name: caja_cierres caja_cierres_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caja_cierres
    ADD CONSTRAINT caja_cierres_pkey PRIMARY KEY (id);


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
-- Name: cotizacion_consecutivos cotizacion_consecutivos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cotizacion_consecutivos
    ADD CONSTRAINT cotizacion_consecutivos_pkey PRIMARY KEY (id);


--
-- Name: cotizaciones_auditoria cotizaciones_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cotizaciones_auditoria
    ADD CONSTRAINT cotizaciones_auditoria_pkey PRIMARY KEY (id);


--
-- Name: cotizaciones cotizaciones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cotizaciones
    ADD CONSTRAINT cotizaciones_pkey PRIMARY KEY (id);


--
-- Name: cuentas_por_cobrar cuentas_por_cobrar_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cuentas_por_cobrar
    ADD CONSTRAINT cuentas_por_cobrar_pkey PRIMARY KEY (id);


--
-- Name: documento_consecutivos documento_consecutivos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_consecutivos
    ADD CONSTRAINT documento_consecutivos_pkey PRIMARY KEY (id);


--
-- Name: documento_cxc_aplicaciones documento_cxc_aplicaciones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_cxc_aplicaciones
    ADD CONSTRAINT documento_cxc_aplicaciones_pkey PRIMARY KEY (id);


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
-- Name: empresa_tarifas_impuesto empresa_tarifas_impuesto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tarifas_impuesto
    ADD CONSTRAINT empresa_tarifas_impuesto_pkey PRIMARY KEY (id);


--
-- Name: empresa_tipo_cambios empresa_tipo_cambios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipo_cambios
    ADD CONSTRAINT empresa_tipo_cambios_pkey PRIMARY KEY (id);


--
-- Name: empresa_tipos_descuento empresa_tipos_descuento_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_descuento
    ADD CONSTRAINT empresa_tipos_descuento_pkey PRIMARY KEY (id);


--
-- Name: empresa_tipos_impuesto empresa_tipos_impuesto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_impuesto
    ADD CONSTRAINT empresa_tipos_impuesto_pkey PRIMARY KEY (id);


--
-- Name: facturas_recibidas facturas_recibidas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facturas_recibidas
    ADD CONSTRAINT facturas_recibidas_pkey PRIMARY KEY (id);


--
-- Name: funcionario_sucursales funcionario_sucursales_funcionario_id_sucursal_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionario_sucursales
    ADD CONSTRAINT funcionario_sucursales_funcionario_id_sucursal_id_key UNIQUE (funcionario_id, sucursal_id);


--
-- Name: funcionario_sucursales funcionario_sucursales_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionario_sucursales
    ADD CONSTRAINT funcionario_sucursales_pkey PRIMARY KEY (id);


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
-- Name: mercadeo_campana_envios mercadeo_campana_envios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_campana_envios
    ADD CONSTRAINT mercadeo_campana_envios_pkey PRIMARY KEY (id);


--
-- Name: mercadeo_campanas mercadeo_campanas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_campanas
    ADD CONSTRAINT mercadeo_campanas_pkey PRIMARY KEY (id);


--
-- Name: mercadeo_plantillas mercadeo_plantillas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_plantillas
    ADD CONSTRAINT mercadeo_plantillas_pkey PRIMARY KEY (id);


--
-- Name: migrations migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.migrations
    ADD CONSTRAINT migrations_pkey PRIMARY KEY (id);


--
-- Name: movimientos_inventario movimientos_inventario_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.movimientos_inventario
    ADD CONSTRAINT movimientos_inventario_pkey PRIMARY KEY (id);


--
-- Name: orden_pedido_consecutivos orden_pedido_consecutivos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orden_pedido_consecutivos
    ADD CONSTRAINT orden_pedido_consecutivos_pkey PRIMARY KEY (id);


--
-- Name: ordenes_pedido_auditoria ordenes_pedido_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ordenes_pedido_auditoria
    ADD CONSTRAINT ordenes_pedido_auditoria_pkey PRIMARY KEY (id);


--
-- Name: ordenes_pedido ordenes_pedido_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ordenes_pedido
    ADD CONSTRAINT ordenes_pedido_pkey PRIMARY KEY (id);


--
-- Name: producto_proveedor_equivalencias producto_proveedor_equivalencias_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.producto_proveedor_equivalencias
    ADD CONSTRAINT producto_proveedor_equivalencias_pkey PRIMARY KEY (id);


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
-- Name: proveedores_auditoria proveedores_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proveedores_auditoria
    ADD CONSTRAINT proveedores_auditoria_pkey PRIMARY KEY (id);


--
-- Name: proveedores proveedores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proveedores
    ADD CONSTRAINT proveedores_pkey PRIMARY KEY (id);


--
-- Name: recibos_adelanto_aplicaciones recibos_adelanto_aplicaciones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto_aplicaciones
    ADD CONSTRAINT recibos_adelanto_aplicaciones_pkey PRIMARY KEY (id);


--
-- Name: recibos_adelanto recibos_adelanto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto
    ADD CONSTRAINT recibos_adelanto_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (id);


--
-- Name: servicios_auditoria servicios_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.servicios_auditoria
    ADD CONSTRAINT servicios_auditoria_pkey PRIMARY KEY (id);


--
-- Name: servicios servicios_empresa_id_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.servicios
    ADD CONSTRAINT servicios_empresa_id_code_key UNIQUE (empresa_id, code);


--
-- Name: servicios servicios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.servicios
    ADD CONSTRAINT servicios_pkey PRIMARY KEY (id);


--
-- Name: sucursal_bodegas sucursal_bodegas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_bodegas
    ADD CONSTRAINT sucursal_bodegas_pkey PRIMARY KEY (id);


--
-- Name: sucursal_horarios sucursal_horarios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_horarios
    ADD CONSTRAINT sucursal_horarios_pkey PRIMARY KEY (sucursal_id);


--
-- Name: tipos_codigo_referencia tipos_codigo_referencia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tipos_codigo_referencia
    ADD CONSTRAINT tipos_codigo_referencia_pkey PRIMARY KEY (id);


--
-- Name: tipos_documento_referencia tipos_documento_referencia_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tipos_documento_referencia
    ADD CONSTRAINT tipos_documento_referencia_pkey PRIMARY KEY (id);


--
-- Name: agenda_avisos_envios uq_agenda_avisos_envios; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_avisos_envios
    ADD CONSTRAINT uq_agenda_avisos_envios UNIQUE (evento_id, tipo);


--
-- Name: agenda_avisos_tokens uq_agenda_avisos_tokens_token; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_avisos_tokens
    ADD CONSTRAINT uq_agenda_avisos_tokens_token UNIQUE (token);


--
-- Name: documento_consecutivos uq_consecutivo; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_consecutivos
    ADD CONSTRAINT uq_consecutivo UNIQUE (empresa_id, sucursal_id, terminal, tipo_documento);


--
-- Name: cotizacion_consecutivos uq_cotizacion_consecutivo; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cotizacion_consecutivos
    ADD CONSTRAINT uq_cotizacion_consecutivo UNIQUE (empresa_id);


--
-- Name: empresa_tipo_cambios uq_emp_tipo_cambio; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipo_cambios
    ADD CONSTRAINT uq_emp_tipo_cambio UNIQUE (empresa_id, fecha);


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
-- Name: orden_pedido_consecutivos uq_orden_pedido_consecutivo; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orden_pedido_consecutivos
    ADD CONSTRAINT uq_orden_pedido_consecutivo UNIQUE (empresa_id);


--
-- Name: producto_proveedor_equivalencias uq_producto_proveedor_equiv; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.producto_proveedor_equivalencias
    ADD CONSTRAINT uq_producto_proveedor_equiv UNIQUE (empresa_id, proveedor_id, codigo_proveedor);


--
-- Name: sucursal_bodegas uq_sucursal_bodega; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_bodegas
    ADD CONSTRAINT uq_sucursal_bodega UNIQUE (sucursal_id, bodega_id);


--
-- Name: clients_central_client_id_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX clients_central_client_id_uidx ON public.clients USING btree (central_client_id) WHERE (central_client_id IS NOT NULL);


--
-- Name: idx_adelanto_aplic_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_adelanto_aplic_documento ON public.recibos_adelanto_aplicaciones USING btree (documento_id);


--
-- Name: idx_adelanto_aplic_recibo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_adelanto_aplic_recibo ON public.recibos_adelanto_aplicaciones USING btree (recibo_adelanto_id);


--
-- Name: idx_adelanto_cliente; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_adelanto_cliente ON public.recibos_adelanto USING btree (cliente_id, estado);


--
-- Name: idx_adelanto_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_adelanto_documento ON public.recibos_adelanto USING btree (documento_id);


--
-- Name: idx_agenda_avisos_envios_evento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_avisos_envios_evento ON public.agenda_avisos_envios USING btree (evento_id);


--
-- Name: idx_agenda_avisos_tokens_evento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_avisos_tokens_evento ON public.agenda_avisos_tokens USING btree (evento_id);


--
-- Name: idx_agenda_evento_linea_productos_linea; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_evento_linea_productos_linea ON public.agenda_evento_linea_productos USING btree (linea_id);


--
-- Name: idx_agenda_evento_lineas_evento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_evento_lineas_evento ON public.agenda_evento_lineas USING btree (evento_id);


--
-- Name: idx_agenda_evento_lineas_fechas; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_evento_lineas_fechas ON public.agenda_evento_lineas USING btree (fecha_inicio, fecha_fin);


--
-- Name: idx_agenda_evento_lineas_funcionario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_evento_lineas_funcionario ON public.agenda_evento_lineas USING btree (funcionario_id);


--
-- Name: idx_agenda_eventos_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_eventos_documento ON public.agenda_eventos USING btree (documento_id);


--
-- Name: idx_agenda_eventos_empresa_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_eventos_empresa_fecha ON public.agenda_eventos USING btree (empresa_id, fecha_inicio);


--
-- Name: idx_bitacora_api_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bitacora_api_created ON public.bitacora_api USING btree (created_at DESC);


--
-- Name: idx_bitacora_api_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bitacora_api_empresa ON public.bitacora_api USING btree (empresa_id);


--
-- Name: idx_bitacora_api_endpoint; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bitacora_api_endpoint ON public.bitacora_api USING btree (endpoint);


--
-- Name: idx_bitacora_api_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bitacora_api_user ON public.bitacora_api USING btree (user_id);


--
-- Name: idx_bitacora_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bitacora_created_at ON public.bitacora_api USING btree (created_at DESC);


--
-- Name: idx_bitacora_empresa_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bitacora_empresa_id ON public.bitacora_api USING btree (empresa_id);


--
-- Name: idx_bitacora_endpoint; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bitacora_endpoint ON public.bitacora_api USING btree (endpoint);


--
-- Name: idx_bitacora_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bitacora_user_id ON public.bitacora_api USING btree (user_id);


--
-- Name: idx_caja_cierre_medios; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_caja_cierre_medios ON public.caja_cierre_medios_pago USING btree (cierre_id);


--
-- Name: idx_caja_cierres_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_caja_cierres_empresa ON public.caja_cierres USING btree (empresa_id, caja_id);


--
-- Name: idx_cotizaciones_empresa_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cotizaciones_empresa_estado ON public.cotizaciones USING btree (empresa_id, estado);


--
-- Name: idx_cotizaciones_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cotizaciones_fecha ON public.cotizaciones USING btree (empresa_id, fecha_emision DESC);


--
-- Name: idx_cxc_aplic_cxc; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cxc_aplic_cxc ON public.documento_cxc_aplicaciones USING btree (cuenta_por_cobrar_id);


--
-- Name: idx_cxc_aplic_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cxc_aplic_documento ON public.documento_cxc_aplicaciones USING btree (documento_id);


--
-- Name: idx_cxc_cliente; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cxc_cliente ON public.cuentas_por_cobrar USING btree (cliente_id, estado);


--
-- Name: idx_cxc_cliente_origen; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cxc_cliente_origen ON public.cuentas_por_cobrar USING btree (cliente_id, origen_venta, estado);


--
-- Name: idx_cxc_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_cxc_documento ON public.cuentas_por_cobrar USING btree (documento_id);


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
-- Name: idx_funcionario_sucursales_funcionario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_funcionario_sucursales_funcionario ON public.funcionario_sucursales USING btree (funcionario_id);


--
-- Name: idx_mercadeo_campana_envios_campana; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mercadeo_campana_envios_campana ON public.mercadeo_campana_envios USING btree (campana_id);


--
-- Name: idx_mercadeo_campanas_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mercadeo_campanas_empresa ON public.mercadeo_campanas USING btree (empresa_id);


--
-- Name: idx_mercadeo_plantillas_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mercadeo_plantillas_empresa ON public.mercadeo_plantillas USING btree (empresa_id);


--
-- Name: idx_mov_inv_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_inv_created ON public.movimientos_inventario USING btree (created_at DESC);


--
-- Name: idx_mov_inv_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_inv_empresa ON public.movimientos_inventario USING btree (empresa_id);


--
-- Name: idx_mov_inv_producto; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_inv_producto ON public.movimientos_inventario USING btree (producto_id, bodega_origen_id);


--
-- Name: idx_ordenes_pedido_empresa_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ordenes_pedido_empresa_estado ON public.ordenes_pedido USING btree (empresa_id, estado);


--
-- Name: idx_ordenes_pedido_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ordenes_pedido_fecha ON public.ordenes_pedido USING btree (empresa_id, fecha DESC);


--
-- Name: idx_productos_codigo_barras; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_productos_codigo_barras ON public.productos USING btree (empresa_id, codigo_barras) WHERE (codigo_barras IS NOT NULL);


--
-- Name: idx_proveedores_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_proveedores_auditoria_registro ON public.proveedores_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_proveedores_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_proveedores_empresa ON public.proveedores USING btree (empresa_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_proveedores_tax_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_proveedores_tax_id ON public.proveedores USING btree (tax_id) WHERE (deleted_at IS NULL);


--
-- Name: uq_emp_tarifa_imp_empresa_codigo; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_emp_tarifa_imp_empresa_codigo ON public.empresa_tarifas_impuesto USING btree (empresa_id, codigo) WHERE (deleted_at IS NULL);


--
-- Name: uq_emp_tipo_desc_empresa_codigo; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_emp_tipo_desc_empresa_codigo ON public.empresa_tipos_descuento USING btree (empresa_id, codigo) WHERE (deleted_at IS NULL);


--
-- Name: uq_emp_tipo_imp_empresa_codigo; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_emp_tipo_imp_empresa_codigo ON public.empresa_tipos_impuesto USING btree (empresa_id, codigo) WHERE (deleted_at IS NULL);


--
-- Name: uq_fr_clave; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_fr_clave ON public.facturas_recibidas USING btree (empresa_id, clave) WHERE (clave IS NOT NULL);


--
-- Name: agenda_eventos trg_agenda_eventos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_agenda_eventos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.agenda_eventos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


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
-- Name: cotizaciones trg_cotizaciones_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_cotizaciones_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.cotizaciones FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: documentos_electronicos trg_documentos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_documentos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.documentos_electronicos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: funcionarios trg_funcionarios_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_funcionarios_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.funcionarios FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: ordenes_pedido trg_ordenes_pedido_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ordenes_pedido_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.ordenes_pedido FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: productos trg_productos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_productos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.productos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: proveedores trg_proveedores_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_proveedores_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.proveedores FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: servicios trg_servicios_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_servicios_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.servicios FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


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
-- Name: caja_cierre_medios_pago caja_cierre_medios_pago_cierre_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caja_cierre_medios_pago
    ADD CONSTRAINT caja_cierre_medios_pago_cierre_id_fkey FOREIGN KEY (cierre_id) REFERENCES public.caja_cierres(id) ON DELETE CASCADE;


--
-- Name: cuentas_por_cobrar cuentas_por_cobrar_cliente_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cuentas_por_cobrar
    ADD CONSTRAINT cuentas_por_cobrar_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES public.clients(id);


--
-- Name: cuentas_por_cobrar cuentas_por_cobrar_documento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cuentas_por_cobrar
    ADD CONSTRAINT cuentas_por_cobrar_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos_electronicos(id);


--
-- Name: documento_cxc_aplicaciones documento_cxc_aplicaciones_cuenta_por_cobrar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_cxc_aplicaciones
    ADD CONSTRAINT documento_cxc_aplicaciones_cuenta_por_cobrar_id_fkey FOREIGN KEY (cuenta_por_cobrar_id) REFERENCES public.cuentas_por_cobrar(id);


--
-- Name: documento_cxc_aplicaciones documento_cxc_aplicaciones_documento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_cxc_aplicaciones
    ADD CONSTRAINT documento_cxc_aplicaciones_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos_electronicos(id);


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
-- Name: facturas_recibidas facturas_recibidas_factura_referencia_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facturas_recibidas
    ADD CONSTRAINT facturas_recibidas_factura_referencia_id_fkey FOREIGN KEY (factura_referencia_id) REFERENCES public.facturas_recibidas(id);


--
-- Name: funcionario_sucursales funcionario_sucursales_funcionario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionario_sucursales
    ADD CONSTRAINT funcionario_sucursales_funcionario_id_fkey FOREIGN KEY (funcionario_id) REFERENCES public.funcionarios(id) ON DELETE CASCADE;


--
-- Name: mercadeo_campana_envios mercadeo_campana_envios_campana_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_campana_envios
    ADD CONSTRAINT mercadeo_campana_envios_campana_id_fkey FOREIGN KEY (campana_id) REFERENCES public.mercadeo_campanas(id);


--
-- Name: mercadeo_campanas mercadeo_campanas_plantilla_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_campanas
    ADD CONSTRAINT mercadeo_campanas_plantilla_id_fkey FOREIGN KEY (plantilla_id) REFERENCES public.mercadeo_plantillas(id);


--
-- Name: movimientos_inventario movimientos_inventario_bodega_destino_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.movimientos_inventario
    ADD CONSTRAINT movimientos_inventario_bodega_destino_id_fkey FOREIGN KEY (bodega_destino_id) REFERENCES public.bodegas(id);


--
-- Name: movimientos_inventario movimientos_inventario_bodega_origen_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.movimientos_inventario
    ADD CONSTRAINT movimientos_inventario_bodega_origen_id_fkey FOREIGN KEY (bodega_origen_id) REFERENCES public.bodegas(id);


--
-- Name: movimientos_inventario movimientos_inventario_documento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.movimientos_inventario
    ADD CONSTRAINT movimientos_inventario_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos_electronicos(id);


--
-- Name: movimientos_inventario movimientos_inventario_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.movimientos_inventario
    ADD CONSTRAINT movimientos_inventario_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);


--
-- Name: movimientos_inventario movimientos_inventario_proveedor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.movimientos_inventario
    ADD CONSTRAINT movimientos_inventario_proveedor_id_fkey FOREIGN KEY (proveedor_id) REFERENCES public.proveedores(id);


--
-- Name: productos productos_categoria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_categoria_id_fkey FOREIGN KEY (categoria_id) REFERENCES public.categorias_producto(id);


--
-- Name: recibos_adelanto_aplicaciones recibos_adelanto_aplicaciones_documento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto_aplicaciones
    ADD CONSTRAINT recibos_adelanto_aplicaciones_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos_electronicos(id);


--
-- Name: recibos_adelanto_aplicaciones recibos_adelanto_aplicaciones_recibo_adelanto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto_aplicaciones
    ADD CONSTRAINT recibos_adelanto_aplicaciones_recibo_adelanto_id_fkey FOREIGN KEY (recibo_adelanto_id) REFERENCES public.recibos_adelanto(id);


--
-- Name: recibos_adelanto recibos_adelanto_cliente_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto
    ADD CONSTRAINT recibos_adelanto_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES public.clients(id);


--
-- Name: recibos_adelanto recibos_adelanto_documento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto
    ADD CONSTRAINT recibos_adelanto_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos_electronicos(id);


--
-- Name: sucursal_bodegas sucursal_bodegas_bodega_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_bodegas
    ADD CONSTRAINT sucursal_bodegas_bodega_id_fkey FOREIGN KEY (bodega_id) REFERENCES public.bodegas(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

