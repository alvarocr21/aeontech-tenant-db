--
-- PostgreSQL database dump
--

\restrict TVrCVA9biMVdIffWRLnMiN4dXxDvkKcU4LAmvSzwb5jYSwYoxnx6X6EJbCBV7D6

-- Dumped from database version 16.14 (Ubuntu 16.14-1.pgdg22.04+1)
-- Dumped by pg_dump version 16.14 (Ubuntu 16.14-1.pgdg22.04+1)

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

-- *not* creating schema, since initdb creates it


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: unaccent; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;


--
-- Name: EXTENSION unaccent; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION unaccent IS 'text search dictionary that removes accents';


--
-- Name: fn_agenda_evento_recalcular(bigint, bigint, text, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_agenda_evento_recalcular(p_evento_id bigint, p_documento_id bigint DEFAULT NULL::bigint, p_motivo text DEFAULT NULL::text, p_user_id bigint DEFAULT NULL::bigint, p_user_nombre character varying DEFAULT NULL::character varying) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    DECLARE
        v_pend   INTEGER;
        v_fact   INTEGER;
        v_doc    BIGINT;
        v_estado VARCHAR;
    BEGIN
        SELECT estado INTO v_estado FROM agenda_eventos WHERE id = p_evento_id;

        SELECT COUNT(*) FILTER (WHERE fn_agenda_linea_estado(l.estado, l.documento_id) = 'pendiente'),
               COUNT(*) FILTER (WHERE fn_agenda_linea_estado(l.estado, l.documento_id) = 'facturado'),
               MAX(l.documento_id) FILTER (WHERE fn_agenda_linea_estado(l.estado, l.documento_id) = 'facturado')
          INTO v_pend, v_fact, v_doc
          FROM agenda_evento_lineas l WHERE l.evento_id = p_evento_id;

        IF v_pend > 0 THEN
            RETURN;
        END IF;

        IF v_fact > 0 THEN
            UPDATE agenda_eventos SET
                estado = 'completado',
                documento_id = COALESCE(p_documento_id, v_doc),
                updated_at = NOW()
            WHERE id = p_evento_id;
        ELSIF v_estado <> 'cancelado' THEN
            UPDATE agenda_eventos SET
                estado = 'cancelado',
                motivo_cancelacion = p_motivo,
                cancelado_at = NOW(),
                cancelado_por = p_user_id,
                cancelado_por_nombre = p_user_nombre,
                updated_at = NOW()
            WHERE id = p_evento_id;
        END IF;
    END;
    $$;


--
-- Name: fn_agenda_linea_estado(character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_agenda_linea_estado(p_estado character varying, p_documento_id bigint) RETURNS character varying
    LANGUAGE sql STABLE
    AS $$
        SELECT CASE
            WHEN p_estado = 'facturado'
             AND EXISTS (SELECT 1 FROM documentos_electronicos d WHERE d.id = p_documento_id AND d.estado = 'rechazado')
            THEN 'pendiente'
            ELSE p_estado
        END;
    $$;


--
-- Name: fn_auditoria_generica(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_auditoria_generica() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
    v_datos_antes JSONB := NULL;
    v_datos_despues JSONB := NULL;
    v_tabla_auditoria TEXT;
    v_excluidas TEXT[] := COALESCE(TG_ARGV, ARRAY[]::TEXT[]);
BEGIN
    v_tabla_auditoria := TG_TABLE_NAME || '_auditoria';

    IF TG_OP = 'DELETE' THEN
        v_datos_antes := to_jsonb(OLD) - v_excluidas;
    ELSIF TG_OP = 'UPDATE' THEN
        v_datos_antes   := to_jsonb(OLD) - v_excluidas;
        v_datos_despues := to_jsonb(NEW) - v_excluidas;
    ELSE
        v_datos_despues := to_jsonb(NEW) - v_excluidas;
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
-- Name: fn_rrhh_dias_habiles(bigint, bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_dias_habiles(p_empresa_id bigint, p_empleado_id bigint, p_desde date, p_hasta date) RETURNS integer
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_horas NUMERIC;
    v_n     INTEGER;
BEGIN
    IF p_hasta < p_desde THEN RETURN 0; END IF;
    IF p_hasta - p_desde > 400 THEN RAISE EXCEPTION 'FECHA_INVALIDA: El rango de fechas es demasiado grande.'; END IF;
    SELECT e.horas_semanales INTO v_horas FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id;

    SELECT COUNT(*)::INTEGER INTO v_n
      FROM generate_series(p_desde::TIMESTAMP, p_hasta::TIMESTAMP, INTERVAL '1 day') gs
      CROSS JOIN LATERAL (SELECT gs::DATE AS dia, EXTRACT(ISODOW FROM gs)::INTEGER AS dow) x
      LEFT JOIN LATERAL (
          SELECT a.horario_id FROM rrhh_empleado_horarios a
           WHERE a.empleado_id = p_empleado_id AND a.deleted_at IS NULL AND a.vigente_desde <= x.dia
             AND (a.vigente_hasta IS NULL OR a.vigente_hasta >= x.dia)
           ORDER BY a.vigente_desde DESC LIMIT 1) h ON TRUE
     WHERE NOT EXISTS (SELECT 1 FROM rrhh_feriados f WHERE f.empresa_id = p_empresa_id AND f.fecha = x.dia
                          AND f.pago_obligatorio AND f.deleted_at IS NULL)
       AND (CASE WHEN h.horario_id IS NOT NULL
                 THEN EXISTS (SELECT 1 FROM rrhh_horario_dias d WHERE d.horario_id = h.horario_id AND d.dia_semana = x.dow)
                 ELSE x.dow <= (CASE WHEN COALESCE(v_horas, 48) > 40 THEN 6 ELSE 5 END) END);
    RETURN v_n;
END; $$;


--
-- Name: fn_rrhh_horario_guardar_dias(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_horario_guardar_dias(p_horario_id bigint, p_dias jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    DELETE FROM rrhh_horario_dias WHERE horario_id = p_horario_id;
    INSERT INTO rrhh_horario_dias (horario_id, dia_semana, hora_entrada, hora_salida, minutos_descanso)
    SELECT p_horario_id, (x->>'dia_semana')::SMALLINT, (x->>'hora_entrada')::TIME, (x->>'hora_salida')::TIME,
           COALESCE((x->>'minutos_descanso')::SMALLINT, 0)
      FROM jsonb_array_elements(p_dias) x;
END; $$;


--
-- Name: fn_rrhh_inc_dias_previos(bigint, character varying, date, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_inc_dias_previos(p_empleado_id bigint, p_tipo character varying, p_inicio date, p_excluir_id bigint) RETURNS integer
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_cursor DATE := p_inicio;
    v_total  INTEGER := 0;
    v_r      RECORD;
BEGIN
    LOOP
        SELECT i.fecha_inicio, i.fecha_fin INTO v_r FROM rrhh_incapacidades i
         WHERE i.empleado_id = p_empleado_id AND i.tipo = p_tipo AND i.estado = 'registrada' AND i.deleted_at IS NULL
           AND i.id <> COALESCE(p_excluir_id, 0) AND i.fecha_fin = v_cursor - 1
         LIMIT 1;
        EXIT WHEN NOT FOUND;
        v_total := v_total + (v_r.fecha_fin - v_r.fecha_inicio + 1);
        v_cursor := v_r.fecha_inicio;
        EXIT WHEN v_total > 3650;
    END LOOP;
    RETURN v_total;
END; $$;


--
-- Name: fn_rrhh_inc_tramos(bigint, character varying, date, date, numeric, boolean, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_inc_tramos(p_empleado_id bigint, p_tipo character varying, p_inicio date, p_fin date, p_valor_dia numeric, p_completa boolean, p_excluir_id bigint) RETURNS TABLE(desde date, hasta date, dias integer, patrono_pct numeric, entidad_pct numeric, complemento_pct numeric, monto_patrono numeric, monto_entidad numeric, monto_complemento numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    WITH prev AS (
        SELECT fn_rrhh_inc_dias_previos(p_empleado_id, p_tipo, p_inicio, p_excluir_id) AS p
    ),
    d AS (
        SELECT gs::DATE AS dia, prev.p + (gs::DATE - p_inicio) + 1 AS n
          FROM prev, generate_series(p_inicio::TIMESTAMP, p_fin::TIMESTAMP, INTERVAL '1 day') gs
    ),
    q AS (
        SELECT d.dia,
               (CASE WHEN p_tipo = 'maternidad' THEN 50 WHEN d.n <= 3 THEN 50 ELSE 0 END)::NUMERIC AS pat,
               (CASE WHEN p_tipo = 'maternidad' THEN 50 WHEN d.n <= 3 THEN 0 ELSE 60 END)::NUMERIC AS ent
          FROM d
    ),
    r AS (
        SELECT q.dia, q.pat, q.ent, (CASE WHEN p_completa THEN 100 - q.pat - q.ent ELSE 0 END)::NUMERIC AS comp FROM q
    )
    SELECT MIN(r.dia), MAX(r.dia), COUNT(*)::INTEGER, r.pat, r.ent, r.comp,
           round(COUNT(*) * p_valor_dia * r.pat / 100, 2),
           round(COUNT(*) * p_valor_dia * r.ent / 100, 2),
           round(COUNT(*) * p_valor_dia * r.comp / 100, 2)
      FROM r GROUP BY r.pat, r.ent, r.comp ORDER BY MIN(r.dia);
$$;


--
-- Name: fn_rrhh_inc_vac_traslape(bigint, bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_inc_vac_traslape(p_empresa_id bigint, p_empleado_id bigint, p_inicio date, p_fin date) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT COALESCE(SUM(fn_rrhh_dias_habiles(p_empresa_id, p_empleado_id, GREATEST(s.fecha_inicio, p_inicio), LEAST(s.fecha_fin, p_fin))), 0)::NUMERIC
      FROM rrhh_vacaciones_solicitudes s
     WHERE s.empleado_id = p_empleado_id AND s.deleted_at IS NULL AND s.estado = 'aprobada'
       AND s.fecha_inicio <= p_fin AND s.fecha_fin >= p_inicio;
$$;


--
-- Name: fn_rrhh_inc_validar(bigint, bigint, character varying, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_inc_validar(p_empresa_id bigint, p_empleado_id bigint, p_tipo character varying, p_inicio date, p_fin date) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_e RECORD;
BEGIN
    SELECT e.fecha_ingreso, e.fecha_salida, e.estado INTO v_e
      FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.'; END IF;
    IF v_e.estado = 'liquidado' THEN RAISE EXCEPTION 'INCAPACIDAD_INVALIDA: El empleado ya fue liquidado.'; END IF;
    IF p_tipo IS NULL OR p_tipo NOT IN ('enfermedad', 'maternidad', 'riesgo_trabajo') THEN
        RAISE EXCEPTION 'INCAPACIDAD_INVALIDA: Tipo de incapacidad desconocido.';
    END IF;
    IF p_inicio IS NULL OR p_fin IS NULL THEN RAISE EXCEPTION 'FECHA_INVALIDA: Indique las fechas de la incapacidad.'; END IF;
    IF p_fin < p_inicio THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha final es anterior a la inicial.'; END IF;
    IF p_fin - p_inicio > 730 THEN RAISE EXCEPTION 'INCAPACIDAD_INVALIDA: Una incapacidad no puede pasar de 731 días; divídala en prórrogas.'; END IF;
    IF p_inicio < v_e.fecha_ingreso THEN RAISE EXCEPTION 'INCAPACIDAD_INVALIDA: La incapacidad es anterior a la fecha de ingreso del empleado.'; END IF;
    IF v_e.fecha_salida IS NOT NULL AND p_inicio > v_e.fecha_salida THEN
        RAISE EXCEPTION 'INCAPACIDAD_INVALIDA: La incapacidad empieza después de la fecha de salida del empleado.';
    END IF;
    IF EXISTS (SELECT 1 FROM rrhh_incapacidades i WHERE i.empleado_id = p_empleado_id AND i.deleted_at IS NULL AND i.estado = 'registrada'
                  AND i.fecha_inicio <= p_fin AND i.fecha_fin >= p_inicio) THEN
        RAISE EXCEPTION 'INCAPACIDAD_INVALIDA: El empleado ya tiene una incapacidad registrada que se cruza con esas fechas.';
    END IF;
    IF EXISTS (SELECT 1 FROM rrhh_permiso_solicitudes s WHERE s.empleado_id = p_empleado_id AND s.deleted_at IS NULL
                  AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada') AND s.fecha_inicio <= p_fin AND s.fecha_fin >= p_inicio) THEN
        RAISE EXCEPTION 'INCAPACIDAD_INVALIDA: El empleado tiene un permiso pedido o aprobado que se cruza con esas fechas; cancélelo primero.';
    END IF;
END; $$;


--
-- Name: fn_rrhh_inc_valor_dia(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_inc_valor_dia(p_empleado_id bigint) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT round(e.salario_base / (CASE e.periodo_pago WHEN 'mensual' THEN 30 WHEN 'quincenal' THEN 15 ELSE 7 END), 2)
      FROM rrhh_empleados e WHERE e.id = p_empleado_id;
$$;


--
-- Name: fn_rrhh_minutos_dia(time without time zone, time without time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_minutos_dia(p_entrada time without time zone, p_salida time without time zone, p_descanso integer) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT (EXTRACT(EPOCH FROM (CASE WHEN p_salida > p_entrada THEN p_salida - p_entrada
                                     ELSE p_salida - p_entrada + INTERVAL '24 hours' END)) / 60)::INTEGER - COALESCE(p_descanso, 0);
$$;


--
-- Name: fn_rrhh_movimiento(bigint, bigint, character varying, text, jsonb, jsonb, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_movimiento(p_empresa_id bigint, p_empleado_id bigint, p_tipo character varying, p_descripcion text, p_anterior jsonb DEFAULT NULL::jsonb, p_nuevo jsonb DEFAULT NULL::jsonb, p_fecha date DEFAULT CURRENT_DATE) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    INSERT INTO rrhh_empleado_movimientos (empresa_id, empleado_id, tipo, fecha, descripcion, valor_anterior, valor_nuevo, usuario_id)
    VALUES (p_empresa_id, p_empleado_id, p_tipo, p_fecha, p_descripcion, p_anterior, p_nuevo,
            NULLIF(current_setting('app.current_user_id', true), '')::BIGINT);
END; $$;


--
-- Name: fn_rrhh_permiso_validar(bigint, bigint, bigint, date, date, time without time zone, time without time zone, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_permiso_validar(p_empresa_id bigint, p_empleado_id bigint, p_tipo_id bigint, p_inicio date, p_fin date, p_hi time without time zone, p_hf time without time zone, p_excluir_id bigint) RETURNS numeric
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_e     RECORD;
    v_t     RECORD;
    v_cant  NUMERIC;
    v_usado NUMERIC;
BEGIN
    SELECT e.fecha_ingreso, e.fecha_salida, e.estado INTO v_e
      FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.'; END IF;
    IF v_e.estado <> 'activo' THEN RAISE EXCEPTION 'PERMISO_INVALIDO: Solo los empleados activos pueden pedir permisos.'; END IF;

    SELECT t.* INTO v_t FROM rrhh_permiso_tipos t WHERE t.id = p_tipo_id AND t.empresa_id = p_empresa_id AND t.deleted_at IS NULL;
    IF NOT FOUND OR NOT v_t.is_active THEN RAISE EXCEPTION 'PERMISO_INVALIDO: El tipo de permiso no existe o está inactivo.'; END IF;

    IF p_fin < p_inicio THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha final es anterior a la inicial.'; END IF;
    IF p_fin - p_inicio > 60 THEN RAISE EXCEPTION 'PERMISO_INVALIDO: Un permiso no puede pasar de 60 días; divídalo en dos.'; END IF;
    IF p_inicio < v_e.fecha_ingreso THEN RAISE EXCEPTION 'PERMISO_INVALIDO: El permiso es anterior a la fecha de ingreso del empleado.'; END IF;
    IF v_e.fecha_salida IS NOT NULL AND p_fin > v_e.fecha_salida THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: Las fechas pasan de la fecha de salida del empleado.';
    END IF;

    IF v_t.unidad = 'horas' THEN
        IF p_inicio <> p_fin THEN RAISE EXCEPTION 'PERMISO_INVALIDO: Un permiso por horas se pide para un solo día.'; END IF;
        IF p_hi IS NULL OR p_hf IS NULL OR p_hf <= p_hi THEN
            RAISE EXCEPTION 'PERMISO_INVALIDO: Indique la hora de inicio y la de fin (la final debe ser posterior a la inicial).';
        END IF;
        v_cant := round(EXTRACT(EPOCH FROM (p_hf - p_hi)) / 3600.0, 2);
    ELSE
        v_cant := fn_rrhh_dias_habiles(p_empresa_id, p_empleado_id, p_inicio, p_fin);
        IF v_cant = 0 THEN RAISE EXCEPTION 'PERMISO_INVALIDO: El rango no incluye días laborales (los descansos y feriados no cuentan).'; END IF;
    END IF;

    IF v_t.max_por_solicitud IS NOT NULL AND v_cant > v_t.max_por_solicitud THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: «%» permite como máximo % % por solicitud y se piden %.',
            v_t.nombre, trim(trailing '.' FROM trim(trailing '0' FROM v_t.max_por_solicitud::TEXT)), CASE v_t.unidad WHEN 'horas' THEN 'hora(s)' ELSE 'día(s)' END,
            trim(trailing '.' FROM trim(trailing '0' FROM v_cant::TEXT));
    END IF;
    IF v_t.max_por_anio IS NOT NULL THEN
        SELECT COALESCE(SUM(s.cantidad), 0) INTO v_usado FROM rrhh_permiso_solicitudes s
         WHERE s.empleado_id = p_empleado_id AND s.tipo_id = p_tipo_id AND s.deleted_at IS NULL AND s.id <> COALESCE(p_excluir_id, 0)
           AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada')
           AND EXTRACT(YEAR FROM s.fecha_inicio) = EXTRACT(YEAR FROM p_inicio);
        IF v_usado + v_cant > v_t.max_por_anio THEN
            RAISE EXCEPTION 'PERMISO_INVALIDO: «%» permite % % por año y el empleado ya tiene % entre aprobados y pendientes.',
                v_t.nombre, trim(trailing '.' FROM trim(trailing '0' FROM v_t.max_por_anio::TEXT)), CASE v_t.unidad WHEN 'horas' THEN 'hora(s)' ELSE 'día(s)' END,
                trim(trailing '.' FROM trim(trailing '0' FROM v_usado::TEXT));
        END IF;
    END IF;

    IF EXISTS (SELECT 1 FROM rrhh_vacaciones_solicitudes s
                WHERE s.empleado_id = p_empleado_id AND s.deleted_at IS NULL AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada')
                  AND s.fecha_inicio <= p_fin AND s.fecha_fin >= p_inicio) THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: El empleado tiene vacaciones que se cruzan con esas fechas.';
    END IF;
    IF EXISTS (SELECT 1 FROM rrhh_incapacidades i
                WHERE i.empleado_id = p_empleado_id AND i.deleted_at IS NULL AND i.estado = 'registrada'
                  AND i.fecha_inicio <= p_fin AND i.fecha_fin >= p_inicio) THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: El empleado tiene una incapacidad registrada que se cruza con esas fechas.';
    END IF;
    IF EXISTS (SELECT 1 FROM rrhh_permiso_solicitudes s
                WHERE s.empleado_id = p_empleado_id AND s.deleted_at IS NULL AND s.id <> COALESCE(p_excluir_id, 0)
                  AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada')
                  AND s.fecha_inicio <= p_fin AND s.fecha_fin >= p_inicio
                  AND (v_t.unidad = 'dias' OR s.unidad = 'dias' OR (s.hora_inicio < p_hf AND s.hora_fin > p_hi))) THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: El empleado ya tiene otro permiso, pedido o aprobado, que se cruza con esas fechas u horas.';
    END IF;
    RETURN v_cant;
END; $$;


--
-- Name: fn_rrhh_sesiones(bigint, bigint, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_sesiones(p_empresa_id bigint, p_empleado_id bigint, p_desde timestamp without time zone, p_hasta timestamp without time zone) RETURNS TABLE(s_empleado_id bigint, s_entrada_id bigint, s_entrada timestamp without time zone, s_salida_id bigint, s_salida timestamp without time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    r        RECORD;
    v_emp    BIGINT := NULL;
    v_ent_id BIGINT := NULL;
    v_ent    TIMESTAMP := NULL;
BEGIN
    FOR r IN
        SELECT m.id, m.empleado_id AS emp, m.fecha_hora
          FROM rrhh_marcas m
         WHERE m.empresa_id = p_empresa_id AND m.estado = 'valida' AND m.deleted_at IS NULL AND m.empleado_id IS NOT NULL
           AND (p_empleado_id IS NULL OR m.empleado_id = p_empleado_id)
           AND m.fecha_hora BETWEEN p_desde AND p_hasta
         ORDER BY m.empleado_id, m.fecha_hora, m.id
    LOOP
        IF v_emp IS DISTINCT FROM r.emp THEN
            IF v_ent_id IS NOT NULL THEN
                s_empleado_id := v_emp; s_entrada_id := v_ent_id; s_entrada := v_ent; s_salida_id := NULL; s_salida := NULL;
                RETURN NEXT;
            END IF;
            v_emp := r.emp; v_ent_id := NULL; v_ent := NULL;
        END IF;

        IF v_ent_id IS NULL THEN
            v_ent_id := r.id; v_ent := r.fecha_hora;
        ELSIF r.fecha_hora - v_ent <= INTERVAL '14 hours' THEN
            s_empleado_id := v_emp; s_entrada_id := v_ent_id; s_entrada := v_ent; s_salida_id := r.id; s_salida := r.fecha_hora;
            RETURN NEXT;
            v_ent_id := NULL; v_ent := NULL;
        ELSE
            s_empleado_id := v_emp; s_entrada_id := v_ent_id; s_entrada := v_ent; s_salida_id := NULL; s_salida := NULL;
            RETURN NEXT;
            v_ent_id := r.id; v_ent := r.fecha_hora;
        END IF;
    END LOOP;

    IF v_ent_id IS NOT NULL THEN
        s_empleado_id := v_emp; s_entrada_id := v_ent_id; s_entrada := v_ent; s_salida_id := NULL; s_salida := NULL;
        RETURN NEXT;
    END IF;
END; $$;


--
-- Name: fn_rrhh_vac_devengado(bigint, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_vac_devengado(p_empleado_id bigint, p_fecha date) RETURNS numeric
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_e     RECORD;
    v_hasta DATE;
    v_edad  INTERVAL;
BEGIN
    SELECT e.fecha_ingreso, e.fecha_salida INTO v_e FROM rrhh_empleados e WHERE e.id = p_empleado_id;
    IF NOT FOUND THEN RETURN 0; END IF;
    v_hasta := LEAST(p_fecha, COALESCE(v_e.fecha_salida, p_fecha));
    IF v_hasta < v_e.fecha_ingreso THEN RETURN 0; END IF;
    v_edad := age(v_hasta, v_e.fecha_ingreso);
    RETURN (EXTRACT(YEAR FROM v_edad) * 12 + EXTRACT(MONTH FROM v_edad))::NUMERIC;
END; $$;


--
-- Name: fn_rrhh_vac_movimientos(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_vac_movimientos(p_empleado_id bigint) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT COALESCE(SUM(m.dias), 0) FROM rrhh_vacaciones_movimientos m WHERE m.empleado_id = p_empleado_id AND m.deleted_at IS NULL;
$$;


--
-- Name: fn_rrhh_vac_reservado(bigint, bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_vac_reservado(p_empleado_id bigint, p_excluir_id bigint, p_solo_aprobadas boolean DEFAULT false) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT COALESCE(SUM(s.dias), 0)::NUMERIC FROM rrhh_vacaciones_solicitudes s
     WHERE s.empleado_id = p_empleado_id AND s.deleted_at IS NULL AND s.id <> COALESCE(p_excluir_id, 0)
       AND (s.estado = 'aprobada' OR (NOT p_solo_aprobadas AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh')));
$$;


--
-- Name: fn_rrhh_vac_tarifa(bigint, bigint, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_vac_tarifa(p_empresa_id bigint, p_empleado_id bigint, p_fecha date) RETURNS TABLE(valor_dia numeric, extras_50sem numeric, extras_dia numeric, promedio_dia numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_e      RECORD;
    v_ref    DATE := LEAST(p_fecha, CURRENT_DATE);
    v_ini    DATE;
    v_cur    DATE;
    v_hasta  DATE;
    v_ext    NUMERIC := 0;
    v_vd     NUMERIC;
    v_win    NUMERIC;
    v_ed     NUMERIC;
BEGIN
    SELECT e.salario_base, e.periodo_pago, e.fecha_ingreso INTO v_e
      FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id;
    IF NOT FOUND THEN RETURN; END IF;

    v_vd  := v_e.salario_base / (CASE v_e.periodo_pago WHEN 'mensual' THEN 30 WHEN 'quincenal' THEN 15 ELSE 6 END);
    v_ini := GREATEST(v_e.fecha_ingreso, v_ref - 349);
    v_win := GREATEST(v_ref - v_ini + 1, 1);
    v_cur := v_ini;
    WHILE v_cur <= v_ref LOOP
        v_hasta := LEAST(v_cur + 89, v_ref);   -- el resumen de asistencia acepta como máximo 93 días por consulta
        SELECT v_ext + COALESCE(SUM(x.monto_aprobado), 0) INTO v_ext FROM sp_rrhh_horas_extra(p_empresa_id, v_cur, v_hasta, p_empleado_id, NULL) x;
        v_cur := v_hasta + 1;
    END LOOP;
    v_ed := v_ext / (CASE WHEN v_e.periodo_pago = 'semanal' THEN v_win * 6 / 7 ELSE v_win END);

    valor_dia := round(v_vd, 2); extras_50sem := round(v_ext, 2); extras_dia := round(v_ed, 2); promedio_dia := round(v_vd + v_ed, 2);
    RETURN NEXT;
END; $$;


--
-- Name: fn_rrhh_vac_validar(bigint, bigint, date, date, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_vac_validar(p_empresa_id bigint, p_empleado_id bigint, p_inicio date, p_fin date, p_excluir_id bigint) RETURNS integer
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_e         RECORD;
    v_dias      INTEGER;
    v_disp      NUMERIC;
    v_elegible  DATE;
BEGIN
    SELECT e.fecha_ingreso, e.fecha_salida, e.estado INTO v_e
      FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.'; END IF;
    IF v_e.estado <> 'activo' THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: Solo los empleados activos pueden tomar vacaciones.'; END IF;
    IF p_fin < p_inicio THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha final es anterior a la inicial.'; END IF;
    IF p_fin - p_inicio > 60 THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: Una solicitud no puede pasar de 60 días; divídala en dos.'; END IF;

    v_elegible := v_e.fecha_ingreso + 350;   -- 50 semanas
    IF p_inicio < v_elegible THEN
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: El empleado cumple las 50 semanas de servicio el %; puede disfrutar vacaciones desde esa fecha.', to_char(v_elegible, 'DD/MM/YYYY');
    END IF;
    IF v_e.fecha_salida IS NOT NULL AND p_fin > v_e.fecha_salida THEN
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: Las fechas pasan de la fecha de salida del empleado.';
    END IF;

    v_dias := fn_rrhh_dias_habiles(p_empresa_id, p_empleado_id, p_inicio, p_fin);
    IF v_dias = 0 THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: El rango no incluye días laborales (los descansos y feriados no cuentan).'; END IF;

    IF EXISTS (SELECT 1 FROM rrhh_vacaciones_solicitudes s
                WHERE s.empleado_id = p_empleado_id AND s.deleted_at IS NULL AND s.id <> COALESCE(p_excluir_id, 0)
                  AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada')
                  AND s.fecha_inicio <= p_fin AND s.fecha_fin >= p_inicio) THEN
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: Ya hay una solicitud de vacaciones de este empleado que se cruza con esas fechas.';
    END IF;
    IF EXISTS (SELECT 1 FROM rrhh_incapacidades i
                WHERE i.empleado_id = p_empleado_id AND i.deleted_at IS NULL AND i.estado = 'registrada'
                  AND i.fecha_inicio <= p_fin AND i.fecha_fin >= p_inicio) THEN
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: El empleado tiene una incapacidad registrada que se cruza con esas fechas.';
    END IF;
    IF EXISTS (SELECT 1 FROM rrhh_permiso_solicitudes s
                WHERE s.empleado_id = p_empleado_id AND s.deleted_at IS NULL
                  AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada')
                  AND s.fecha_inicio <= p_fin AND s.fecha_fin >= p_inicio) THEN
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: El empleado tiene un permiso pedido o aprobado que se cruza con esas fechas.';
    END IF;

    v_disp := fn_rrhh_vac_devengado(p_empleado_id, p_inicio) + fn_rrhh_vac_movimientos(p_empleado_id) - fn_rrhh_vac_reservado(p_empleado_id, p_excluir_id);
    IF v_dias > v_disp THEN
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: Solicita % día(s) hábil(es) y a esa fecha solo tiene % disponible(s).', v_dias, trim(trailing '.' FROM trim(trailing '0' FROM round(GREATEST(v_disp, 0), 2)::TEXT));
    END IF;

    PERFORM fn_rrhh_vac_validar_fracciones(p_empleado_id, p_inicio, v_dias, p_excluir_id);
    RETURN v_dias;
END; $$;


--
-- Name: fn_rrhh_vac_validar_fracciones(bigint, date, integer, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_vac_validar_fracciones(p_empleado_id bigint, p_inicio date, p_dias integer, p_excluir_id bigint) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_periodo INTEGER;
BEGIN
    SELECT t.per INTO v_periodo FROM (
        WITH base AS (
            SELECT GREATEST(COALESCE(-SUM(m.dias), 0), 0) AS b
              FROM rrhh_vacaciones_movimientos m WHERE m.empleado_id = p_empleado_id AND m.deleted_at IS NULL
        ),
        reqs AS (
            SELECT s.id AS rid, s.fecha_inicio AS ini, s.dias::NUMERIC AS d FROM rrhh_vacaciones_solicitudes s
             WHERE s.empleado_id = p_empleado_id AND s.deleted_at IS NULL
               AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada') AND s.id <> COALESCE(p_excluir_id, 0)
            UNION ALL
            SELECT 0::BIGINT, p_inicio, p_dias::NUMERIC
        ),
        rg AS (
            SELECT r.d, (SELECT b FROM base) + COALESCE(SUM(r.d) OVER (ORDER BY r.ini, r.rid ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS a
              FROM reqs r
        )
        SELECT gs.per FROM rg, LATERAL generate_series(floor(rg.a / 12)::INTEGER, floor((rg.a + rg.d - 1) / 12)::INTEGER) AS gs(per)
         GROUP BY gs.per HAVING COUNT(*) > 2 ORDER BY gs.per LIMIT 1
    ) t;
    IF v_periodo IS NOT NULL THEN
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: Con esas fechas un mismo período de 12 días quedaría repartido en más de dos fracciones; el Código de Trabajo (art. 154) permite dividirlo en dos como máximo.';
    END IF;
END; $$;


--
-- Name: fn_rrhh_valida_depto_padre(bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_valida_depto_padre(p_empresa_id bigint, p_depto_id bigint, p_padre_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF p_padre_id IS NULL THEN RETURN; END IF;
    IF p_depto_id IS NOT NULL AND p_padre_id = p_depto_id THEN
        RAISE EXCEPTION 'DEPTO_INVALIDO: Un departamento no puede depender de sí mismo.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rrhh_departamentos WHERE id = p_padre_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'DEPTO_INVALIDO: El departamento superior indicado no existe.';
    END IF;
    IF p_depto_id IS NOT NULL AND EXISTS (
        WITH RECURSIVE cadena AS (
            SELECT d.id, d.departamento_padre_id FROM rrhh_departamentos d WHERE d.id = p_padre_id
            UNION
            SELECT d.id, d.departamento_padre_id FROM rrhh_departamentos d JOIN cadena c ON d.id = c.departamento_padre_id
        ) SELECT 1 FROM cadena WHERE id = p_depto_id
    ) THEN
        RAISE EXCEPTION 'DEPTO_CICLO: Ese departamento depende de este (directa o indirectamente); la estructura quedaría en círculo.';
    END IF;
END; $$;


--
-- Name: fn_rrhh_valida_dispositivo(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_valida_dispositivo(p_empresa_id bigint, p_agente_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF p_agente_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM rrhh_agentes WHERE id = p_agente_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'AGENTE_INVALIDO: El agente indicado no existe.';
    END IF;
END; $$;


--
-- Name: fn_rrhh_valida_empleado_refs(bigint, bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_valida_empleado_refs(p_empresa_id bigint, p_empleado_id bigint, p_d jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_depto BIGINT := NULLIF(p_d->>'departamento_id', '')::BIGINT;
    v_puesto BIGINT := NULLIF(p_d->>'puesto_id', '')::BIGINT;
    v_func  BIGINT := NULLIF(p_d->>'funcionario_id', '')::BIGINT;
BEGIN
    IF v_depto IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM rrhh_departamentos WHERE id = v_depto AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El departamento indicado no existe.';
    END IF;
    IF v_puesto IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM rrhh_puestos WHERE id = v_puesto AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El puesto indicado no existe.';
    END IF;
    IF v_func IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM funcionarios WHERE id = v_func AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'REF_INVALIDA: El funcionario indicado no existe.';
        END IF;
        IF EXISTS (SELECT 1 FROM rrhh_empleados WHERE funcionario_id = v_func AND deleted_at IS NULL
                      AND (p_empleado_id IS NULL OR id <> p_empleado_id)) THEN
            RAISE EXCEPTION 'REF_INVALIDA: Ese funcionario ya está ligado a otro empleado.';
        END IF;
    END IF;
    IF NULLIF(p_d->>'fecha_fin_contrato', '') IS NOT NULL
       AND (p_d->>'fecha_fin_contrato')::DATE < (p_d->>'fecha_ingreso')::DATE THEN
        RAISE EXCEPTION 'FECHA_INVALIDA: El fin del contrato no puede ser anterior a la fecha de ingreso.';
    END IF;
END; $$;


--
-- Name: fn_rrhh_valida_horario(character varying, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_valida_horario(p_jornada character varying, p_dias jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    d             RECORD;
    v_total       INTEGER := 0;
    v_max_dia     INTEGER;
    v_max_semana  INTEGER;
    v_minutos     INTEGER;
    v_vistos      INTEGER[] := '{}';
BEGIN
    IF p_dias IS NULL OR jsonb_typeof(p_dias) <> 'array' OR jsonb_array_length(p_dias) = 0 THEN
        RAISE EXCEPTION 'HORARIO_INVALIDO: Indique al menos un día laboral.';
    END IF;
    -- Máximo diario (jornada ampliada de hasta 10 h diurna / 8 h mixta si la semana no pasa del límite) y semanal.
    v_max_dia    := CASE p_jornada WHEN 'diurna' THEN 600 WHEN 'mixta' THEN 480 WHEN 'nocturna' THEN 360 ELSE 600 END;
    v_max_semana := CASE p_jornada WHEN 'diurna' THEN 2880 WHEN 'mixta' THEN 2520 WHEN 'nocturna' THEN 2160 ELSE 2880 END;

    FOR d IN SELECT (x->>'dia_semana')::INTEGER AS dia, (x->>'hora_entrada')::TIME AS ent, (x->>'hora_salida')::TIME AS sal,
                    COALESCE((x->>'minutos_descanso')::INTEGER, 0) AS descanso
               FROM jsonb_array_elements(p_dias) x
    LOOP
        IF d.dia NOT BETWEEN 1 AND 7 THEN RAISE EXCEPTION 'HORARIO_INVALIDO: Día de la semana inválido.'; END IF;
        IF d.dia = ANY (v_vistos) THEN RAISE EXCEPTION 'HORARIO_INVALIDO: Un día de la semana está repetido.'; END IF;
        v_vistos := v_vistos || d.dia;
        IF d.ent = d.sal THEN RAISE EXCEPTION 'HORARIO_INVALIDO: La entrada y la salida no pueden ser la misma hora.'; END IF;
        v_minutos := fn_rrhh_minutos_dia(d.ent, d.sal, d.descanso);
        IF v_minutos <= 0 THEN RAISE EXCEPTION 'HORARIO_INVALIDO: El descanso no puede ser igual o mayor que el tiempo del turno.'; END IF;
        IF v_minutos > v_max_dia THEN
            RAISE EXCEPTION 'HORARIO_INVALIDO: Un turno de jornada % no puede pasar de % horas ordinarias por día (Código de Trabajo, art. 136).', p_jornada, v_max_dia / 60;
        END IF;
        v_total := v_total + v_minutos;
    END LOOP;

    IF v_total > v_max_semana THEN
        RAISE EXCEPTION 'HORARIO_INVALIDO: La jornada % no puede pasar de % horas ordinarias por semana (art. 136); este horario suma % h.',
            p_jornada, v_max_semana / 60, round(v_total / 60.0, 1);
    END IF;
END; $$;


--
-- Name: fn_rrhh_valida_jefe(bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rrhh_valida_jefe(p_empresa_id bigint, p_empleado_id bigint, p_jefe_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF p_jefe_id IS NULL THEN RETURN; END IF;
    IF p_empleado_id IS NOT NULL AND p_jefe_id = p_empleado_id THEN
        RAISE EXCEPTION 'JEFE_INVALIDO: Un empleado no puede ser su propio jefe.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rrhh_empleados WHERE id = p_jefe_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'JEFE_INVALIDO: El jefe indicado no existe.';
    END IF;
    IF p_empleado_id IS NOT NULL AND EXISTS (
        WITH RECURSIVE cadena AS (
            SELECT e.id, e.jefe_id FROM rrhh_empleados e WHERE e.id = p_jefe_id
            UNION
            SELECT e.id, e.jefe_id FROM rrhh_empleados e JOIN cadena c ON e.id = c.jefe_id
        ) SELECT 1 FROM cadena WHERE id = p_empleado_id
    ) THEN
        RAISE EXCEPTION 'JEFE_CICLO: Ese jefe es subordinado (directo o indirecto) de este empleado; la jerarquía quedaría en círculo.';
    END IF;
END; $$;


--
-- Name: fn_valida_espacio_libre(bigint, timestamp without time zone, timestamp without time zone, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_valida_espacio_libre(p_espacio_id bigint, p_inicio timestamp without time zone, p_fin timestamp without time zone, p_excluir_linea_id bigint DEFAULT NULL::bigint, p_excluir_evento_id bigint DEFAULT NULL::bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_nombre VARCHAR;
    v_c      RECORD;
BEGIN
    IF p_espacio_id IS NULL THEN RETURN; END IF;

    PERFORM pg_advisory_xact_lock(hashtext('agenda_espacio'), p_espacio_id::int);

    SELECT e.titulo, l.fecha_inicio, l.fecha_fin INTO v_c
    FROM agenda_evento_lineas l
    JOIN agenda_eventos e ON e.id = l.evento_id AND e.deleted_at IS NULL AND e.estado <> 'cancelado'
    WHERE l.espacio_id = p_espacio_id
      AND l.estado <> 'cancelado'
      AND l.fecha_inicio < p_fin AND l.fecha_fin > p_inicio
      AND (p_excluir_linea_id IS NULL OR l.id <> p_excluir_linea_id)
      AND (p_excluir_evento_id IS NULL OR e.id <> p_excluir_evento_id)
    ORDER BY l.fecha_inicio LIMIT 1;

    IF FOUND THEN
        SELECT nombre INTO v_nombre FROM agenda_espacios WHERE id = p_espacio_id;
        RAISE EXCEPTION 'ESPACIO_OCUPADO: El espacio «%» ya está reservado por la cita «%» de % a %, que se traslapa con este horario.',
            v_nombre, v_c.titulo, to_char(v_c.fecha_inicio, 'DD/MM/YYYY HH24:MI'), to_char(v_c.fecha_fin, 'HH24:MI');
    END IF;
END; $$;


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
-- Name: sp_agenda_avisos_desmarcar_enviado(bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_avisos_desmarcar_enviado(p_evento_id bigint, p_tipo character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
    BEGIN
        DELETE FROM agenda_avisos_envios
         WHERE evento_id = p_evento_id AND tipo = p_tipo;
        RETURN FOUND;
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
            (SELECT COALESCE(es.nombre, l.ubicacion)::VARCHAR FROM agenda_evento_lineas l
               LEFT JOIN agenda_espacios es ON es.id = l.espacio_id
              WHERE l.evento_id = e.id ORDER BY l.orden, l.id LIMIT 1),
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
          AND e.fecha_inicio >= (p_fecha_ref + INTERVAL '22 hours')
          AND e.fecha_inicio <  (p_fecha_ref + INTERVAL '25 hours')
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
            (SELECT COALESCE(es.nombre, l.ubicacion)::VARCHAR FROM agenda_evento_lineas l
               LEFT JOIN agenda_espacios es ON es.id = l.espacio_id
              WHERE l.evento_id = e.id ORDER BY l.orden, l.id LIMIT 1),
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
          AND e.fecha_inicio >=
                (p_fecha_ref + (cfg.aviso_discrecional_dias || ' days')::INTERVAL - INTERVAL '2 hours')
          AND e.fecha_inicio <
                (p_fecha_ref + (cfg.aviso_discrecional_dias || ' days')::INTERVAL + INTERVAL '1 hour')
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
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    DECLARE
        v_evento_id BIGINT;
        v_motivo    CONSTANT TEXT := 'Cancelada por el cliente desde el enlace del aviso.';
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

        IF p_estado = 'cancelado' THEN
            UPDATE agenda_evento_lineas SET
                estado = 'cancelado',
                motivo_cancelacion = v_motivo,
                cancelado_at = NOW(),
                cancelado_por_nombre = 'Cliente',
                updated_at = NOW()
            WHERE evento_id = v_evento_id
              AND fn_agenda_linea_estado(estado, documento_id) = 'pendiente';

            PERFORM fn_agenda_evento_recalcular(v_evento_id, NULL, v_motivo, NULL, 'Cliente');
        ELSE
            UPDATE agenda_eventos SET estado = p_estado, updated_at = NOW()
            WHERE id = v_evento_id;
        END IF;

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
        e.titulo,
        (SELECT string_agg(DISTINCT s.name, ', ')
           FROM agenda_evento_lineas l
           JOIN servicios s ON s.id = l.servicio_id
          WHERE l.evento_id = e.id)::TEXT,
        (SELECT COALESCE(es.nombre, l.ubicacion) FROM agenda_evento_lineas l
           LEFT JOIN agenda_espacios es ON es.id = l.espacio_id
          WHERE l.evento_id = e.id ORDER BY l.orden, l.id LIMIT 1)::VARCHAR,
        e.fecha_inicio, e.estado
    FROM agenda_avisos_tokens t
    JOIN agenda_eventos e ON e.id = t.evento_id
    WHERE t.token = p_token;
END;
$$;


--
-- Name: sp_agenda_espacio_create(bigint, character varying, character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_espacio_create(p_empresa_id bigint, p_nombre character varying, p_descripcion character varying, p_sucursal_id bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO agenda_espacios (empresa_id, sucursal_id, nombre, descripcion)
    VALUES (p_empresa_id, p_sucursal_id, btrim(p_nombre), NULLIF(btrim(COALESCE(p_descripcion, '')), ''))
    RETURNING agenda_espacios.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_agenda_espacio_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_espacio_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, sucursal_id bigint, nombre character varying, descripcion character varying, is_active boolean, deleted_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT es.id, es.empresa_id, es.sucursal_id, es.nombre, es.descripcion, es.is_active, es.deleted_at
    FROM agenda_espacios es
    WHERE es.id = p_id AND es.empresa_id = p_empresa_id;
END; $$;


--
-- Name: sp_agenda_espacio_list(bigint, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_espacio_list(p_empresa_id bigint, p_eliminados boolean DEFAULT false, p_solo_activos boolean DEFAULT false) RETURNS TABLE(id bigint, empresa_id bigint, sucursal_id bigint, nombre character varying, descripcion character varying, is_active boolean, deleted_at timestamp without time zone, citas_futuras bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT es.id, es.empresa_id, es.sucursal_id, es.nombre, es.descripcion, es.is_active, es.deleted_at,
           (SELECT COUNT(*) FROM agenda_evento_lineas l
              JOIN agenda_eventos e ON e.id = l.evento_id AND e.deleted_at IS NULL AND e.estado <> 'cancelado'
             WHERE l.espacio_id = es.id AND l.estado = 'pendiente' AND l.fecha_fin > NOW())
    FROM agenda_espacios es
    WHERE es.empresa_id = p_empresa_id
      AND ((p_eliminados AND es.deleted_at IS NOT NULL) OR (NOT p_eliminados AND es.deleted_at IS NULL))
      AND (NOT p_solo_activos OR es.is_active)
    ORDER BY lower(regexp_replace(es.nombre, '[0-9]+', '', 'g')),
             NULLIF(substring(es.nombre from '[0-9]{1,9}'), '')::int NULLS FIRST,
             es.nombre;
END; $$;


--
-- Name: sp_agenda_espacio_restore(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_espacio_restore(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE agenda_espacios SET deleted_at = NULL, is_active = TRUE, updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NOT NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_agenda_espacio_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_espacio_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE agenda_espacios SET is_active = FALSE, deleted_at = NOW(), updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_agenda_espacio_update(bigint, bigint, character varying, character varying, bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_espacio_update(p_id bigint, p_empresa_id bigint, p_nombre character varying, p_descripcion character varying, p_sucursal_id bigint, p_is_active boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE agenda_espacios SET
        nombre = btrim(p_nombre), descripcion = NULLIF(btrim(COALESCE(p_descripcion, '')), ''),
        sucursal_id = p_sucursal_id, is_active = p_is_active, updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_agenda_espacios_ocupados(bigint, timestamp without time zone, timestamp without time zone, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_espacios_ocupados(p_empresa_id bigint, p_desde timestamp without time zone, p_hasta timestamp without time zone, p_excluir_evento_id bigint DEFAULT NULL::bigint) RETURNS TABLE(espacio_id bigint, evento_id bigint, linea_id bigint, titulo character varying, fecha_inicio timestamp without time zone, fecha_fin timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT l.espacio_id, e.id, l.id, e.titulo, l.fecha_inicio, l.fecha_fin
    FROM agenda_evento_lineas l
    JOIN agenda_eventos e ON e.id = l.evento_id AND e.empresa_id = p_empresa_id
                         AND e.deleted_at IS NULL AND e.estado <> 'cancelado'
    WHERE l.espacio_id IS NOT NULL
      AND l.estado <> 'cancelado'
      AND l.fecha_inicio < p_hasta AND l.fecha_fin > p_desde
      AND (p_excluir_evento_id IS NULL OR e.id <> p_excluir_evento_id)
    ORDER BY l.fecha_inicio;
END; $$;


--
-- Name: sp_agenda_evento_create(bigint, bigint, bigint, character varying, timestamp without time zone, timestamp without time zone, boolean, bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_create(p_empresa_id bigint, p_sucursal_id bigint, p_user_id bigint, p_titulo character varying, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone, p_todo_el_dia boolean, p_cliente_id bigint, p_color character varying, p_estado character varying) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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

CREATE FUNCTION public.sp_agenda_evento_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, sucursal_id bigint, user_id bigint, titulo character varying, fecha_inicio timestamp without time zone, fecha_fin timestamp without time zone, todo_el_dia boolean, cliente_id bigint, cliente_nombre character varying, color character varying, estado character varying, documento_id bigint, motivo_cancelacion text, cancelado_at timestamp without time zone, cancelado_por_nombre character varying, created_at timestamp without time zone, updated_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    BEGIN
        RETURN QUERY
        SELECT ae.id, ae.empresa_id, ae.sucursal_id, ae.user_id,
               ae.titulo,
               ae.fecha_inicio, ae.fecha_fin, ae.todo_el_dia,
               ae.cliente_id, c.name AS cliente_nombre,
               ae.color, ae.estado, ae.documento_id,
               ae.motivo_cancelacion, ae.cancelado_at, ae.cancelado_por_nombre,
               ae.created_at, ae.updated_at
        FROM agenda_eventos ae
        LEFT JOIN clients c ON c.id = ae.cliente_id
        WHERE ae.id = p_id AND ae.empresa_id = p_empresa_id AND ae.deleted_at IS NULL;
    END; $$;


--
-- Name: sp_agenda_evento_linea_cancelar(bigint, bigint, bigint, text, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_linea_cancelar(p_linea_id bigint, p_evento_id bigint, p_empresa_id bigint, p_motivo text, p_user_id bigint, p_user_nombre character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    DECLARE
        v_existe BOOLEAN;
        v_estado VARCHAR;
    BEGIN
        IF p_motivo IS NULL OR char_length(btrim(p_motivo)) < 3 THEN
            RAISE EXCEPTION 'MOTIVO_REQUERIDO: Indique el motivo de la cancelación.';
        END IF;

        SELECT TRUE INTO v_existe FROM agenda_eventos
         WHERE id = p_evento_id AND empresa_id = p_empresa_id AND deleted_at IS NULL
         FOR UPDATE;
        IF v_existe IS NULL THEN
            RETURN FALSE;
        END IF;

        SELECT fn_agenda_linea_estado(l.estado, l.documento_id) INTO v_estado
          FROM agenda_evento_lineas l WHERE l.id = p_linea_id AND l.evento_id = p_evento_id;
        IF v_estado IS NULL THEN
            RETURN FALSE;
        END IF;
        IF v_estado = 'facturado' THEN
            RAISE EXCEPTION 'LINEA_NO_PENDIENTE: El servicio ya fue facturado y no se puede cancelar.';
        ELSIF v_estado = 'cancelado' THEN
            RAISE EXCEPTION 'LINEA_NO_PENDIENTE: El servicio ya está cancelado.';
        END IF;

        UPDATE agenda_evento_lineas SET
            estado = 'cancelado', motivo_cancelacion = btrim(p_motivo),
            cancelado_at = NOW(), cancelado_por = p_user_id, cancelado_por_nombre = p_user_nombre,
            updated_at = NOW()
        WHERE id = p_linea_id;

        PERFORM fn_agenda_evento_recalcular(p_evento_id, NULL, btrim(p_motivo), p_user_id, p_user_nombre);
        UPDATE agenda_eventos SET updated_at = NOW() WHERE id = p_evento_id;
        RETURN TRUE;
    END; $$;


--
-- Name: sp_agenda_evento_linea_create(bigint, bigint, bigint, timestamp without time zone, timestamp without time zone, text, character varying, integer, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_linea_create(p_evento_id bigint, p_servicio_id bigint, p_funcionario_id bigint, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone, p_comentario text, p_ubicacion character varying, p_orden integer, p_espacio_id bigint DEFAULT NULL::bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_id          BIGINT;
    v_todo_el_dia BOOLEAN;
BEGIN
    IF p_funcionario_id IS NOT NULL THEN
        SELECT todo_el_dia INTO v_todo_el_dia FROM agenda_eventos WHERE id = p_evento_id;
        PERFORM fn_valida_horario_funcionario(p_funcionario_id, p_fecha_inicio, p_fecha_fin, v_todo_el_dia);
    END IF;
    PERFORM fn_valida_espacio_libre(p_espacio_id, p_fecha_inicio, p_fecha_fin, NULL, p_evento_id);

    INSERT INTO agenda_evento_lineas (evento_id, servicio_id, funcionario_id, fecha_inicio, fecha_fin, comentario, ubicacion, espacio_id, orden)
    VALUES (p_evento_id, p_servicio_id, p_funcionario_id, p_fecha_inicio, p_fecha_fin, p_comentario, p_ubicacion, p_espacio_id, p_orden)
    RETURNING id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_agenda_evento_linea_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_linea_delete(p_linea_id bigint, p_evento_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    DECLARE v_estado VARCHAR;
    BEGIN
        SELECT fn_agenda_linea_estado(l.estado, l.documento_id) INTO v_estado
          FROM agenda_evento_lineas l WHERE l.id = p_linea_id AND l.evento_id = p_evento_id;
        IF v_estado IS NULL THEN
            RETURN FALSE;
        END IF;
        IF v_estado <> 'pendiente' THEN
            RAISE EXCEPTION 'LINEA_NO_PENDIENTE: Un servicio facturado o cancelado no se puede quitar de la cita.';
        END IF;

        DELETE FROM agenda_evento_linea_productos WHERE linea_id = p_linea_id;
        DELETE FROM agenda_evento_lineas WHERE id = p_linea_id;
        RETURN TRUE;
    END; $$;


--
-- Name: sp_agenda_evento_linea_producto_create(bigint, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_linea_producto_create(p_linea_id bigint, p_producto_id bigint, p_cantidad numeric) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO agenda_evento_linea_productos (linea_id, producto_id, cantidad)
                VALUES (p_linea_id, p_producto_id, p_cantidad)
                RETURNING id INTO v_id;
                RETURN v_id;
            END; $$;


--
-- Name: sp_agenda_evento_linea_reagendar(bigint, bigint, bigint, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_linea_reagendar(p_linea_id bigint, p_evento_id bigint, p_empresa_id bigint, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_sucursal_id    BIGINT;
    v_todo_el_dia    BOOLEAN;
    v_estado_evento  VARCHAR;
    v_estado         VARCHAR;
    v_funcionario_id BIGINT;
    v_espacio_id     BIGINT;
BEGIN
    SELECT sucursal_id, todo_el_dia, estado INTO v_sucursal_id, v_todo_el_dia, v_estado_evento
      FROM agenda_eventos
     WHERE id = p_evento_id AND empresa_id = p_empresa_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    SELECT fn_agenda_linea_estado(l.estado, l.documento_id), l.funcionario_id, l.espacio_id
      INTO v_estado, v_funcionario_id, v_espacio_id
      FROM agenda_evento_lineas l WHERE l.id = p_linea_id AND l.evento_id = p_evento_id;
    IF v_estado IS NULL THEN
        RETURN FALSE;
    END IF;
    IF v_estado <> 'pendiente' OR v_estado_evento = 'cancelado' THEN
        RAISE EXCEPTION 'LINEA_NO_PENDIENTE: Solo se puede reagendar un servicio pendiente de una cita activa.';
    END IF;

    -- Solo la NUEVA fecha debe ser futura: la anterior puede haber pasado (el cliente se fue).
    PERFORM fn_valida_evento_no_pasado(p_fecha_inicio);
    PERFORM fn_valida_horario_sucursal(v_sucursal_id, p_fecha_inicio, p_fecha_fin, v_todo_el_dia);
    IF v_funcionario_id IS NOT NULL THEN
        PERFORM fn_valida_horario_funcionario(v_funcionario_id, p_fecha_inicio, p_fecha_fin, v_todo_el_dia);
    END IF;
    PERFORM fn_valida_espacio_libre(v_espacio_id, p_fecha_inicio, p_fecha_fin, p_linea_id, NULL);

    UPDATE agenda_evento_lineas SET
        fecha_inicio = p_fecha_inicio, fecha_fin = p_fecha_fin, updated_at = NOW()
    WHERE id = p_linea_id;

    UPDATE agenda_eventos SET
        fecha_inicio = (SELECT MIN(l.fecha_inicio) FROM agenda_evento_lineas l WHERE l.evento_id = p_evento_id AND l.estado <> 'cancelado'),
        fecha_fin    = (SELECT MAX(l.fecha_fin)    FROM agenda_evento_lineas l WHERE l.evento_id = p_evento_id AND l.estado <> 'cancelado'),
        updated_at   = NOW()
    WHERE id = p_evento_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_agenda_evento_linea_update(bigint, bigint, bigint, bigint, timestamp without time zone, timestamp without time zone, text, character varying, integer, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_linea_update(p_linea_id bigint, p_evento_id bigint, p_servicio_id bigint, p_funcionario_id bigint, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone, p_comentario text, p_ubicacion character varying, p_orden integer, p_espacio_id bigint DEFAULT NULL::bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_todo_el_dia BOOLEAN;
    v_estado      VARCHAR;
BEGIN
    SELECT fn_agenda_linea_estado(l.estado, l.documento_id) INTO v_estado
      FROM agenda_evento_lineas l WHERE l.id = p_linea_id AND l.evento_id = p_evento_id;
    IF v_estado IS NULL OR v_estado <> 'pendiente' THEN
        RETURN FALSE;
    END IF;

    IF p_funcionario_id IS NOT NULL THEN
        SELECT todo_el_dia INTO v_todo_el_dia FROM agenda_eventos WHERE id = p_evento_id;
        PERFORM fn_valida_horario_funcionario(p_funcionario_id, p_fecha_inicio, p_fecha_fin, v_todo_el_dia);
    END IF;
    PERFORM fn_valida_espacio_libre(p_espacio_id, p_fecha_inicio, p_fecha_fin, NULL, p_evento_id);

    DELETE FROM agenda_evento_linea_productos WHERE linea_id = p_linea_id;
    UPDATE agenda_evento_lineas SET
        servicio_id = p_servicio_id, funcionario_id = p_funcionario_id,
        fecha_inicio = p_fecha_inicio, fecha_fin = p_fecha_fin,
        comentario = p_comentario, ubicacion = p_ubicacion, espacio_id = p_espacio_id, orden = p_orden,
        updated_at = NOW()
    WHERE id = p_linea_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_agenda_evento_lineas_delete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_lineas_delete(p_evento_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
            BEGIN
                DELETE FROM agenda_evento_linea_productos
                WHERE linea_id IN (SELECT id FROM agenda_evento_lineas WHERE evento_id = p_evento_id);
                DELETE FROM agenda_evento_lineas WHERE evento_id = p_evento_id;
            END; $$;


--
-- Name: sp_agenda_evento_lineas_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_lineas_list(p_evento_id bigint) RETURNS TABLE(linea_id bigint, servicio_id bigint, servicio_nombre character varying, funcionario_id bigint, funcionario_nombre character varying, funcionario_color character varying, fecha_inicio timestamp without time zone, fecha_fin timestamp without time zone, comentario text, ubicacion character varying, orden integer, productos jsonb, estado character varying, documento_id bigint, documento_numero character varying, motivo_cancelacion text, cancelado_at timestamp without time zone, cancelado_por_nombre character varying, espacio_id bigint, espacio_nombre character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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
           ), '[]'::jsonb) AS productos,
           fn_agenda_linea_estado(l.estado, l.documento_id)::VARCHAR,
           CASE WHEN fn_agenda_linea_estado(l.estado, l.documento_id) = 'facturado' THEN l.documento_id END,
           CASE WHEN fn_agenda_linea_estado(l.estado, l.documento_id) = 'facturado'
                THEN (SELECT d.numero_consecutivo::VARCHAR FROM documentos_electronicos d WHERE d.id = l.documento_id) END,
           l.motivo_cancelacion, l.cancelado_at, l.cancelado_por_nombre,
           l.espacio_id, es.nombre
    FROM agenda_evento_lineas l
    LEFT JOIN servicios        s  ON s.id  = l.servicio_id
    LEFT JOIN funcionarios     f  ON f.id  = l.funcionario_id
    LEFT JOIN agenda_espacios  es ON es.id = l.espacio_id
    WHERE l.evento_id = p_evento_id
    ORDER BY l.orden, l.id;
END; $$;


--
-- Name: sp_agenda_evento_list(bigint, timestamp without time zone, timestamp without time zone, bigint[], bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_list(p_empresa_id bigint, p_fecha_desde timestamp without time zone, p_fecha_hasta timestamp without time zone, p_funcionario_ids bigint[] DEFAULT NULL::bigint[], p_sucursal_id bigint DEFAULT NULL::bigint) RETURNS TABLE(evento_id bigint, linea_id bigint, titulo character varying, fecha_inicio timestamp without time zone, fecha_fin timestamp without time zone, todo_el_dia boolean, cliente_id bigint, cliente_nombre character varying, cliente_telefono character varying, cliente_email character varying, color character varying, estado character varying, servicio_id bigint, servicio_nombre character varying, funcionario_id bigint, funcionario_nombre character varying, funcionario_color character varying, sucursal_id bigint, linea_estado character varying, espacio_id bigint, espacio_nombre character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT ae.id, l.id, ae.titulo,
           l.fecha_inicio, l.fecha_fin, ae.todo_el_dia,
           ae.cliente_id, c.name AS cliente_nombre, c.phone AS cliente_telefono, c.email AS cliente_email,
           ae.color, ae.estado,
           l.servicio_id, s.name AS servicio_nombre,
           l.funcionario_id, f.name AS funcionario_nombre, f.color AS funcionario_color,
           ae.sucursal_id,
           fn_agenda_linea_estado(l.estado, l.documento_id)::VARCHAR AS linea_estado,
           l.espacio_id, es.nombre AS espacio_nombre
    FROM agenda_eventos ae
    JOIN agenda_evento_lineas l ON l.evento_id = ae.id
    LEFT JOIN clients c ON c.id = ae.cliente_id
    LEFT JOIN servicios        s  ON s.id  = l.servicio_id
    LEFT JOIN funcionarios     f  ON f.id  = l.funcionario_id
    LEFT JOIN agenda_espacios  es ON es.id = l.espacio_id
    WHERE ae.empresa_id = p_empresa_id
      AND ae.deleted_at IS NULL
      AND l.fecha_inicio < p_fecha_hasta
      AND l.fecha_fin > p_fecha_desde
      AND (p_funcionario_ids IS NULL OR array_length(p_funcionario_ids, 1) IS NULL OR l.funcionario_id = ANY(p_funcionario_ids))
      AND (p_sucursal_id IS NULL OR ae.sucursal_id = p_sucursal_id)
    ORDER BY l.fecha_inicio, l.orden;
END; $$;


--
-- Name: sp_agenda_evento_marcar_facturado(bigint, bigint, bigint, bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_marcar_facturado(p_id bigint, p_empresa_id bigint, p_documento_id bigint, p_linea_ids bigint[] DEFAULT NULL::bigint[]) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    DECLARE
        v_existe BOOLEAN;
        v_n      INTEGER;
        v_validas INTEGER;
    BEGIN
        SELECT TRUE INTO v_existe FROM agenda_eventos
         WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL
         FOR UPDATE;
        IF v_existe IS NULL THEN
            RETURN FALSE;
        END IF;

        IF p_linea_ids IS NULL OR array_length(p_linea_ids, 1) IS NULL THEN
            SELECT COALESCE(array_agg(l.id), '{}') INTO p_linea_ids
              FROM agenda_evento_lineas l
             WHERE l.evento_id = p_id AND fn_agenda_linea_estado(l.estado, l.documento_id) = 'pendiente';
        END IF;

        v_n := COALESCE(array_length(p_linea_ids, 1), 0);
        IF v_n = 0 THEN
            RAISE EXCEPTION 'SIN_PENDIENTES: La cita no tiene servicios pendientes de facturar.';
        END IF;

        SELECT COUNT(*) INTO v_validas
          FROM agenda_evento_lineas l
         WHERE l.evento_id = p_id AND l.id = ANY(p_linea_ids)
           AND fn_agenda_linea_estado(l.estado, l.documento_id) = 'pendiente';
        IF v_validas <> v_n THEN
            RAISE EXCEPTION 'LINEA_NO_PENDIENTE: Alguno de los servicios ya fue facturado o cancelado.';
        END IF;

        UPDATE agenda_evento_lineas SET
            estado = 'facturado', documento_id = p_documento_id, updated_at = NOW()
        WHERE evento_id = p_id AND id = ANY(p_linea_ids);

        PERFORM fn_agenda_evento_recalcular(p_id, p_documento_id);
        UPDATE agenda_eventos SET updated_at = NOW() WHERE id = p_id;
        RETURN TRUE;
    END; $$;


--
-- Name: sp_agenda_evento_mover(bigint, bigint, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_mover(p_id bigint, p_empresa_id bigint, p_fecha_inicio timestamp without time zone, p_fecha_fin timestamp without time zone) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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

        IF EXISTS (SELECT 1 FROM agenda_evento_lineas l
                    WHERE l.evento_id = p_id AND fn_agenda_linea_estado(l.estado, l.documento_id) = 'facturado') THEN
            RAISE EXCEPTION 'CITA_BLOQUEADA: La cita tiene servicios facturados; reagende cada servicio pendiente por separado.';
        END IF;

        PERFORM fn_valida_evento_no_pasado(v_fecha_inicio_prev);
        PERFORM fn_valida_horario_sucursal(v_sucursal_id, p_fecha_inicio, p_fecha_fin, v_todo_el_dia);

        v_delta := p_fecha_inicio - v_fecha_inicio_prev;

        FOR v_linea IN
            SELECT funcionario_id,
                   fecha_inicio + v_delta AS nueva_fecha_inicio,
                   fecha_fin + v_delta    AS nueva_fecha_fin
            FROM agenda_evento_lineas WHERE evento_id = p_id AND estado <> 'cancelado'
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
-- Name: sp_agenda_evento_set_estado(bigint, bigint, character varying, text, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_agenda_evento_set_estado(p_id bigint, p_empresa_id bigint, p_estado character varying, p_motivo text DEFAULT NULL::text, p_user_id bigint DEFAULT NULL::bigint, p_user_nombre character varying DEFAULT NULL::character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    DECLARE
        v_fecha_inicio_prev TIMESTAMP;
        v_estado_prev       VARCHAR;
        v_cancelado_at_prev TIMESTAMP;
        v_pend              INTEGER;
    BEGIN
        SELECT fecha_inicio, estado, cancelado_at
          INTO v_fecha_inicio_prev, v_estado_prev, v_cancelado_at_prev
          FROM agenda_eventos
         WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL
         FOR UPDATE;
        IF NOT FOUND THEN
            RETURN FALSE;
        END IF;

        IF p_estado = 'cancelado' THEN
            IF v_estado_prev = 'cancelado' THEN
                RETURN TRUE;
            END IF;
            IF p_motivo IS NULL OR char_length(btrim(p_motivo)) < 3 THEN
                RAISE EXCEPTION 'MOTIVO_REQUERIDO: Indique el motivo de la cancelación.';
            END IF;

            SELECT COUNT(*) INTO v_pend FROM agenda_evento_lineas l
             WHERE l.evento_id = p_id AND fn_agenda_linea_estado(l.estado, l.documento_id) = 'pendiente';
            IF v_pend = 0 THEN
                RAISE EXCEPTION 'SIN_PENDIENTES: La cita no tiene servicios pendientes por cancelar (ya fueron facturados o cancelados).';
            END IF;

            -- Cancela los servicios pendientes (los ya facturados se conservan)
            UPDATE agenda_evento_lineas l SET
                estado = 'cancelado', motivo_cancelacion = btrim(p_motivo),
                cancelado_at = NOW(), cancelado_por = p_user_id, cancelado_por_nombre = p_user_nombre,
                updated_at = NOW()
            WHERE l.evento_id = p_id AND fn_agenda_linea_estado(l.estado, l.documento_id) = 'pendiente';

            PERFORM fn_agenda_evento_recalcular(p_id, NULL, btrim(p_motivo), p_user_id, p_user_nombre);
            RETURN TRUE;
        END IF;

        PERFORM fn_valida_evento_no_pasado(v_fecha_inicio_prev);

        -- Reactivar una cita cancelada: vuelven los servicios que se cancelaron junto con ella
        IF v_estado_prev = 'cancelado' THEN
            UPDATE agenda_evento_lineas SET
                estado = 'pendiente', motivo_cancelacion = NULL, cancelado_at = NULL,
                cancelado_por = NULL, cancelado_por_nombre = NULL, updated_at = NOW()
            WHERE evento_id = p_id AND estado = 'cancelado'
              AND cancelado_at IS NOT DISTINCT FROM v_cancelado_at_prev;
        END IF;

        UPDATE agenda_eventos SET
            estado = p_estado,
            motivo_cancelacion = CASE WHEN v_estado_prev = 'cancelado' THEN NULL ELSE motivo_cancelacion END,
            cancelado_at = CASE WHEN v_estado_prev = 'cancelado' THEN NULL ELSE cancelado_at END,
            cancelado_por = CASE WHEN v_estado_prev = 'cancelado' THEN NULL ELSE cancelado_por END,
            cancelado_por_nombre = CASE WHEN v_estado_prev = 'cancelado' THEN NULL ELSE cancelado_por_nombre END,
            updated_at = NOW()
        WHERE id = p_id;
        RETURN TRUE;
    END; $$;


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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    INSERT INTO bitacora_api (
        user_id, empresa_id, sucursal_id, metodo, endpoint,
        request_headers, request_body, response_status, response_body,
        ip_address, user_agent, duracion_ms
    ) VALUES (
        p_user_id, p_empresa_id, p_sucursal_id, p_metodo, p_endpoint,
        p_request_headers, p_request_body, p_response_status, p_response_body,
        p_ip_address, p_user_agent, p_duracion_ms
    );
END;
$$;


--
-- Name: sp_bitacora_purge(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bitacora_purge(p_dias integer) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_total BIGINT := 0;
    v_lote  BIGINT;
BEGIN
    IF p_dias IS NULL OR p_dias < 1 THEN
        RAISE EXCEPTION 'p_dias debe ser mayor o igual a 1';
    END IF;
    LOOP
        DELETE FROM bitacora_api
        WHERE id IN (
            SELECT id FROM bitacora_api
            WHERE created_at < NOW() - make_interval(days => p_dias)
            LIMIT 5000
        );
        GET DIAGNOSTICS v_lote = ROW_COUNT;
        v_total := v_total + v_lote;
        EXIT WHEN v_lote = 0;
    END LOOP;
    RETURN v_total;
END;
$$;


--
-- Name: sp_bodega_create(bigint, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_create(p_empresa_id bigint, p_name character varying, p_description text DEFAULT NULL::text) RETURNS TABLE(id bigint, name character varying, is_default boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
    AS $$
            DECLARE v_rows INTEGER;
            BEGIN
                UPDATE bodega_productos SET is_active = NOT is_active, updated_at = NOW()
                WHERE bodega_id = p_bodega_id AND producto_id = p_producto_id;
                GET DIAGNOSTICS v_rows = ROW_COUNT; RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_bodega_restore(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_bodega_restore(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
             SELECT mp.tipo_medio_pago, COALESCE(d.moneda, 'CRC') AS moneda,
                    SUM(CASE WHEN d.tipo_documento = '03' THEN -mp.total_medio_pago ELSE mp.total_medio_pago END) AS monto
             FROM documento_medios_pago mp
             JOIN documentos_electronicos d ON d.id = mp.documento_id
             WHERE d.empresa_id  = p_empresa_id
               AND d.caja_id     = p_caja_id
               AND d.fecha_emision > v_fecha_inicio
               AND d.fecha_emision <= v_fecha_fin
               AND d.estado = 'aceptado'
             GROUP BY mp.tipo_medio_pago, COALESCE(d.moneda, 'CRC')
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

CREATE FUNCTION public.sp_client_find(p_id bigint) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, province_code character varying, canton_code character varying, district_code character varying, created_at timestamp without time zone, updated_at timestamp without time zone, dias_credito integer, limite_credito numeric, estado_credito character varying, saldo_pendiente numeric, porcentaje_descuento numeric, saldos_moneda jsonb)
    LANGUAGE sql STABLE
    AS $$
                SELECT c.id, c.name, c.legal_name, c.tax_id_type, c.tax_id, c.email, c.phone, c.address, c.notes,
                       c.birth_date, c.is_active, c.actividad_economica_codigo, c.actividad_economica_descripcion,
                       c.province_code, c.canton_code, c.district_code,
                       c.created_at, c.updated_at,
                       c.dias_credito, c.limite_credito, c.estado_credito,
                       COALESCE((SELECT SUM(cxc.saldo_pendiente) FROM cuentas_por_cobrar cxc
                                 WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')), 0) AS saldo_pendiente,
                       c.porcentaje_descuento,
                       COALESCE((
                           SELECT jsonb_object_agg(m.moneda, m.saldo)
                             FROM (SELECT COALESCE(d.moneda, 'CRC') AS moneda, SUM(cxc.saldo_pendiente) AS saldo
                                     FROM cuentas_por_cobrar cxc
                                     JOIN documentos_electronicos d ON d.id = cxc.documento_id
                                    WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')
                                    GROUP BY COALESCE(d.moneda, 'CRC')
                                   HAVING SUM(cxc.saldo_pendiente) <> 0) m
                       ), '{}'::jsonb) AS saldos_moneda
                FROM clients c WHERE c.id = p_id AND c.deleted_at IS NULL LIMIT 1;
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

CREATE FUNCTION public.sp_client_find_by_tax_id(p_tax_id character varying) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, province_code character varying, canton_code character varying, district_code character varying, created_at timestamp without time zone, updated_at timestamp without time zone, dias_credito integer, limite_credito numeric, estado_credito character varying, saldo_pendiente numeric, porcentaje_descuento numeric, saldos_moneda jsonb)
    LANGUAGE sql STABLE
    AS $$
                SELECT c.id, c.name, c.legal_name, c.tax_id_type, c.tax_id, c.email, c.phone, c.address, c.notes,
                       c.birth_date, c.is_active, c.actividad_economica_codigo, c.actividad_economica_descripcion,
                       c.province_code, c.canton_code, c.district_code,
                       c.created_at, c.updated_at,
                       c.dias_credito, c.limite_credito, c.estado_credito,
                       COALESCE((SELECT SUM(cxc.saldo_pendiente) FROM cuentas_por_cobrar cxc
                                 WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')), 0) AS saldo_pendiente,
                       c.porcentaje_descuento,
                       COALESCE((
                           SELECT jsonb_object_agg(m.moneda, m.saldo)
                             FROM (SELECT COALESCE(d.moneda, 'CRC') AS moneda, SUM(cxc.saldo_pendiente) AS saldo
                                     FROM cuentas_por_cobrar cxc
                                     JOIN documentos_electronicos d ON d.id = cxc.documento_id
                                    WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')
                                    GROUP BY COALESCE(d.moneda, 'CRC')
                                   HAVING SUM(cxc.saldo_pendiente) <> 0) m
                       ), '{}'::jsonb) AS saldos_moneda
                FROM clients c WHERE c.tax_id = p_tax_id AND c.deleted_at IS NULL LIMIT 1;
            $$;


--
-- Name: sp_client_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_client_list(p_empresa_id bigint) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, province_code character varying, canton_code character varying, district_code character varying, created_at timestamp without time zone, updated_at timestamp without time zone, dias_credito integer, limite_credito numeric, estado_credito character varying, saldo_pendiente numeric, porcentaje_descuento numeric, saldos_moneda jsonb)
    LANGUAGE sql STABLE
    AS $$
                SELECT c.id, c.name, c.legal_name, c.tax_id_type, c.tax_id, c.email, c.phone, c.address, c.notes,
                       c.birth_date, c.is_active, c.actividad_economica_codigo, c.actividad_economica_descripcion,
                       c.province_code, c.canton_code, c.district_code,
                       c.created_at, c.updated_at,
                       c.dias_credito, c.limite_credito, c.estado_credito,
                       COALESCE((SELECT SUM(cxc.saldo_pendiente) FROM cuentas_por_cobrar cxc
                                 WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')), 0) AS saldo_pendiente,
                       c.porcentaje_descuento,
                       COALESCE((
                           SELECT jsonb_object_agg(m.moneda, m.saldo)
                             FROM (SELECT COALESCE(d.moneda, 'CRC') AS moneda, SUM(cxc.saldo_pendiente) AS saldo
                                     FROM cuentas_por_cobrar cxc
                                     JOIN documentos_electronicos d ON d.id = cxc.documento_id
                                    WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')
                                    GROUP BY COALESCE(d.moneda, 'CRC')
                                   HAVING SUM(cxc.saldo_pendiente) <> 0) m
                       ), '{}'::jsonb) AS saldos_moneda
                FROM clients c WHERE c.deleted_at IS NULL ORDER BY c.name;
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
    SET search_path TO 'public', 'pg_temp'
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

CREATE FUNCTION public.sp_client_search(p_empresa_id bigint, p_query character varying) RETURNS TABLE(id bigint, name character varying, legal_name character varying, tax_id_type character varying, tax_id character varying, email character varying, phone character varying, address text, notes text, birth_date date, is_active boolean, actividad_economica_codigo character varying, actividad_economica_descripcion character varying, province_code character varying, canton_code character varying, district_code character varying, created_at timestamp without time zone, updated_at timestamp without time zone, dias_credito integer, limite_credito numeric, estado_credito character varying, saldo_pendiente numeric, porcentaje_descuento numeric, saldos_moneda jsonb)
    LANGUAGE sql STABLE
    AS $$
                SELECT c.id, c.name, c.legal_name, c.tax_id_type, c.tax_id, c.email, c.phone, c.address, c.notes,
                       c.birth_date, c.is_active, c.actividad_economica_codigo, c.actividad_economica_descripcion,
                       c.province_code, c.canton_code, c.district_code,
                       c.created_at, c.updated_at,
                       c.dias_credito, c.limite_credito, c.estado_credito,
                       COALESCE((SELECT SUM(cxc.saldo_pendiente) FROM cuentas_por_cobrar cxc
                                 WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')), 0) AS saldo_pendiente,
                       c.porcentaje_descuento,
                       COALESCE((
                           SELECT jsonb_object_agg(m.moneda, m.saldo)
                             FROM (SELECT COALESCE(d.moneda, 'CRC') AS moneda, SUM(cxc.saldo_pendiente) AS saldo
                                     FROM cuentas_por_cobrar cxc
                                     JOIN documentos_electronicos d ON d.id = cxc.documento_id
                                    WHERE cxc.cliente_id = c.id AND cxc.estado IN ('vigente','mora')
                                    GROUP BY COALESCE(d.moneda, 'CRC')
                                   HAVING SUM(cxc.saldo_pendiente) <> 0) m
                       ), '{}'::jsonb) AS saldos_moneda
                FROM clients c WHERE c.deleted_at IS NULL
                  AND (c.name ILIKE '%'||p_query||'%' OR c.tax_id ILIKE '%'||p_query||'%'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
-- Name: sp_cliente_exoneracion_delete(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cliente_exoneracion_delete(p_client_id bigint) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
            DECLARE v_count INTEGER;
            BEGIN
              DELETE FROM cliente_exoneraciones WHERE client_id = p_client_id;
              GET DIAGNOSTICS v_count = ROW_COUNT;
              RETURN v_count > 0;
            END;
            $$;


--
-- Name: sp_cliente_exoneracion_get(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cliente_exoneracion_get(p_client_id bigint) RETURNS TABLE(id bigint, client_id bigint, tipo_documento character varying, tipo_documento_otro character varying, numero_documento character varying, articulo character varying, inciso character varying, nombre_institucion character varying, nombre_institucion_otros character varying, fecha_emision date, fecha_vencimiento date, tarifa_exonerada numeric)
    LANGUAGE plpgsql
    AS $$
            BEGIN
              RETURN QUERY
              SELECT e.id, e.client_id, e.tipo_documento, e.tipo_documento_otro,
                     e.numero_documento, e.articulo, e.inciso,
                     e.nombre_institucion, e.nombre_institucion_otros,
                     e.fecha_emision, e.fecha_vencimiento, e.tarifa_exonerada
              FROM cliente_exoneraciones e
              WHERE e.client_id = p_client_id;
            END;
            $$;


--
-- Name: sp_cliente_exoneracion_save(bigint, character varying, character varying, character varying, character varying, character varying, character varying, character varying, date, date, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cliente_exoneracion_save(p_client_id bigint, p_tipo_documento character varying, p_tipo_documento_otro character varying, p_numero_documento character varying, p_articulo character varying, p_inciso character varying, p_nombre_institucion character varying, p_nombre_institucion_otros character varying, p_fecha_emision date, p_fecha_vencimiento date, p_tarifa_exonerada numeric) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
              INSERT INTO cliente_exoneraciones(
                  client_id, tipo_documento, tipo_documento_otro, numero_documento,
                  articulo, inciso, nombre_institucion, nombre_institucion_otros,
                  fecha_emision, fecha_vencimiento, tarifa_exonerada)
              VALUES (
                  p_client_id, p_tipo_documento, NULLIF(p_tipo_documento_otro, ''), p_numero_documento,
                  NULLIF(p_articulo, ''), NULLIF(p_inciso, ''), p_nombre_institucion,
                  NULLIF(p_nombre_institucion_otros, ''),
                  p_fecha_emision, p_fecha_vencimiento, p_tarifa_exonerada)
              ON CONFLICT (client_id) DO UPDATE SET
                  tipo_documento           = EXCLUDED.tipo_documento,
                  tipo_documento_otro      = EXCLUDED.tipo_documento_otro,
                  numero_documento         = EXCLUDED.numero_documento,
                  articulo                 = EXCLUDED.articulo,
                  inciso                   = EXCLUDED.inciso,
                  nombre_institucion       = EXCLUDED.nombre_institucion,
                  nombre_institucion_otros = EXCLUDED.nombre_institucion_otros,
                  fecha_emision            = EXCLUDED.fecha_emision,
                  fecha_vencimiento        = EXCLUDED.fecha_vencimiento,
                  tarifa_exonerada         = EXCLUDED.tarifa_exonerada,
                  updated_at               = NOW()
              RETURNING cliente_exoneraciones.id INTO v_id;
              RETURN v_id;
            END;
            $$;


--
-- Name: sp_cliente_historial(bigint, bigint, integer, timestamp without time zone, character varying, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cliente_historial(p_cliente_id bigint, p_empresa_id bigint, p_limite integer DEFAULT 30, p_cursor_fecha timestamp without time zone DEFAULT NULL::timestamp without time zone, p_cursor_origen character varying DEFAULT NULL::character varying, p_cursor_id bigint DEFAULT NULL::bigint, p_tipo character varying DEFAULT NULL::character varying) RETURNS TABLE(origen character varying, id bigint, fecha timestamp without time zone, tipo_documento character varying, estado character varying, titulo character varying, descripcion text, monto numeric, clave character varying, numero_consecutivo character varying)
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_column
DECLARE
    v_limite integer := LEAST(GREATEST(COALESCE(p_limite, 30), 1), 200);
BEGIN
    RETURN QUERY
    SELECT h.origen, h.id, h.fecha, h.tipo_documento, h.estado, h.titulo,
           h.descripcion, h.monto, h.clave, h.numero_consecutivo
    FROM (
        (SELECT
            'documento'::VARCHAR          AS origen,
            d.id::BIGINT                  AS id,
            d.fecha_emision               AS fecha,
            d.tipo_documento::VARCHAR     AS tipo_documento,
            d.estado::VARCHAR             AS estado,
            d.numero_consecutivo::VARCHAR AS titulo,
            NULL::TEXT                    AS descripcion,
            d.total_comprobante::NUMERIC  AS monto,
            d.clave::VARCHAR              AS clave,
            d.numero_consecutivo::VARCHAR AS numero_consecutivo
         FROM documentos_electronicos d
         WHERE (p_tipo IS NULL OR p_tipo = 'documento')
           AND d.receptor_cliente_id = p_cliente_id
           AND d.empresa_id = p_empresa_id
           AND d.deleted_at IS NULL
           AND (p_cursor_fecha IS NULL
                OR (d.fecha_emision <= p_cursor_fecha
                    AND (d.fecha_emision, 'documento'::VARCHAR, d.id) < (p_cursor_fecha, p_cursor_origen, p_cursor_id)))
         ORDER BY d.fecha_emision DESC, d.id DESC
         LIMIT v_limite + 1)

        UNION ALL

        (SELECT
            'agenda'::VARCHAR,
            e.id::BIGINT,
            e.fecha_inicio,
            NULL::VARCHAR,
            e.estado::VARCHAR,
            e.titulo::VARCHAR,
            ('Creada el ' || to_char(e.created_at, 'DD/MM/YYYY HH24:MI'))::TEXT,
            NULL::NUMERIC,
            NULL::VARCHAR,
            NULL::VARCHAR
         FROM agenda_eventos e
         WHERE (p_tipo IS NULL OR p_tipo = 'agenda')
           AND e.cliente_id = p_cliente_id
           AND e.empresa_id = p_empresa_id
           AND e.deleted_at IS NULL
           AND (p_cursor_fecha IS NULL
                OR (e.fecha_inicio <= p_cursor_fecha
                    AND (e.fecha_inicio, 'agenda'::VARCHAR, e.id) < (p_cursor_fecha, p_cursor_origen, p_cursor_id)))
         ORDER BY e.fecha_inicio DESC, e.id DESC
         LIMIT v_limite + 1)

        UNION ALL

        (SELECT
            'cotizacion'::VARCHAR,
            c.id::BIGINT,
            c.aprobado_at,
            NULL::VARCHAR,
            c.estado::VARCHAR,
            c.numero::VARCHAR,
            NULL::TEXT,
            c.total_comprobante::NUMERIC,
            NULL::VARCHAR,
            c.numero::VARCHAR
         FROM cotizaciones c
         WHERE (p_tipo IS NULL OR p_tipo = 'cotizacion')
           AND c.receptor_cliente_id = p_cliente_id
           AND c.empresa_id = p_empresa_id
           AND c.deleted_at IS NULL
           AND c.aprobado_at IS NOT NULL
           AND c.estado IN ('aprobada','convertida','convertida_parcial')
           AND (p_cursor_fecha IS NULL
                OR (c.aprobado_at <= p_cursor_fecha
                    AND (c.aprobado_at, 'cotizacion'::VARCHAR, c.id) < (p_cursor_fecha, p_cursor_origen, p_cursor_id)))
         ORDER BY c.aprobado_at DESC, c.id DESC
         LIMIT v_limite + 1)

        UNION ALL

        -- Citas modificadas / eliminadas (desde la auditoría)
        (SELECT
            o.origen,
            a.id::BIGINT,
            a.created_at,
            NULL::VARCHAR,
            COALESCE(a.datos_despues->>'estado', a.datos_antes->>'estado')::VARCHAR,
            COALESCE(a.datos_despues->>'titulo', a.datos_antes->>'titulo')::VARCHAR,
            (CASE
                WHEN o.origen = 'agenda_eliminada'
                THEN 'Fecha de la cita: ' || to_char((a.datos_antes->>'fecha_inicio')::timestamp, 'DD/MM/YYYY HH24:MI')
                ELSE COALESCE(
                    NULLIF(array_to_string(ARRAY[
                        CASE WHEN a.datos_antes->>'titulo' IS DISTINCT FROM a.datos_despues->>'titulo'
                             THEN 'Título: ' || (a.datos_antes->>'titulo') || ' → ' || (a.datos_despues->>'titulo') END,
                        CASE WHEN a.datos_antes->>'fecha_inicio' IS DISTINCT FROM a.datos_despues->>'fecha_inicio'
                               OR a.datos_antes->>'fecha_fin' IS DISTINCT FROM a.datos_despues->>'fecha_fin'
                             THEN 'Fecha: '
                                  || to_char((a.datos_antes->>'fecha_inicio')::timestamp, 'DD/MM/YYYY HH24:MI')
                                  || ' → '
                                  || to_char((a.datos_despues->>'fecha_inicio')::timestamp, 'DD/MM/YYYY HH24:MI') END,
                        CASE WHEN a.datos_antes->>'estado' IS DISTINCT FROM a.datos_despues->>'estado'
                             THEN 'Estado: ' || (a.datos_antes->>'estado') || ' → ' || (a.datos_despues->>'estado') END,
                        CASE WHEN a.datos_antes->>'cliente_id' IS DISTINCT FROM a.datos_despues->>'cliente_id'
                             THEN 'Cliente reasignado' END,
                        CASE WHEN a.datos_antes->>'documento_id' IS DISTINCT FROM a.datos_despues->>'documento_id'
                             THEN 'Cita facturada' END
                    ], '; '), ''),
                    'Se modificaron los servicios o detalles de la cita'
                )
             END)::TEXT,
            NULL::NUMERIC,
            NULL::VARCHAR,
            NULL::VARCHAR
         FROM agenda_eventos_auditoria a
         CROSS JOIN LATERAL (
             SELECT (CASE WHEN a.operacion = 'DELETE' OR (a.datos_despues->>'deleted_at') IS NOT NULL
                          THEN 'agenda_eliminada' ELSE 'agenda_modificada' END)::VARCHAR AS origen
         ) o
         WHERE (p_tipo IS NULL OR p_tipo = 'agenda')
           AND a.operacion IN ('UPDATE', 'DELETE')
           AND ((a.datos_despues->>'cliente_id')::BIGINT = p_cliente_id
                OR (a.datos_antes->>'cliente_id')::BIGINT = p_cliente_id)
           AND COALESCE(a.datos_despues->>'empresa_id', a.datos_antes->>'empresa_id')::BIGINT = p_empresa_id
           -- una cita ya eliminada que se vuelve a tocar no es un cambio nuevo
           AND (a.datos_antes->>'deleted_at') IS NULL
           AND (p_cursor_fecha IS NULL
                OR (a.created_at <= p_cursor_fecha
                    AND (a.created_at, o.origen, a.id) < (p_cursor_fecha, p_cursor_origen, p_cursor_id)))
         ORDER BY a.created_at DESC, o.origen DESC, a.id DESC
         LIMIT v_limite + 1)
    ) h
    ORDER BY h.fecha DESC, h.origen DESC, h.id DESC
    LIMIT v_limite + 1;
END;
$$;


--
-- Name: sp_cliente_resumen(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_cliente_resumen(p_cliente_id bigint, p_empresa_id bigint) RETURNS TABLE(total_citas bigint, citas_completadas bigint, citas_canceladas bigint, citas_pendientes bigint, total_facturas bigint, total_facturado numeric, total_facturado_moneda json, total_notas_credito bigint, top_servicios json, top_productos json, top_funcionarios json)
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
        (SELECT COALESCE(SUM(CASE WHEN d.tipo_documento = '03' THEN -d.total_comprobante ELSE d.total_comprobante END), 0)
           FROM documentos_electronicos d
           WHERE d.receptor_cliente_id = p_cliente_id AND d.empresa_id = p_empresa_id AND d.deleted_at IS NULL
             AND d.tipo_documento IN ('01','02','03','04','09') AND d.estado = 'aceptado'),
        (SELECT COALESCE(json_object_agg(t.moneda, t.total), '{}'::json) FROM (
            SELECT COALESCE(d.moneda, 'CRC') AS moneda,
                   SUM(CASE WHEN d.tipo_documento = '03' THEN -d.total_comprobante ELSE d.total_comprobante END) AS total
            FROM documentos_electronicos d
            WHERE d.receptor_cliente_id = p_cliente_id AND d.empresa_id = p_empresa_id AND d.deleted_at IS NULL
              AND d.tipo_documento IN ('01','02','03','04','09') AND d.estado = 'aceptado'
            GROUP BY COALESCE(d.moneda, 'CRC')
        ) t),
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
            SELECT p.id, p.name, SUM(CASE WHEN d.tipo_documento = '03' THEN -dl.cantidad ELSE dl.cantidad END) AS cantidad
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

CREATE FUNCTION public.sp_clientes_con_adelantos(p_empresa_id bigint) RETURNS TABLE(cliente_id bigint, nombre character varying, tax_id character varying, tax_id_type character varying, correo character varying, cantidad_recibos bigint, saldo_disponible numeric, moneda character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
            BEGIN
                RETURN QUERY
                SELECT c.id,
                       c.name,
                       c.tax_id,
                       c.tax_id_type,
                       c.email,
                       COUNT(ra.id),
                       COALESCE(SUM(ra.saldo_disponible), 0),
                       ra.moneda::VARCHAR
                FROM recibos_adelanto ra
                JOIN clients c ON c.id = ra.cliente_id
                WHERE ra.empresa_id = p_empresa_id
                  AND ra.estado = 'disponible'
                  AND ra.saldo_disponible > 0
                GROUP BY c.id, c.name, c.tax_id, c.tax_id_type, c.email, ra.moneda
                ORDER BY c.name, ra.moneda;
            END; $$;


--
-- Name: sp_company_impresion_get(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_company_impresion_get(p_empresa_id bigint) RETURNS TABLE(formato_impresion_factura character varying, formato_impresion_tiquete character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            BEGIN
                RETURN QUERY
                SELECT cs.formato_impresion_factura, cs.formato_impresion_tiquete
                FROM company_settings cs
                WHERE cs.empresa_id = p_empresa_id AND cs.deleted_at IS NULL
                LIMIT 1;
            END; $$;


--
-- Name: sp_company_impresion_save(bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_company_impresion_save(p_empresa_id bigint, p_factura character varying, p_tiquete character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
            DECLARE v_rows INT;
            BEGIN
                UPDATE company_settings SET
                    formato_impresion_factura = p_factura,
                    formato_impresion_tiquete = p_tiquete,
                    updated_at = NOW()
                WHERE empresa_id = p_empresa_id AND deleted_at IS NULL;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                RETURN v_rows > 0;
            END; $$;


--
-- Name: sp_company_settings_get(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_company_settings_get(p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, legal_name character varying, commercial_name character varying, tax_id character varying, tax_id_type character varying, actividad_economica character varying, leyenda_tributaria text, hacienda_environment character varying, has_hacienda_credentials boolean, has_certificate boolean, certificate_subject text, certificate_issuer text, certificate_serial character varying, certificate_valid_from timestamp without time zone, certificate_valid_to timestamp without time zone, certificate_tax_id character varying, certificate_validated_at timestamp without time zone, hacienda_token_tested_at timestamp without time zone, hacienda_token_expires_at timestamp without time zone, validation_status character varying, validation_errors jsonb, is_active boolean, updated_at timestamp without time zone, clients_managed_by_central boolean, has_onvo_card boolean, onvo_customer_id character varying, onvo_payment_method_id character varying, onvo_card_brand character varying, onvo_card_last4 character varying, onvo_card_exp_month smallint, onvo_card_exp_year smallint, logo_url text, logo_public_id text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT cs.id, cs.empresa_id, cs.legal_name, cs.commercial_name,
           cs.tax_id, cs.tax_id_type,
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
-- Name: sp_company_settings_save(bigint, character varying, character varying, character varying, character varying, character varying, text, character varying, text, text, text, text, text, text, character varying, timestamp without time zone, timestamp without time zone, character varying, timestamp without time zone, timestamp without time zone, timestamp without time zone, character varying, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_company_settings_save(p_empresa_id bigint, p_legal_name character varying, p_commercial_name character varying, p_tax_id character varying, p_tax_id_type character varying, p_actividad_economica character varying, p_leyenda_tributaria text, p_hacienda_environment character varying, p_hacienda_username_encrypted text, p_hacienda_password_encrypted text, p_certificate_p12_encrypted text, p_certificate_password_encrypted text, p_certificate_subject text, p_certificate_issuer text, p_certificate_serial character varying, p_certificate_valid_from timestamp without time zone, p_certificate_valid_to timestamp without time zone, p_certificate_tax_id character varying, p_certificate_validated_at timestamp without time zone, p_hacienda_token_tested_at timestamp without time zone, p_hacienda_token_expires_at timestamp without time zone, p_validation_status character varying, p_validation_errors jsonb, p_logo_url text DEFAULT NULL::text, p_logo_public_id text DEFAULT NULL::text) RETURNS TABLE(id bigint, validation_status character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  RETURN QUERY
  INSERT INTO company_settings (
    empresa_id, legal_name, commercial_name, tax_id, tax_id_type,
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
DECLARE
    v_rows INT;
BEGIN
    UPDATE documento_consecutivos
    SET ultimo_consecutivo = p_nuevo_valor,
        updated_at         = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows > 0;
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
    SET search_path TO 'public', 'pg_temp'
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
-- Name: sp_doc_adjunto_create(bigint, character varying, bigint, character varying, character varying, bigint, character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_doc_adjunto_create(p_empresa_id bigint, p_entidad character varying, p_entidad_id bigint, p_nombre character varying, p_clave character varying, p_tamano bigint, p_sha256 character varying, p_user_id bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO documentos_adjuntos (empresa_id, entidad, entidad_id, nombre, clave, tamano_bytes, sha256, created_by)
    VALUES (p_empresa_id, p_entidad, p_entidad_id, p_nombre, p_clave, p_tamano, p_sha256, p_user_id)
    RETURNING documentos_adjuntos.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_doc_adjunto_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_doc_adjunto_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, entidad character varying, entidad_id bigint, nombre character varying, clave character varying, tamano_bytes bigint, created_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT d.id, d.entidad, d.entidad_id, d.nombre, d.clave, d.tamano_bytes, d.created_at
    FROM documentos_adjuntos d
    WHERE d.id = p_id AND d.empresa_id = p_empresa_id AND d.deleted_at IS NULL;
END; $$;


--
-- Name: sp_doc_adjunto_list(bigint, character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_doc_adjunto_list(p_empresa_id bigint, p_entidad character varying, p_entidad_id bigint) RETURNS TABLE(id bigint, entidad character varying, entidad_id bigint, nombre character varying, tamano_bytes bigint, created_by bigint, created_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT d.id, d.entidad, d.entidad_id, d.nombre, d.tamano_bytes, d.created_by, d.created_at
    FROM documentos_adjuntos d
    WHERE d.empresa_id = p_empresa_id AND d.entidad = p_entidad AND d.entidad_id = p_entidad_id
      AND d.deleted_at IS NULL
    ORDER BY d.id DESC;
END; $$;


--
-- Name: sp_doc_adjunto_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_doc_adjunto_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE documentos_adjuntos SET deleted_at = NOW(), updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_documento_ajustar_inventario(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_documento_ajustar_inventario(p_documento_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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

                SELECT id, empresa_id, tipo_documento, clave, numero_consecutivo, user_id, afecta_inventario
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

                IF v_tipo_mov IS NULL OR (v_doc.tipo_documento = '02' AND NOT COALESCE(v_doc.afecta_inventario, TRUE)) THEN
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
    postproceso_error text,
    afecta_inventario boolean DEFAULT true NOT NULL,
    CONSTRAINT chk_doc_estado CHECK (((estado)::text = ANY (ARRAY['borrador'::text, 'procesando'::text, 'aceptado'::text, 'rechazado'::text, 'error'::text, 'pendiente_manual'::text]))),
    CONSTRAINT documentos_electronicos_estado_check CHECK (((estado)::text = ANY (ARRAY[('borrador'::character varying)::text, ('procesando'::character varying)::text, ('aceptado'::character varying)::text, ('rechazado'::character varying)::text, ('anulado'::character varying)::text, ('error'::character varying)::text, ('pendiente_manual'::character varying)::text])))
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
DECLARE
    v_total BIGINT;
BEGIN
    -- El total se cuenta aparte: COUNT(*) OVER() obliga a ordenar todo el conjunto antes de devolver la página.
    SELECT COUNT(*) INTO v_total
    FROM documentos_electronicos d
    WHERE d.empresa_id = p_empresa_id
      AND d.deleted_at IS NULL
      AND (p_tipo_documento IS NULL OR d.tipo_documento = p_tipo_documento)
      AND (p_estado IS NULL OR d.estado = p_estado)
      AND (p_fecha_desde IS NULL OR d.fecha_emision >= p_fecha_desde)
      AND (p_fecha_hasta IS NULL OR d.fecha_emision < p_fecha_hasta + 1)
      AND (p_search IS NULL
           OR d.clave ILIKE '%' || p_search || '%'
           OR d.receptor_nombre ILIKE '%' || p_search || '%'
           OR d.receptor_numero_id ILIKE '%' || p_search || '%'
           OR d.numero_consecutivo ILIKE '%' || p_search || '%');

    RETURN QUERY
    SELECT
        d.id, d.tipo_documento, d.clave, d.numero_consecutivo,
        d.fecha_emision, d.receptor_nombre, d.receptor_numero_id,
        d.moneda, d.total_comprobante, d.estado, d.aceptado_at,
        d.created_at, d.condicion_venta, d.receptor_cliente_id,
        v_total
    FROM documentos_electronicos d
    WHERE d.empresa_id = p_empresa_id
      AND d.deleted_at IS NULL
      AND (p_tipo_documento IS NULL OR d.tipo_documento = p_tipo_documento)
      AND (p_estado IS NULL OR d.estado = p_estado)
      AND (p_fecha_desde IS NULL OR d.fecha_emision >= p_fecha_desde)
      AND (p_fecha_hasta IS NULL OR d.fecha_emision < p_fecha_hasta + 1)
      AND (p_search IS NULL
           OR d.clave ILIKE '%' || p_search || '%'
           OR d.receptor_nombre ILIKE '%' || p_search || '%'
           OR d.receptor_numero_id ILIKE '%' || p_search || '%'
           OR d.numero_consecutivo ILIKE '%' || p_search || '%')
    ORDER BY d.created_at DESC, d.id DESC
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
    AS $$
            DECLARE
                v_cxc            RECORD;
                v_ad             RECORD;
                v_moneda         VARCHAR;
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

                SELECT COALESCE(NULLIF(moneda, ''), 'CRC') INTO v_moneda
                FROM documentos_electronicos WHERE id = p_documento_id;
                v_moneda := COALESCE(v_moneda, 'CRC');

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
                      AND moneda = v_moneda
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
    AS $$
            DECLARE
                v_total BIGINT;
            BEGIN
                -- Total aparte (los LEFT JOIN no cambian el conteo): evita ordenar todo el kardex para contarlo.
                SELECT COUNT(*) INTO v_total
                FROM movimientos_inventario m
                WHERE m.empresa_id       = p_empresa_id
                  AND (p_producto_id IS NULL OR m.producto_id      = p_producto_id)
                  AND (p_bodega_id   IS NULL OR m.bodega_origen_id = p_bodega_id)
                  AND (p_fecha_desde IS NULL OR m.created_at >= p_fecha_desde)
                  AND (p_fecha_hasta IS NULL OR m.created_at < p_fecha_hasta + 1);

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
                    v_total AS total_rows
                FROM movimientos_inventario m
                LEFT JOIN productos p ON p.id = m.producto_id
                LEFT JOIN bodegas   bo ON bo.id = m.bodega_origen_id
                LEFT JOIN bodegas   bd ON bd.id = m.bodega_destino_id
                WHERE m.empresa_id       = p_empresa_id
                  AND (p_producto_id IS NULL OR m.producto_id      = p_producto_id)
                  AND (p_bodega_id   IS NULL OR m.bodega_origen_id = p_bodega_id)
                  AND (p_fecha_desde IS NULL OR m.created_at >= p_fecha_desde)
                  AND (p_fecha_hasta IS NULL OR m.created_at < p_fecha_hasta + 1)
                ORDER BY m.created_at DESC, m.id DESC
                LIMIT GREATEST(p_per_page, 1) OFFSET GREATEST(p_page - 1, 0) * GREATEST(p_per_page, 1);
            END;
            $$;


--
-- Name: sp_inventario_kardex_totales(bigint, bigint, bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_inventario_kardex_totales(p_empresa_id bigint, p_producto_id bigint DEFAULT NULL::bigint, p_bodega_id bigint DEFAULT NULL::bigint, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date) RETURNS TABLE(total_movimientos bigint, total_entrada numeric, total_salida numeric, stock_actual numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    WITH f AS (
        SELECT
            m.id,
            m.created_at,
            m.stock_despues,
            CASE WHEN m.tipo IN ('entrada','devolucion')
                   OR (m.tipo = 'ajuste'   AND m.stock_despues >= m.stock_antes)
                   OR (m.tipo = 'traslado' AND m.stock_despues >  m.stock_antes)
                 THEN m.cantidad ELSE 0 END AS entrada,
            CASE WHEN m.tipo IN ('salida','venta','danio')
                   OR (m.tipo = 'ajuste'   AND m.stock_despues < m.stock_antes)
                   OR (m.tipo = 'traslado' AND m.stock_despues <= m.stock_antes)
                 THEN m.cantidad ELSE 0 END AS salida
        FROM movimientos_inventario m
        WHERE m.empresa_id       = p_empresa_id
          AND (p_producto_id IS NULL OR m.producto_id      = p_producto_id)
          AND (p_bodega_id   IS NULL OR m.bodega_origen_id = p_bodega_id)
          AND (p_fecha_desde IS NULL OR m.created_at >= p_fecha_desde)
          AND (p_fecha_hasta IS NULL OR m.created_at < p_fecha_hasta + 1)
    )
    SELECT
        COUNT(*)::BIGINT,
        COALESCE(SUM(f.entrada), 0)::NUMERIC,
        COALESCE(SUM(f.salida),  0)::NUMERIC,
        CASE WHEN p_producto_id IS NOT NULL AND p_bodega_id IS NOT NULL
             THEN (SELECT x.stock_despues FROM f x ORDER BY x.created_at DESC, x.id DESC LIMIT 1)
             ELSE NULL END
    FROM f;
END;
$$;


--
-- Name: sp_inventario_movimientos(bigint, bigint, bigint, character varying, date, date, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_inventario_movimientos(p_empresa_id bigint, p_bodega_id bigint DEFAULT NULL::bigint, p_producto_id bigint DEFAULT NULL::bigint, p_tipo character varying DEFAULT NULL::character varying, p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0) RETURNS TABLE(id bigint, fecha timestamp without time zone, tipo character varying, bodega_origen character varying, bodega_destino character varying, producto_codigo character varying, producto_nombre character varying, cantidad numeric, stock_antes numeric, stock_despues numeric, precio_base numeric, monto_total numeric, referencia character varying, notas text, documento_id bigint, user_id bigint, proveedor_nombre character varying, total_count bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
            DECLARE
                v_total BIGINT;
            BEGIN
                -- Total aparte; los JOIN internos sí afectan el conteo y se conservan.
                SELECT COUNT(*) INTO v_total
                FROM movimientos_inventario m
                JOIN bodegas bo  ON bo.id = m.bodega_origen_id
                JOIN productos p ON p.id = m.producto_id
                WHERE m.empresa_id = p_empresa_id
                  AND (p_bodega_id   IS NULL OR m.bodega_origen_id = p_bodega_id)
                  AND (p_producto_id IS NULL OR m.producto_id      = p_producto_id)
                  AND (p_tipo        IS NULL OR m.tipo             = p_tipo)
                  AND (p_fecha_desde IS NULL OR m.created_at >= p_fecha_desde)
                  AND (p_fecha_hasta IS NULL OR m.created_at < p_fecha_hasta + 1);

                RETURN QUERY
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
                    v_total AS total_count
                FROM movimientos_inventario m
                JOIN bodegas bo  ON bo.id = m.bodega_origen_id
                LEFT JOIN bodegas bd ON bd.id = m.bodega_destino_id
                JOIN productos p ON p.id = m.producto_id
                LEFT JOIN proveedores prov ON prov.id = m.proveedor_id
                WHERE m.empresa_id = p_empresa_id
                  AND (p_bodega_id   IS NULL OR m.bodega_origen_id = p_bodega_id)
                  AND (p_producto_id IS NULL OR m.producto_id      = p_producto_id)
                  AND (p_tipo        IS NULL OR m.tipo             = p_tipo)
                  AND (p_fecha_desde IS NULL OR m.created_at >= p_fecha_desde)
                  AND (p_fecha_hasta IS NULL OR m.created_at < p_fecha_hasta + 1)
                ORDER BY m.created_at DESC, m.id DESC
                LIMIT p_limit OFFSET p_offset;
            END;
            $$;


--
-- Name: sp_inventario_registrar_desde_documento(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_inventario_registrar_desde_documento(p_documento_id bigint, p_user_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
-- Name: sp_mercadeo_imagen_create(bigint, character varying, character varying, character varying, integer, integer, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_imagen_create(p_empresa_id bigint, p_nombre character varying, p_clave character varying, p_mime character varying, p_ancho integer, p_alto integer, p_tamano bigint, p_user_id bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO mercadeo_imagenes (empresa_id, nombre, clave, mime, ancho, alto, tamano_bytes, created_by)
    VALUES (p_empresa_id, p_nombre, p_clave, p_mime, p_ancho, p_alto, p_tamano, p_user_id)
    RETURNING mercadeo_imagenes.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_mercadeo_imagen_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_imagen_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, nombre character varying, clave character varying, mime character varying, ancho integer, alto integer, tamano_bytes bigint, created_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT i.id, i.nombre, i.clave, i.mime, i.ancho, i.alto, i.tamano_bytes, i.created_at
    FROM mercadeo_imagenes i
    WHERE i.id = p_id AND i.empresa_id = p_empresa_id AND i.deleted_at IS NULL;
END; $$;


--
-- Name: sp_mercadeo_imagen_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_imagen_list(p_empresa_id bigint) RETURNS TABLE(id bigint, nombre character varying, clave character varying, mime character varying, ancho integer, alto integer, tamano_bytes bigint, created_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT i.id, i.nombre, i.clave, i.mime, i.ancho, i.alto, i.tamano_bytes, i.created_at
    FROM mercadeo_imagenes i
    WHERE i.empresa_id = p_empresa_id AND i.deleted_at IS NULL
    ORDER BY i.id DESC
    LIMIT 500;
END; $$;


--
-- Name: sp_mercadeo_imagen_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_imagen_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE mercadeo_imagenes SET deleted_at = NOW(), updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_mercadeo_imagen_usos(bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_imagen_usos(p_empresa_id bigint, p_clave character varying) RETURNS TABLE(plantilla_id bigint, nombre character varying, eliminada boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT p.id, p.nombre, (p.deleted_at IS NOT NULL)
    FROM mercadeo_plantillas p
    WHERE p.empresa_id = p_empresa_id
      AND position(p_clave in COALESCE(p.contenido_html, '')) > 0
      AND (p.deleted_at IS NULL
           OR EXISTS (SELECT 1 FROM mercadeo_campanas c WHERE c.plantilla_id = p.id))
    ORDER BY p.nombre
    LIMIT 20;
END; $$;


--
-- Name: sp_mercadeo_plantilla_create(bigint, character varying, character varying, character varying, character varying, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_mercadeo_plantilla_create(p_empresa_id bigint, p_categoria character varying, p_canal character varying, p_nombre character varying, p_asunto character varying, p_contenido_html text, p_contenido_texto text, p_variables_usadas jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
-- Name: sp_producto_alertas_stock(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_producto_alertas_stock(p_empresa_id bigint, p_bodega_id bigint) RETURNS TABLE(total_negativos bigint, total_bajos bigint, nombres_negativos text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT p.name, bp.stock, bp.stock_min
        FROM bodega_productos bp
        JOIN productos p ON p.id = bp.producto_id
        WHERE p.empresa_id = p_empresa_id
          AND bp.bodega_id = p_bodega_id
          AND p.deleted_at IS NULL
          AND p.is_active
          AND bp.is_active
          AND COALESCE(p.type, '') <> 'service'
          AND bp.stock IS NOT NULL
    )
    SELECT
        (SELECT COUNT(*) FROM base WHERE stock < 0)::BIGINT,
        (SELECT COUNT(*) FROM base WHERE stock >= 0 AND COALESCE(stock_min, 0) > 0 AND stock <= stock_min)::BIGINT,
        (SELECT COALESCE(jsonb_agg(n.name), '[]'::jsonb)::TEXT
           FROM (SELECT b.name FROM base b WHERE b.stock < 0 ORDER BY b.name LIMIT 3) n);
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
-- Name: sp_proveedor_historial(bigint, bigint, integer, timestamp without time zone, character varying, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_historial(p_proveedor_id bigint, p_empresa_id bigint, p_limite integer DEFAULT 30, p_cursor_fecha timestamp without time zone DEFAULT NULL::timestamp without time zone, p_cursor_origen character varying DEFAULT NULL::character varying, p_cursor_id bigint DEFAULT NULL::bigint, p_tipo character varying DEFAULT NULL::character varying) RETURNS TABLE(origen character varying, id bigint, fecha timestamp without time zone, tipo_documento character varying, estado character varying, titulo character varying, descripcion text, monto numeric, moneda character varying, clave character varying, numero_consecutivo character varying)
    LANGUAGE plpgsql
    AS $$
#variable_conflict use_column
DECLARE
    v_tax_id character varying;
    v_limite integer := LEAST(GREATEST(COALESCE(p_limite, 30), 1), 200);
BEGIN
    SELECT p.tax_id INTO v_tax_id
    FROM proveedores p
    WHERE p.id = p_proveedor_id AND p.empresa_id = p_empresa_id;

    RETURN QUERY
    SELECT h.origen, h.id, h.fecha, h.tipo_documento, h.estado, h.titulo,
           h.descripcion, h.monto, h.moneda, h.clave, h.numero_consecutivo
    FROM (
        (SELECT
            'factura_recibida'::VARCHAR                       AS origen,
            fr.id::BIGINT                                     AS id,
            COALESCE(fr.fecha_emision, fr.created_at)         AS fecha,
            fr.tipo_documento::VARCHAR                        AS tipo_documento,
            fr.estado_recepcion::VARCHAR                      AS estado,
            (CASE fr.tipo_documento
                WHEN '01' THEN 'Factura Electrónica'
                WHEN '02' THEN 'Nota de Débito'
                WHEN '03' THEN 'Nota de Crédito'
                WHEN '04' THEN 'Tiquete Electrónico'
                WHEN '08' THEN 'Factura de Compra'
                WHEN '09' THEN 'Factura de Exportación'
                WHEN '10' THEN 'Recibo de Pago'
                ELSE 'Comprobante recibido'
             END)::VARCHAR                                    AS titulo,
            (CASE WHEN fr.condicion_pago = 'credito'
                  THEN 'Crédito' || CASE WHEN fr.monto_pagado >= fr.total_comprobante
                                         THEN ' · pagada' ELSE ' · con saldo pendiente' END
                  ELSE 'Contado'
             END)::TEXT                                       AS descripcion,
            fr.total_comprobante::NUMERIC                     AS monto,
            COALESCE(fr.moneda, 'CRC')::VARCHAR               AS moneda,
            fr.clave::VARCHAR                                 AS clave,
            fr.numero_consecutivo_emisor::VARCHAR             AS numero_consecutivo
         FROM facturas_recibidas fr
         WHERE (p_tipo IS NULL OR p_tipo = 'factura_recibida')
           AND fr.empresa_id = p_empresa_id
           AND (fr.proveedor_id = p_proveedor_id
                OR (v_tax_id IS NOT NULL AND fr.emisor_numero_id = v_tax_id))
           AND (p_cursor_fecha IS NULL
                OR (COALESCE(fr.fecha_emision, fr.created_at) <= p_cursor_fecha
                    AND (COALESCE(fr.fecha_emision, fr.created_at), 'factura_recibida'::VARCHAR, fr.id::BIGINT)
                        < (p_cursor_fecha, p_cursor_origen, p_cursor_id)))
         ORDER BY COALESCE(fr.fecha_emision, fr.created_at) DESC, fr.id DESC
         LIMIT v_limite + 1)

        UNION ALL

        (SELECT
            'orden_pedido'::VARCHAR,
            o.id::BIGINT,
            o.fecha,
            NULL::VARCHAR,
            o.estado::VARCHAR,
            ('Orden de pedido ' || o.numero)::VARCHAR,
            o.notas::TEXT,
            (SELECT COALESCE(SUM(COALESCE(NULLIF(l->>'subtotal','')::NUMERIC,
                                          COALESCE(NULLIF(l->>'cantidad','')::NUMERIC, 0)
                                        * COALESCE(NULLIF(l->>'precio_unitario','')::NUMERIC, 0))), 0)
               FROM jsonb_array_elements(o.lineas) l)::NUMERIC,
            COALESCE(o.moneda, 'CRC')::VARCHAR,
            NULL::VARCHAR,
            o.numero::VARCHAR
         FROM ordenes_pedido o
         WHERE (p_tipo IS NULL OR p_tipo = 'orden_pedido')
           AND o.empresa_id = p_empresa_id
           AND o.proveedor_id = p_proveedor_id
           AND o.deleted_at IS NULL
           AND (p_cursor_fecha IS NULL
                OR (o.fecha <= p_cursor_fecha
                    AND (o.fecha, 'orden_pedido'::VARCHAR, o.id::BIGINT) < (p_cursor_fecha, p_cursor_origen, p_cursor_id)))
         ORDER BY o.fecha DESC, o.id DESC
         LIMIT v_limite + 1)
    ) h
    ORDER BY h.fecha DESC, h.origen DESC, h.id DESC
    LIMIT v_limite + 1;
END;
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
    SET search_path TO 'public', 'pg_temp'
    AS $$
            BEGIN
                UPDATE proveedores
                SET deleted_at = NULL, is_active = TRUE, updated_at = NOW()
                WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NOT NULL;
                RETURN FOUND;
            END;
            $$;


--
-- Name: sp_proveedor_resumen(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_proveedor_resumen(p_proveedor_id bigint, p_empresa_id bigint) RETURNS TABLE(total_facturas bigint, total_notas_credito bigint, total_ordenes bigint, ordenes_abiertas bigint, primera_compra timestamp without time zone, ultima_compra timestamp without time zone, totales_moneda json, top_productos json)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_tax_id character varying;
BEGIN
    SELECT p.tax_id INTO v_tax_id
    FROM proveedores p
    WHERE p.id = p_proveedor_id AND p.empresa_id = p_empresa_id;

    RETURN QUERY
    WITH fr AS (
        SELECT f.*
        FROM facturas_recibidas f
        WHERE f.empresa_id = p_empresa_id
          AND (f.proveedor_id = p_proveedor_id
               OR (v_tax_id IS NOT NULL AND f.emisor_numero_id = v_tax_id))
          AND COALESCE(f.estado_recepcion, 'pendiente') <> 'rechazado'
    ),
    compras AS (
        -- Compras reales: sin notas de crédito ni recibos de pago
        SELECT * FROM fr WHERE COALESCE(fr.tipo_documento, '01') NOT IN ('03', '10')
    )
    SELECT
        (SELECT COUNT(*) FROM compras),
        (SELECT COUNT(*) FROM fr WHERE fr.tipo_documento = '03'),
        (SELECT COUNT(*) FROM ordenes_pedido o
          WHERE o.empresa_id = p_empresa_id AND o.proveedor_id = p_proveedor_id
            AND o.deleted_at IS NULL AND o.estado <> 'cancelada'),
        (SELECT COUNT(*) FROM ordenes_pedido o
          WHERE o.empresa_id = p_empresa_id AND o.proveedor_id = p_proveedor_id
            AND o.deleted_at IS NULL AND o.estado IN ('enviada', 'recibida_parcial')),
        (SELECT MIN(COALESCE(c.fecha_emision, c.created_at)) FROM compras c),
        (SELECT MAX(COALESCE(c.fecha_emision, c.created_at)) FROM compras c),
        (SELECT COALESCE(json_agg(t ORDER BY t.moneda), '[]'::json) FROM (
            SELECT
                COALESCE(c.moneda, 'CRC')                                   AS moneda,
                COUNT(*)                                                    AS cantidad,
                COALESCE(SUM(c.total_comprobante), 0)                       AS total_comprado,
                COALESCE(SUM(c.total_impuesto), 0)                          AS total_impuesto,
                COALESCE(SUM(CASE WHEN c.condicion_pago = 'credito'
                                   AND c.estado_recepcion IN ('aceptado', 'aceptado_parcial')
                                  THEN GREATEST(c.total_comprobante - c.monto_pagado, 0)
                                  ELSE 0 END), 0)                           AS saldo_pendiente
            FROM compras c
            GROUP BY COALESCE(c.moneda, 'CRC')
        ) t),
        (SELECT COALESCE(json_agg(t), '[]'::json) FROM (
            SELECT
                MIN(NULLIF(trim(l->>'detalle'), ''))                        AS nombre,
                COALESCE(c.moneda, 'CRC')                                   AS moneda,
                SUM(COALESCE(NULLIF(l->>'cantidad', '')::NUMERIC, 0))       AS cantidad,
                SUM(COALESCE(NULLIF(l->>'monto_total', '')::NUMERIC, 0))    AS monto_total
            FROM compras c
            CROSS JOIN LATERAL jsonb_array_elements(c.lineas) l
            WHERE NULLIF(trim(l->>'detalle'), '') IS NOT NULL
            GROUP BY lower(trim(l->>'detalle')), COALESCE(c.moneda, 'CRC')
            ORDER BY SUM(COALESCE(NULLIF(l->>'monto_total', '')::NUMERIC, 0)) DESC
            LIMIT 5
        ) t);
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
    SET search_path TO 'public', 'pg_temp'
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
-- Name: sp_recibo_adelanto_create(bigint, bigint, bigint, numeric, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_recibo_adelanto_create(p_documento_id bigint, p_empresa_id bigint, p_cliente_id bigint, p_monto numeric, p_moneda character varying DEFAULT 'CRC'::character varying) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
            DECLARE v_id BIGINT;
            BEGIN
                INSERT INTO recibos_adelanto (empresa_id, documento_id, cliente_id, monto_original, saldo_disponible, estado, moneda)
                VALUES (p_empresa_id, p_documento_id, p_cliente_id, p_monto, p_monto, 'disponible', COALESCE(NULLIF(p_moneda, ''), 'CRC'))
                RETURNING id INTO v_id;
                RETURN v_id;
            END; $$;


--
-- Name: sp_recibo_pago_create(bigint, bigint, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_recibo_pago_create(p_documento_id bigint, p_empresa_id bigint, p_aplicaciones jsonb, p_medios_pago jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
-- Name: sp_reporte_comisiones(bigint, date, date, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_comisiones(p_empresa_id bigint, p_fecha_desde date, p_fecha_hasta date, p_funcionario_id bigint DEFAULT NULL::bigint, p_sucursal_id bigint DEFAULT NULL::bigint) RETURNS TABLE(documento_id bigint, fecha_emision timestamp without time zone, tipo_documento character varying, tipo_label character varying, numero_consecutivo character varying, cliente character varying, sucursal_id bigint, funcionario_id bigint, funcionario_nombre character varying, numero_linea smallint, detalle text, moneda character varying, tipo_cambio numeric, base_documento numeric, base_crc numeric, pct numeric, origen_pct character varying, comision_crc numeric)
    LANGUAGE plpgsql
    AS $$
            BEGIN
                RETURN QUERY
                WITH base AS (
                    SELECT
                        d.id AS doc_id, d.fecha_emision AS fecha, d.tipo_documento AS tipo,
                        d.numero_consecutivo AS consecutivo,
                        COALESCE(d.receptor_nombre, 'Consumidor Final')::VARCHAR AS receptor,
                        d.sucursal_id AS sucursal, d.moneda AS mon, d.tipo_cambio AS tc,
                        COALESCE(l.funcionario_id, d.funcionario_id, orig.funcionario_id) AS func_id,
                        l.numero_linea AS num_linea, l.detalle AS det,
                        l.producto_id AS prod_id, l.bodega_id AS bod_id,
                        CASE WHEN d.tipo_documento = '03' THEN -l.subtotal ELSE l.subtotal END AS base_doc
                    FROM documentos_electronicos d
                    JOIN documento_lineas l ON l.documento_id = d.id
                    LEFT JOIN LATERAL (
                        SELECT o.funcionario_id
                        FROM documento_referencias r
                        JOIN documentos_electronicos o
                          ON o.empresa_id = d.empresa_id AND o.deleted_at IS NULL
                         AND (o.clave = r.numero OR o.numero_consecutivo = r.numero)
                        WHERE r.documento_id = d.id AND d.tipo_documento = '03'
                        LIMIT 1
                    ) orig ON TRUE
                    WHERE d.empresa_id = p_empresa_id
                      AND d.deleted_at IS NULL
                      AND d.estado = 'aceptado'
                      AND d.tipo_documento IN ('01', '03', '04', '09')
                      AND d.fecha_emision::DATE BETWEEN p_fecha_desde AND p_fecha_hasta
                      AND (p_sucursal_id IS NULL OR d.sucursal_id = p_sucursal_id)
                ),
                resuelto AS (
                    SELECT
                        b.*,
                        f.name AS func_nombre, f.commission_pct AS func_pct,
                        p.comision_activa AS p_activa, p.comision_pct AS p_pct,
                        s.comision_activa AS s_activa, s.comision_pct AS s_pct,
                        CASE
                            WHEN p.id IS NOT NULL AND s.id IS NULL THEN 'producto'
                            WHEN s.id IS NOT NULL AND p.id IS NULL THEN 'servicio'
                            WHEN p.id IS NOT NULL AND s.id IS NOT NULL THEN
                                CASE
                                    WHEN b.bod_id IS NOT NULL                THEN 'producto'
                                    WHEN lower(s.name) = lower(b.det)        THEN 'servicio'
                                    WHEN lower(p.name) = lower(b.det)        THEN 'producto'
                                END
                        END AS item
                    FROM base b
                    LEFT JOIN funcionarios f ON f.id = b.func_id AND f.empresa_id = p_empresa_id
                    LEFT JOIN productos    p ON p.id = b.prod_id AND p.empresa_id = p_empresa_id
                    LEFT JOIN servicios    s ON s.id = b.prod_id AND s.empresa_id = p_empresa_id
                    WHERE p_funcionario_id IS NULL OR b.func_id = p_funcionario_id
                ),
                calculo AS (
                    SELECT
                        r.*,
                        ROUND(r.base_doc * r.tc, 2) AS base_colones,
                        CASE
                            WHEN r.func_id IS NULL THEN 0::NUMERIC
                            WHEN r.item = 'servicio' AND r.s_activa AND r.s_pct IS NOT NULL THEN r.s_pct
                            WHEN r.item = 'producto' AND r.p_activa AND r.p_pct IS NOT NULL THEN r.p_pct
                            ELSE COALESCE(r.func_pct, 0)
                        END AS pct_aplicado,
                        CASE
                            WHEN r.func_id IS NULL THEN 'sin funcionario'
                            WHEN r.item = 'servicio' AND r.s_activa AND r.s_pct IS NOT NULL THEN 'servicio'
                            WHEN r.item = 'producto' AND r.p_activa AND r.p_pct IS NOT NULL THEN 'producto'
                            ELSE 'funcionario'
                        END AS origen
                    FROM resuelto r
                )
                SELECT
                    c.doc_id, c.fecha, c.tipo::VARCHAR,
                    (CASE c.tipo
                        WHEN '01' THEN 'Factura Electrónica'
                        WHEN '03' THEN 'Nota de Crédito'
                        WHEN '04' THEN 'Tiquete Electrónico'
                        WHEN '09' THEN 'Factura de Exportación'
                        ELSE c.tipo
                    END)::VARCHAR,
                    c.consecutivo::VARCHAR, c.receptor, c.sucursal, c.func_id,
                    COALESCE(c.func_nombre, 'Sin funcionario asignado')::VARCHAR,
                    c.num_linea, c.det::TEXT, c.mon::VARCHAR, c.tc, c.base_doc,
                    c.base_colones, c.pct_aplicado, c.origen::VARCHAR,
                    ROUND(c.base_colones * c.pct_aplicado / 100, 2)
                FROM calculo c
                ORDER BY COALESCE(c.func_nombre, 'zzz'), c.fecha, c.doc_id, c.num_linea;
            END;
            $$;


--
-- Name: sp_reporte_cxc_mora(bigint, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_reporte_cxc_mora(p_empresa_id bigint, p_fecha_corte date DEFAULT CURRENT_DATE) RETURNS TABLE(id bigint, cliente_id bigint, cliente_nombre character varying, cliente_cedula character varying, documento_id bigint, moneda character varying, monto_total numeric, saldo_pendiente numeric, fecha_emision timestamp without time zone, fecha_vencimiento timestamp without time zone, dias_atraso integer, estado character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
      AND (p_fecha_desde IS NULL OR d.fecha_emision >= p_fecha_desde)
      AND (p_fecha_hasta IS NULL OR d.fecha_emision < p_fecha_hasta + 1)
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
    SET search_path TO 'public', 'pg_temp'
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
                  AND d.fecha_emision >= p_fecha_desde AND d.fecha_emision < p_fecha_hasta + 1
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
        ROW_NUMBER() OVER (ORDER BY SUM(CASE WHEN d.tipo_documento = '03' THEN -d.total_comprobante ELSE d.total_comprobante END) DESC)::BIGINT AS posicion,
        COALESCE(d.receptor_nombre,    'Consumidor Final')::VARCHAR AS receptor_nombre,
        COALESCE(d.receptor_numero_id, '—')::VARCHAR                AS receptor_numero_id,
        COUNT(*) FILTER (WHERE d.tipo_documento <> '03')::BIGINT    AS cantidad_docs,
        SUM(CASE WHEN d.tipo_documento = '03' THEN -d.total_venta_neta ELSE d.total_venta_neta END) AS total_venta_neta,
        SUM(CASE WHEN d.tipo_documento = '03' THEN -d.total_impuesto   ELSE d.total_impuesto   END) AS total_impuesto,
        SUM(CASE WHEN d.tipo_documento = '03' THEN -d.total_comprobante ELSE d.total_comprobante END) AS total_comprobante
    FROM documentos_electronicos d
    WHERE d.empresa_id  = p_empresa_id
      AND d.estado      = 'aceptado'
      AND d.deleted_at  IS NULL
      AND d.tipo_documento <> '08'
      AND COALESCE(d.moneda, 'CRC') = COALESCE(p_moneda, 'CRC')
      AND d.fecha_emision >= p_fecha_desde AND d.fecha_emision < p_fecha_hasta + 1
    GROUP BY d.receptor_nombre, d.receptor_numero_id
    ORDER BY SUM(CASE WHEN d.tipo_documento = '03' THEN -d.total_comprobante ELSE d.total_comprobante END) DESC
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
      AND d.fecha_emision >= p_fecha_desde AND d.fecha_emision < p_fecha_hasta + 1
    GROUP BY d.tipo_documento, COALESCE(d.moneda, 'CRC')
    ORDER BY COALESCE(d.moneda, 'CRC'), SUM(d.total_comprobante) DESC;
END;
$$;


--
-- Name: sp_rrhh_agente_autenticar(character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_agente_autenticar(p_token_hash character varying, p_ip character varying, p_version character varying) RETURNS TABLE(id bigint, empresa_id bigint, nombre character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    UPDATE rrhh_agentes a
       SET ultimo_contacto = NOW(), ultima_ip = LEFT(p_ip, 45), version = COALESCE(LEFT(p_version, 20), a.version)
     WHERE a.token_hash = p_token_hash AND a.is_active AND a.deleted_at IS NULL
    RETURNING a.id, a.empresa_id, a.nombre;
END; $$;


--
-- Name: sp_rrhh_agente_create(bigint, character varying, bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_agente_create(p_empresa_id bigint, p_nombre character varying, p_sucursal_id bigint, p_token_hash character varying, p_prefijo character varying) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO rrhh_agentes (empresa_id, nombre, sucursal_id, token_hash, token_prefijo)
    VALUES (p_empresa_id, btrim(p_nombre), p_sucursal_id, p_token_hash, p_prefijo) RETURNING rrhh_agentes.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_agente_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_agente_list(p_empresa_id bigint) RETURNS TABLE(id bigint, nombre character varying, sucursal_id bigint, token_prefijo character varying, version character varying, ultimo_contacto timestamp without time zone, ultima_ip character varying, is_active boolean, dispositivos bigint, tiene_token boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT a.id, a.nombre, a.sucursal_id, a.token_prefijo, a.version, a.ultimo_contacto, a.ultima_ip, a.is_active,
           (SELECT COUNT(*) FROM rrhh_dispositivos d WHERE d.agente_id = a.id AND d.deleted_at IS NULL),
           (a.token_hash IS NOT NULL)
      FROM rrhh_agentes a
     WHERE a.empresa_id = p_empresa_id AND a.deleted_at IS NULL
     ORDER BY lower(a.nombre);
END; $$;


--
-- Name: sp_rrhh_agente_set_token(bigint, bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_agente_set_token(p_id bigint, p_empresa_id bigint, p_token_hash character varying, p_prefijo character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE rrhh_agentes SET token_hash = p_token_hash, token_prefijo = p_prefijo, updated_at = NOW()
     WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_agente_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_agente_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_agentes WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN RETURN FALSE; END IF;
    IF EXISTS (SELECT 1 FROM rrhh_dispositivos WHERE agente_id = p_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'AGENTE_EN_USO: El agente atiende dispositivos; cámbielos de agente o elimínelos antes.';
    END IF;
    UPDATE rrhh_agentes SET deleted_at = NOW(), token_hash = NULL, updated_at = NOW() WHERE id = p_id AND empresa_id = p_empresa_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_agente_update(bigint, bigint, character varying, bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_agente_update(p_id bigint, p_empresa_id bigint, p_nombre character varying, p_sucursal_id bigint, p_is_active boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE rrhh_agentes SET nombre = btrim(p_nombre), sucursal_id = p_sucursal_id, is_active = COALESCE(p_is_active, TRUE), updated_at = NOW()
     WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_ajuste_eliminar(bigint, bigint, date, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_ajuste_eliminar(p_empresa_id bigint, p_empleado_id bigint, p_fecha date, p_tipo character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE rrhh_asistencia_ajustes SET deleted_at = NOW(), updated_at = NOW()
     WHERE empresa_id = p_empresa_id AND empleado_id = p_empleado_id AND fecha = p_fecha AND tipo = p_tipo AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_ajuste_guardar(bigint, bigint, date, character varying, boolean, integer, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_ajuste_guardar(p_empresa_id bigint, p_empleado_id bigint, p_fecha date, p_tipo character varying, p_aprobado boolean, p_minutos integer, p_motivo character varying) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_empleados WHERE id = p_empleado_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.';
    END IF;
    IF p_tipo = 'justificacion' AND COALESCE(btrim(p_motivo), '') = '' THEN
        RAISE EXCEPTION 'AJUSTE_INVALIDO: Indique el motivo de la justificación.';
    END IF;
    IF p_tipo = 'extra' AND p_aprobado IS NULL THEN
        RAISE EXCEPTION 'AJUSTE_INVALIDO: Indique si aprueba o rechaza las horas extra.';
    END IF;
    IF p_tipo = 'extra' AND p_aprobado = FALSE AND COALESCE(btrim(p_motivo), '') = '' THEN
        RAISE EXCEPTION 'AJUSTE_INVALIDO: Indique el motivo del rechazo.';
    END IF;

    UPDATE rrhh_asistencia_ajustes SET aprobado = p_aprobado, minutos = p_minutos, motivo = NULLIF(btrim(COALESCE(p_motivo, '')), ''),
           usuario_id = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT, updated_at = NOW()
     WHERE empleado_id = p_empleado_id AND fecha = p_fecha AND tipo = p_tipo AND deleted_at IS NULL
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        INSERT INTO rrhh_asistencia_ajustes (empresa_id, empleado_id, fecha, tipo, aprobado, minutos, motivo, usuario_id)
        VALUES (p_empresa_id, p_empleado_id, p_fecha, p_tipo, p_aprobado, p_minutos, NULLIF(btrim(COALESCE(p_motivo, '')), ''),
                NULLIF(current_setting('app.current_user_id', true), '')::BIGINT)
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_asistencia_resumen(bigint, date, date, bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_asistencia_resumen(p_empresa_id bigint, p_desde date, p_hasta date, p_empleado_id bigint DEFAULT NULL::bigint, p_departamento_id bigint DEFAULT NULL::bigint, p_sucursal_id bigint DEFAULT NULL::bigint) RETURNS TABLE(empleado_id bigint, empleado_codigo character varying, empleado_nombre character varying, departamento_nombre character varying, fecha date, dia_semana integer, tipo_dia character varying, feriado_nombre character varying, horario_id bigint, horario_nombre character varying, entrada_prog time without time zone, salida_prog time without time zone, entrada_real timestamp without time zone, salida_real timestamp without time zone, marcas integer, minutos_programados integer, minutos_trabajados integer, minutos_tarde integer, minutos_salida_anticipada integer, minutos_extra integer, factor_extra numeric, excede_12h boolean, estado character varying, justificacion character varying, extra_estado character varying, extra_minutos_aprobados integer, extra_motivo character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_hoy TIMESTAMP := NOW();
BEGIN
    IF p_hasta < p_desde THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha final es anterior a la inicial.'; END IF;
    IF p_hasta - p_desde > 92 THEN RAISE EXCEPTION 'FECHA_INVALIDA: El rango de fechas no puede pasar de 93 días.'; END IF;

    RETURN QUERY
    WITH ses AS (
        SELECT * FROM fn_rrhh_sesiones(p_empresa_id, p_empleado_id, (p_desde - 1)::TIMESTAMP, (p_hasta + 2)::TIMESTAMP)
    ),
    emp AS (
        SELECT e.id, e.codigo, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR AS nombre,
               dp.nombre AS depto, e.fecha_ingreso, e.fecha_salida, e.estado
          FROM rrhh_empleados e
          LEFT JOIN rrhh_departamentos dp ON dp.id = e.departamento_id
         WHERE e.empresa_id = p_empresa_id AND e.deleted_at IS NULL
           AND (p_empleado_id IS NULL OR e.id = p_empleado_id)
           AND (p_departamento_id IS NULL OR e.departamento_id = p_departamento_id)
           AND (p_sucursal_id IS NULL OR e.sucursal_id = p_sucursal_id)
           AND e.fecha_ingreso <= p_hasta AND (e.fecha_salida IS NULL OR e.fecha_salida >= p_desde)
    ),
    dias AS (
        SELECT emp.*, g::DATE AS dia
          FROM emp, generate_series(p_desde::TIMESTAMP, p_hasta::TIMESTAMP, INTERVAL '1 day') g
         WHERE g::DATE >= emp.fecha_ingreso AND (emp.fecha_salida IS NULL OR g::DATE <= emp.fecha_salida)
    ),
    base AS (
        SELECT d.*, a.horario_id AS hid, h.nombre AS hnombre, h.tolerancia_entrada_min AS tol_ent, h.tolerancia_salida_min AS tol_sal,
               h.minutos_minimos_extra AS min_extra, hd.hora_entrada, hd.hora_salida, hd.minutos_descanso,
               f.nombre AS fer_nombre, f.pago_obligatorio AS fer_oblig
          FROM dias d
          LEFT JOIN LATERAL (
              SELECT x.horario_id FROM rrhh_empleado_horarios x
               WHERE x.empleado_id = d.id AND x.deleted_at IS NULL AND x.vigente_desde <= d.dia AND (x.vigente_hasta IS NULL OR x.vigente_hasta >= d.dia)
               ORDER BY x.vigente_desde DESC LIMIT 1) a ON TRUE
          LEFT JOIN rrhh_horarios h ON h.id = a.horario_id
          LEFT JOIN rrhh_horario_dias hd ON hd.horario_id = a.horario_id AND hd.dia_semana = EXTRACT(ISODOW FROM d.dia)
          LEFT JOIN rrhh_feriados f ON f.empresa_id = p_empresa_id AND f.fecha = d.dia AND f.deleted_at IS NULL
    ),
    agr AS (
        SELECT s.s_empleado_id AS emp_id, s.s_entrada::DATE AS dia, MIN(s.s_entrada) AS primera_entrada, MAX(s.s_salida) AS ultima_salida,
               (COUNT(*) + COUNT(s.s_salida))::INTEGER AS n_marcas,
               COUNT(*) FILTER (WHERE s.s_salida IS NOT NULL)::INTEGER AS cerradas,
               COUNT(*) FILTER (WHERE s.s_salida IS NULL)::INTEGER AS abiertas,
               COALESCE(SUM(EXTRACT(EPOCH FROM (s.s_salida - s.s_entrada)) / 60) FILTER (WHERE s.s_salida IS NOT NULL), 0)::INTEGER AS bruto,
               MAX(s.s_entrada) FILTER (WHERE s.s_salida IS NULL) AS abierta_desde
          FROM ses s GROUP BY s.s_empleado_id, s.s_entrada::DATE
    ),
    calc AS (
        SELECT b.*, g.primera_entrada, g.ultima_salida, COALESCE(g.n_marcas, 0) AS n_marcas, COALESCE(g.cerradas, 0) AS cerradas,
               COALESCE(g.abiertas, 0) AS abiertas, g.abierta_desde,
               -- con una sola sesión continua se descuenta el descanso no remunerado del horario
               CASE WHEN COALESCE(g.cerradas, 0) = 1 AND b.minutos_descanso > 0 THEN GREATEST(COALESCE(g.bruto, 0) - b.minutos_descanso, 0)
                    ELSE COALESCE(g.bruto, 0) END AS trabajado,
               CASE WHEN b.hora_entrada IS NOT NULL THEN fn_rrhh_minutos_dia(b.hora_entrada, b.hora_salida, b.minutos_descanso) END AS programado,
               CASE WHEN b.hora_entrada IS NOT NULL THEN b.dia::TIMESTAMP + b.hora_entrada END AS ts_entrada_prog,
               CASE WHEN b.hora_entrada IS NOT NULL THEN b.dia::TIMESTAMP + b.hora_salida
                         + CASE WHEN b.hora_salida <= b.hora_entrada THEN INTERVAL '1 day' ELSE INTERVAL '0' END END AS ts_salida_prog,
               (SELECT j.motivo FROM rrhh_asistencia_ajustes j WHERE j.empleado_id = b.id AND j.fecha = b.dia AND j.tipo = 'justificacion' AND j.deleted_at IS NULL) AS just,
               (SELECT j.aprobado FROM rrhh_asistencia_ajustes j WHERE j.empleado_id = b.id AND j.fecha = b.dia AND j.tipo = 'extra' AND j.deleted_at IS NULL) AS ex_aprob,
               (SELECT j.minutos FROM rrhh_asistencia_ajustes j WHERE j.empleado_id = b.id AND j.fecha = b.dia AND j.tipo = 'extra' AND j.deleted_at IS NULL) AS ex_min,
               (SELECT j.motivo FROM rrhh_asistencia_ajustes j WHERE j.empleado_id = b.id AND j.fecha = b.dia AND j.tipo = 'extra' AND j.deleted_at IS NULL) AS ex_motivo,
               EXISTS (SELECT 1 FROM rrhh_asistencia_ajustes j WHERE j.empleado_id = b.id AND j.fecha = b.dia AND j.tipo = 'extra' AND j.deleted_at IS NULL) AS ex_hay,
               EXISTS (SELECT 1 FROM rrhh_incapacidades i WHERE i.empleado_id = b.id AND i.deleted_at IS NULL AND i.estado = 'registrada'
                          AND i.fecha_inicio <= b.dia AND i.fecha_fin >= b.dia) AS hay_inc,
               (SELECT t.nombre FROM rrhh_permiso_solicitudes ps JOIN rrhh_permiso_tipos t ON t.id = ps.tipo_id
                 WHERE ps.empleado_id = b.id AND ps.deleted_at IS NULL AND ps.estado = 'aprobada' AND ps.unidad = 'dias'
                   AND ps.fecha_inicio <= b.dia AND ps.fecha_fin >= b.dia ORDER BY ps.id LIMIT 1) AS perm_dia
          FROM base b LEFT JOIN agr g ON g.emp_id = b.id AND g.dia = b.dia
    ),
    perm AS (
        SELECT c.*,
               COALESCE((SELECT SUM(GREATEST(EXTRACT(EPOCH FROM (LEAST(c.dia::TIMESTAMP + ph.hora_fin, c.primera_entrada)
                                                                 - GREATEST(c.dia::TIMESTAMP + ph.hora_inicio, c.ts_entrada_prog))) / 60, 0))
                           FROM rrhh_permiso_solicitudes ph
                          WHERE ph.empleado_id = c.id AND ph.deleted_at IS NULL AND ph.estado = 'aprobada' AND ph.unidad = 'horas'
                            AND ph.fecha_inicio = c.dia AND c.primera_entrada IS NOT NULL AND c.ts_entrada_prog IS NOT NULL), 0) AS ov_ent,
               COALESCE((SELECT SUM(GREATEST(EXTRACT(EPOCH FROM (LEAST(c.dia::TIMESTAMP + ph.hora_fin, c.ts_salida_prog)
                                                                 - GREATEST(c.dia::TIMESTAMP + ph.hora_inicio, c.ultima_salida))) / 60, 0))
                           FROM rrhh_permiso_solicitudes ph
                          WHERE ph.empleado_id = c.id AND ph.deleted_at IS NULL AND ph.estado = 'aprobada' AND ph.unidad = 'horas'
                            AND ph.fecha_inicio = c.dia AND c.ultima_salida IS NOT NULL AND c.ts_salida_prog IS NOT NULL), 0) AS ov_sal
          FROM calc c
    ),
    fin AS (
        SELECT c.*,
               (c.fer_nombre IS NOT NULL) AS es_feriado,
               (c.hora_entrada IS NULL) AS es_descanso,
               -- tardanza y salida anticipada solo en días laborales con horario
               CASE WHEN c.hora_entrada IS NOT NULL AND c.fer_nombre IS NULL AND c.primera_entrada IS NOT NULL
                         AND EXTRACT(EPOCH FROM (c.primera_entrada - c.ts_entrada_prog)) / 60 - c.ov_ent > c.tol_ent
                    THEN (EXTRACT(EPOCH FROM (c.primera_entrada - c.ts_entrada_prog)) / 60 - c.ov_ent)::INTEGER ELSE 0 END AS tarde,
               CASE WHEN c.hora_entrada IS NOT NULL AND c.fer_nombre IS NULL AND c.ultima_salida IS NOT NULL AND c.abiertas = 0
                         AND EXTRACT(EPOCH FROM (c.ts_salida_prog - c.ultima_salida)) / 60 - c.ov_sal > c.tol_sal
                    THEN (EXTRACT(EPOCH FROM (c.ts_salida_prog - c.ultima_salida)) / 60 - c.ov_sal)::INTEGER ELSE 0 END AS anticipada
          FROM perm c
    ),
    extra AS (
        SELECT f.*,
               CASE WHEN f.abiertas > 0 THEN 0
                    WHEN f.es_feriado OR f.es_descanso THEN f.trabajado
                    WHEN f.programado IS NOT NULL AND f.trabajado - f.programado >= GREATEST(f.min_extra, 1) THEN f.trabajado - f.programado
                    ELSE 0 END AS x_min
          FROM fin f
    )
    SELECT x.id, x.codigo::VARCHAR, x.nombre, x.depto::VARCHAR, x.dia, EXTRACT(ISODOW FROM x.dia)::INTEGER,
           (CASE WHEN x.es_feriado THEN 'feriado' WHEN x.es_descanso THEN 'descanso' ELSE 'laboral' END)::VARCHAR,
           x.fer_nombre::VARCHAR, x.hid, x.hnombre::VARCHAR, x.hora_entrada, x.hora_salida, x.primera_entrada, x.ultima_salida,
           x.n_marcas, x.programado, x.trabajado, x.tarde, x.anticipada, x.x_min,
           (CASE WHEN x.x_min = 0 THEN 0
                 WHEN x.es_descanso OR (x.es_feriado AND x.fer_oblig) THEN 2.0 ELSE 1.5 END)::NUMERIC,
           (x.trabajado > 720),
           (CASE
              WHEN x.abiertas > 0 AND x.dia = v_hoy::DATE AND x.abierta_desde > v_hoy - INTERVAL '14 hours' THEN 'en_curso'
              WHEN x.abiertas > 0 THEN 'incompleta'
              WHEN x.n_marcas > 0 AND x.es_feriado THEN 'trabajo_feriado'
              WHEN x.n_marcas > 0 AND x.es_descanso THEN 'trabajo_descanso'
              WHEN x.n_marcas > 0 AND x.tarde > 0 THEN 'tarde'
              WHEN x.n_marcas > 0 THEN 'ok'
              WHEN x.hay_inc THEN 'incapacidad'
              WHEN x.es_feriado THEN 'feriado'
              WHEN x.es_descanso THEN 'descanso'
              WHEN x.perm_dia IS NOT NULL THEN 'permiso'
              WHEN x.dia > v_hoy::DATE OR (x.dia = v_hoy::DATE AND v_hoy < x.ts_entrada_prog + INTERVAL '1 minute' * x.tol_ent) THEN 'programado'
              WHEN x.just IS NOT NULL THEN 'justificada'
              WHEN x.hid IS NULL THEN 'sin_horario'
              ELSE 'ausente' END)::VARCHAR,
           COALESCE(x.just, CASE WHEN x.hay_inc THEN 'Incapacidad' WHEN x.perm_dia IS NOT NULL THEN 'Permiso: ' || x.perm_dia END)::VARCHAR,
           (CASE WHEN x.x_min = 0 THEN NULL WHEN NOT x.ex_hay THEN 'pendiente' WHEN x.ex_aprob THEN 'aprobada' ELSE 'rechazada' END)::VARCHAR,
           (CASE WHEN x.x_min = 0 OR NOT x.ex_hay OR NOT x.ex_aprob THEN 0 ELSE LEAST(COALESCE(x.ex_min, x.x_min), x.x_min) END)::INTEGER,
           x.ex_motivo::VARCHAR
      FROM extra x
     ORDER BY x.nombre, x.dia;
END; $$;


--
-- Name: sp_rrhh_ausencias_calendario(bigint, date, date, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_ausencias_calendario(p_empresa_id bigint, p_desde date, p_hasta date, p_departamento_id bigint DEFAULT NULL::bigint) RETURNS TABLE(categoria character varying, id bigint, empleado_id bigint, empleado_nombre character varying, departamento_id bigint, departamento_nombre character varying, departamento_total integer, fecha_inicio date, fecha_fin date, dias numeric, hora_inicio time without time zone, hora_fin time without time zone, estado character varying, detalle character varying)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF p_hasta < p_desde THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha final es anterior a la inicial.'; END IF;
    IF p_hasta - p_desde > 92 THEN RAISE EXCEPTION 'FECHA_INVALIDA: El rango de fechas no puede pasar de 93 días.'; END IF;
    RETURN QUERY
    WITH a AS (
        SELECT 'vacaciones'::VARCHAR AS cat, s.id AS rid, s.empleado_id AS eid, s.fecha_inicio AS ini, s.fecha_fin AS fin, s.dias::NUMERIC AS cant,
               NULL::TIME AS hi, NULL::TIME AS hf, s.estado::VARCHAR AS est, 'Vacaciones'::VARCHAR AS det
          FROM rrhh_vacaciones_solicitudes s
         WHERE s.empresa_id = p_empresa_id AND s.deleted_at IS NULL AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada')
           AND s.fecha_inicio <= p_hasta AND s.fecha_fin >= p_desde
        UNION ALL
        SELECT 'permiso'::VARCHAR, s.id, s.empleado_id, s.fecha_inicio, s.fecha_fin, s.cantidad, s.hora_inicio, s.hora_fin, s.estado::VARCHAR, t.nombre::VARCHAR
          FROM rrhh_permiso_solicitudes s JOIN rrhh_permiso_tipos t ON t.id = s.tipo_id
         WHERE s.empresa_id = p_empresa_id AND s.deleted_at IS NULL AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada')
           AND s.fecha_inicio <= p_hasta AND s.fecha_fin >= p_desde
        UNION ALL
        SELECT 'incapacidad'::VARCHAR, i.id, i.empleado_id, i.fecha_inicio, i.fecha_fin, i.dias::NUMERIC, NULL::TIME, NULL::TIME, 'registrada'::VARCHAR,
               (CASE i.tipo WHEN 'enfermedad' THEN 'Incapacidad por enfermedad' WHEN 'maternidad' THEN 'Incapacidad por maternidad'
                            ELSE 'Incapacidad por riesgo del trabajo' END)::VARCHAR
          FROM rrhh_incapacidades i
         WHERE i.empresa_id = p_empresa_id AND i.deleted_at IS NULL AND i.estado = 'registrada'
           AND i.fecha_inicio <= p_hasta AND i.fecha_fin >= p_desde
    )
    SELECT a.cat, a.rid, a.eid, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR,
           e.departamento_id, dp.nombre::VARCHAR,
           (SELECT COUNT(*)::INTEGER FROM rrhh_empleados x WHERE x.empresa_id = p_empresa_id AND x.deleted_at IS NULL AND x.estado = 'activo'
               AND x.departamento_id IS NOT DISTINCT FROM e.departamento_id),
           a.ini, a.fin, a.cant, a.hi, a.hf, a.est, a.det
      FROM a
      JOIN rrhh_empleados e ON e.id = a.eid
      LEFT JOIN rrhh_departamentos dp ON dp.id = e.departamento_id
     WHERE (p_departamento_id IS NULL OR e.departamento_id = p_departamento_id)
     ORDER BY dp.nombre NULLS LAST, a.ini, e.nombre;
END; $$;


--
-- Name: sp_rrhh_ausencias_traslapes(bigint, bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_ausencias_traslapes(p_empresa_id bigint, p_empleado_id bigint, p_desde date, p_hasta date) RETURNS TABLE(categoria character varying, empleado_id bigint, empleado_nombre character varying, fecha_inicio date, fecha_fin date, estado character varying, detalle character varying, departamento_total integer)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_depto BIGINT;
BEGIN
    SELECT e.departamento_id INTO v_depto FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL;
    IF v_depto IS NULL OR p_hasta < p_desde OR p_hasta - p_desde > 92 THEN RETURN; END IF;
    RETURN QUERY
    SELECT c.categoria, c.empleado_id, c.empleado_nombre, c.fecha_inicio, c.fecha_fin, c.estado, c.detalle, c.departamento_total
      FROM sp_rrhh_ausencias_calendario(p_empresa_id, p_desde, p_hasta, v_depto) c
     WHERE c.empleado_id <> p_empleado_id
     ORDER BY c.fecha_inicio, c.empleado_nombre;
END; $$;


--
-- Name: sp_rrhh_cargas_list(bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_cargas_list(p_empresa_id bigint, p_anio integer) RETURNS TABLE(rubro character varying, parte character varying, porcentaje numeric, orden integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT c.rubro::VARCHAR, c.parte::VARCHAR, c.porcentaje, c.orden FROM rrhh_cargas_sociales c
     WHERE c.empresa_id = p_empresa_id AND c.anio = p_anio ORDER BY c.parte, c.orden, c.id;
$$;


--
-- Name: sp_rrhh_concepto_cargar(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_concepto_cargar(p_empresa_id bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n INTEGER;
BEGIN
    WITH sug (cod, nom, tp, ccss, renta) AS (
        VALUES ('BONO', 'Bonificación', 'ingreso', TRUE, TRUE),
               ('COMIS', 'Comisiones', 'ingreso', TRUE, TRUE),
               ('ALIM', 'Alimentación', 'ingreso', FALSE, FALSE),
               ('TRANSP', 'Transporte', 'ingreso', FALSE, FALSE),
               ('PRESTAMO', 'Cuota de préstamo', 'deduccion', FALSE, FALSE),
               ('PENSION', 'Pensión alimentaria', 'deduccion', FALSE, FALSE),
               ('ASOC', 'Asociación solidarista', 'deduccion', FALSE, FALSE),
               ('POLIZA', 'Póliza de seguro', 'deduccion', FALSE, FALSE)
    ), ins AS (
        INSERT INTO rrhh_conceptos (empresa_id, codigo, nombre, tipo, afecta_ccss, afecta_renta)
        SELECT p_empresa_id, s.cod, s.nom, s.tp, s.ccss, s.renta FROM sug s
         WHERE NOT EXISTS (SELECT 1 FROM rrhh_conceptos c WHERE c.empresa_id = p_empresa_id AND lower(c.codigo) = lower(s.cod) AND c.deleted_at IS NULL)
        RETURNING 1
    )
    SELECT COUNT(*)::INTEGER INTO v_n FROM ins;
    RETURN v_n;
END; $$;


--
-- Name: sp_rrhh_concepto_create(bigint, character varying, character varying, character varying, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_concepto_create(p_empresa_id bigint, p_codigo character varying, p_nombre character varying, p_tipo character varying, p_afecta_ccss boolean, p_afecta_renta boolean) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT; v_cod VARCHAR := btrim(COALESCE(p_codigo, '')); v_nom VARCHAR := btrim(COALESCE(p_nombre, ''));
BEGIN
    IF v_cod = '' OR v_nom = '' THEN RAISE EXCEPTION 'CONCEPTO_INVALIDO: Indique el código y el nombre del concepto.'; END IF;
    IF p_tipo NOT IN ('ingreso', 'deduccion') THEN RAISE EXCEPTION 'CONCEPTO_INVALIDO: El tipo debe ser ingreso o deducción.'; END IF;
    IF EXISTS (SELECT 1 FROM rrhh_conceptos c WHERE c.empresa_id = p_empresa_id AND lower(c.codigo) = lower(v_cod) AND c.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'CONCEPTO_INVALIDO: Ya existe un concepto con ese código.';
    END IF;
    INSERT INTO rrhh_conceptos (empresa_id, codigo, nombre, tipo, afecta_ccss, afecta_renta)
    VALUES (p_empresa_id, v_cod, v_nom, p_tipo, p_tipo = 'ingreso' AND COALESCE(p_afecta_ccss, FALSE), p_tipo = 'ingreso' AND COALESCE(p_afecta_renta, FALSE))
    RETURNING rrhh_conceptos.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_concepto_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_concepto_delete(p_empresa_id bigint, p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n INTEGER;
BEGIN
    IF EXISTS (SELECT 1 FROM rrhh_empleado_conceptos ec WHERE ec.concepto_id = p_id AND ec.empresa_id = p_empresa_id AND ec.deleted_at IS NULL)
       OR EXISTS (SELECT 1 FROM rrhh_planilla_lineas l WHERE l.concepto_id = p_id) THEN
        RAISE EXCEPTION 'CONCEPTO_INVALIDO: Este concepto ya se usa; en lugar de eliminarlo, desactívelo.';
    END IF;
    UPDATE rrhh_conceptos SET deleted_at = NOW(), updated_at = NOW() WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n > 0;
END; $$;


--
-- Name: sp_rrhh_concepto_list(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_concepto_list(p_empresa_id bigint, p_solo_activos boolean DEFAULT false) RETURNS TABLE(id bigint, codigo character varying, nombre character varying, tipo character varying, afecta_ccss boolean, afecta_renta boolean, is_active boolean, usos bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT c.id, c.codigo::VARCHAR, c.nombre::VARCHAR, c.tipo::VARCHAR, c.afecta_ccss, c.afecta_renta, c.is_active,
           ((SELECT COUNT(*) FROM rrhh_empleado_conceptos ec WHERE ec.concepto_id = c.id AND ec.deleted_at IS NULL)
            + (SELECT COUNT(*) FROM rrhh_planilla_lineas l WHERE l.concepto_id = c.id))
      FROM rrhh_conceptos c
     WHERE c.empresa_id = p_empresa_id AND c.deleted_at IS NULL AND (NOT p_solo_activos OR c.is_active)
     ORDER BY c.tipo DESC, lower(c.nombre);
END; $$;


--
-- Name: sp_rrhh_concepto_update(bigint, bigint, character varying, character varying, boolean, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_concepto_update(p_empresa_id bigint, p_id bigint, p_codigo character varying, p_nombre character varying, p_afecta_ccss boolean, p_afecta_renta boolean, p_is_active boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_c RECORD; v_cod VARCHAR := btrim(COALESCE(p_codigo, '')); v_nom VARCHAR := btrim(COALESCE(p_nombre, ''));
BEGIN
    SELECT * INTO v_c FROM rrhh_conceptos c WHERE c.id = p_id AND c.empresa_id = p_empresa_id AND c.deleted_at IS NULL;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF v_cod = '' OR v_nom = '' THEN RAISE EXCEPTION 'CONCEPTO_INVALIDO: Indique el código y el nombre del concepto.'; END IF;
    IF EXISTS (SELECT 1 FROM rrhh_conceptos c WHERE c.empresa_id = p_empresa_id AND lower(c.codigo) = lower(v_cod) AND c.deleted_at IS NULL AND c.id <> p_id) THEN
        RAISE EXCEPTION 'CONCEPTO_INVALIDO: Ya existe un concepto con ese código.';
    END IF;
    UPDATE rrhh_conceptos
       SET codigo = v_cod, nombre = v_nom, is_active = COALESCE(p_is_active, is_active),
           afecta_ccss = v_c.tipo = 'ingreso' AND COALESCE(p_afecta_ccss, FALSE),
           afecta_renta = v_c.tipo = 'ingreso' AND COALESCE(p_afecta_renta, FALSE), updated_at = NOW()
     WHERE id = p_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_departamento_create(bigint, character varying, character varying, character varying, bigint, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_departamento_create(p_empresa_id bigint, p_codigo character varying, p_nombre character varying, p_descripcion character varying, p_padre_id bigint, p_jefe_empleado_id bigint, p_centro_costo character varying) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT;
BEGIN
    PERFORM fn_rrhh_valida_depto_padre(p_empresa_id, NULL, p_padre_id);
    IF p_jefe_empleado_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM rrhh_empleados WHERE id = p_jefe_empleado_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'JEFE_INVALIDO: El jefe del departamento no existe.';
    END IF;
    INSERT INTO rrhh_departamentos (empresa_id, codigo, nombre, descripcion, departamento_padre_id, jefe_empleado_id, centro_costo)
    VALUES (p_empresa_id, NULLIF(btrim(COALESCE(p_codigo, '')), ''), btrim(p_nombre),
            NULLIF(btrim(COALESCE(p_descripcion, '')), ''), p_padre_id, p_jefe_empleado_id,
            NULLIF(btrim(COALESCE(p_centro_costo, '')), ''))
    RETURNING rrhh_departamentos.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_departamento_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_departamento_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, codigo character varying, nombre character varying, descripcion character varying, departamento_padre_id bigint, jefe_empleado_id bigint, centro_costo character varying, is_active boolean, deleted_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT d.id, d.empresa_id, d.codigo, d.nombre, d.descripcion, d.departamento_padre_id,
           d.jefe_empleado_id, d.centro_costo, d.is_active, d.deleted_at
    FROM rrhh_departamentos d WHERE d.id = p_id AND d.empresa_id = p_empresa_id;
END; $$;


--
-- Name: sp_rrhh_departamento_list(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_departamento_list(p_empresa_id bigint, p_eliminados boolean DEFAULT false) RETURNS TABLE(id bigint, empresa_id bigint, codigo character varying, nombre character varying, descripcion character varying, departamento_padre_id bigint, departamento_padre_nombre character varying, jefe_empleado_id bigint, jefe_nombre character varying, centro_costo character varying, is_active boolean, deleted_at timestamp without time zone, empleados bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT d.id, d.empresa_id, d.codigo, d.nombre, d.descripcion,
           d.departamento_padre_id, p.nombre, d.jefe_empleado_id,
           NULLIF(btrim(j.nombre || ' ' || j.apellido1 || ' ' || COALESCE(j.apellido2, '')), '')::VARCHAR,
           d.centro_costo, d.is_active, d.deleted_at,
           (SELECT COUNT(*) FROM rrhh_empleados e
             WHERE e.departamento_id = d.id AND e.deleted_at IS NULL AND e.estado <> 'liquidado')
    FROM rrhh_departamentos d
    LEFT JOIN rrhh_departamentos p ON p.id = d.departamento_padre_id
    LEFT JOIN rrhh_empleados     j ON j.id = d.jefe_empleado_id
    WHERE d.empresa_id = p_empresa_id
      AND ((p_eliminados AND d.deleted_at IS NOT NULL) OR (NOT p_eliminados AND d.deleted_at IS NULL))
    ORDER BY lower(d.nombre);
END; $$;


--
-- Name: sp_rrhh_departamento_restore(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_departamento_restore(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE rrhh_departamentos SET deleted_at = NULL, is_active = TRUE, updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NOT NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_departamento_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_departamento_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_n FROM rrhh_empleados
     WHERE departamento_id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL AND estado <> 'liquidado';
    IF v_n > 0 THEN
        RAISE EXCEPTION 'DEPTO_EN_USO: El departamento tiene % empleado(s); muévalos a otro departamento antes de eliminarlo.', v_n;
    END IF;
    SELECT COUNT(*) INTO v_n FROM rrhh_departamentos
     WHERE departamento_padre_id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'DEPTO_EN_USO: El departamento tiene % departamento(s) dependiente(s); reubíquelos antes de eliminarlo.', v_n;
    END IF;
    UPDATE rrhh_departamentos SET is_active = FALSE, deleted_at = NOW(), updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_departamento_update(bigint, bigint, character varying, character varying, character varying, bigint, bigint, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_departamento_update(p_id bigint, p_empresa_id bigint, p_codigo character varying, p_nombre character varying, p_descripcion character varying, p_padre_id bigint, p_jefe_empleado_id bigint, p_centro_costo character varying, p_is_active boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    PERFORM fn_rrhh_valida_depto_padre(p_empresa_id, p_id, p_padre_id);
    IF p_jefe_empleado_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM rrhh_empleados WHERE id = p_jefe_empleado_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'JEFE_INVALIDO: El jefe del departamento no existe.';
    END IF;
    UPDATE rrhh_departamentos SET
        codigo = NULLIF(btrim(COALESCE(p_codigo, '')), ''), nombre = btrim(p_nombre),
        descripcion = NULLIF(btrim(COALESCE(p_descripcion, '')), ''),
        departamento_padre_id = p_padre_id, jefe_empleado_id = p_jefe_empleado_id,
        centro_costo = NULLIF(btrim(COALESCE(p_centro_costo, '')), ''),
        is_active = p_is_active, updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_dispositivo_create(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_dispositivo_create(p_empresa_id bigint, p_datos jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT;
BEGIN
    PERFORM fn_rrhh_valida_dispositivo(p_empresa_id, NULLIF(p_datos->>'agente_id', '')::BIGINT);
    INSERT INTO rrhh_dispositivos (empresa_id, nombre, tipo_lector, marca, modelo, numero_serie, ubicacion, sucursal_id, agente_id)
    VALUES (p_empresa_id, btrim(p_datos->>'nombre'), COALESCE(p_datos->>'tipo_lector', 'huella'), COALESCE(p_datos->>'marca', 'otro'),
            NULLIF(btrim(COALESCE(p_datos->>'modelo', '')), ''), NULLIF(btrim(COALESCE(p_datos->>'numero_serie', '')), ''),
            NULLIF(btrim(COALESCE(p_datos->>'ubicacion', '')), ''), NULLIF(p_datos->>'sucursal_id', '')::BIGINT,
            NULLIF(p_datos->>'agente_id', '')::BIGINT)
    RETURNING rrhh_dispositivos.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_dispositivo_estado(bigint, bigint, bigint, character varying, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_dispositivo_estado(p_empresa_id bigint, p_agente_id bigint, p_dispositivo_id bigint, p_estado character varying, p_error character varying, p_sincronizado boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE rrhh_dispositivos SET
        estado_conexion = CASE WHEN p_estado IN ('en_linea', 'error') THEN p_estado ELSE estado_conexion END,
        ultimo_error = CASE WHEN p_estado = 'error' THEN LEFT(p_error, 255) ELSE NULL END,
        ultima_sincronizacion = CASE WHEN p_sincronizado THEN NOW() ELSE ultima_sincronizacion END
     WHERE id = p_dispositivo_id AND empresa_id = p_empresa_id AND agente_id = p_agente_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_dispositivo_list(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_dispositivo_list(p_empresa_id bigint, p_agente_id bigint DEFAULT NULL::bigint) RETURNS TABLE(id bigint, nombre character varying, tipo_lector character varying, marca character varying, modelo character varying, numero_serie character varying, ubicacion character varying, sucursal_id bigint, agente_id bigint, agente_nombre character varying, ultima_sincronizacion timestamp without time zone, ultima_marca timestamp without time zone, estado_conexion character varying, ultimo_error character varying, is_active boolean, usuarios bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT d.id, d.nombre, d.tipo_lector, d.marca, d.modelo, d.numero_serie, d.ubicacion, d.sucursal_id, d.agente_id, a.nombre,
           d.ultima_sincronizacion, d.ultima_marca, d.estado_conexion, d.ultimo_error, d.is_active,
           (SELECT COUNT(*) FROM rrhh_dispositivo_usuarios u WHERE u.dispositivo_id = d.id)
      FROM rrhh_dispositivos d
      LEFT JOIN rrhh_agentes a ON a.id = d.agente_id
     WHERE d.empresa_id = p_empresa_id AND d.deleted_at IS NULL AND (p_agente_id IS NULL OR d.agente_id = p_agente_id)
     ORDER BY lower(d.nombre);
END; $$;


--
-- Name: sp_rrhh_dispositivo_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_dispositivo_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE rrhh_dispositivos SET deleted_at = NOW(), updated_at = NOW()
     WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_dispositivo_update(bigint, bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_dispositivo_update(p_id bigint, p_empresa_id bigint, p_datos jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_dispositivos WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN RETURN FALSE; END IF;
    PERFORM fn_rrhh_valida_dispositivo(p_empresa_id, NULLIF(p_datos->>'agente_id', '')::BIGINT);
    UPDATE rrhh_dispositivos SET
        nombre = btrim(p_datos->>'nombre'), tipo_lector = COALESCE(p_datos->>'tipo_lector', 'huella'), marca = COALESCE(p_datos->>'marca', 'otro'),
        modelo = NULLIF(btrim(COALESCE(p_datos->>'modelo', '')), ''), numero_serie = NULLIF(btrim(COALESCE(p_datos->>'numero_serie', '')), ''),
        ubicacion = NULLIF(btrim(COALESCE(p_datos->>'ubicacion', '')), ''), sucursal_id = NULLIF(p_datos->>'sucursal_id', '')::BIGINT,
        agente_id = NULLIF(p_datos->>'agente_id', '')::BIGINT, is_active = COALESCE((p_datos->>'is_active')::BOOLEAN, TRUE), updated_at = NOW()
     WHERE id = p_id AND empresa_id = p_empresa_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_dispositivo_usuario_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_dispositivo_usuario_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    DELETE FROM rrhh_dispositivo_usuarios WHERE id = p_id AND empresa_id = p_empresa_id;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_dispositivo_usuario_set(bigint, bigint, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_dispositivo_usuario_set(p_empresa_id bigint, p_dispositivo_id bigint, p_empleado_id bigint, p_id_en_dispositivo character varying) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT; v_ext VARCHAR := btrim(p_id_en_dispositivo);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_dispositivos WHERE id = p_dispositivo_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'DISPOSITIVO_INVALIDO: El dispositivo no existe.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rrhh_empleados WHERE id = p_empleado_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.';
    END IF;
    IF v_ext = '' THEN RAISE EXCEPTION 'DISPOSITIVO_INVALIDO: Indique el ID del empleado dentro del dispositivo.'; END IF;
    IF EXISTS (SELECT 1 FROM rrhh_dispositivo_usuarios WHERE dispositivo_id = p_dispositivo_id AND id_en_dispositivo = v_ext AND empleado_id <> p_empleado_id) THEN
        RAISE EXCEPTION 'DISPOSITIVO_INVALIDO: Ese ID ya está asignado a otro empleado en este dispositivo.';
    END IF;

    INSERT INTO rrhh_dispositivo_usuarios (empresa_id, dispositivo_id, empleado_id, id_en_dispositivo)
    VALUES (p_empresa_id, p_dispositivo_id, p_empleado_id, v_ext)
    ON CONFLICT (dispositivo_id, empleado_id) DO UPDATE SET id_en_dispositivo = EXCLUDED.id_en_dispositivo, updated_at = NOW()
    RETURNING rrhh_dispositivo_usuarios.id INTO v_id;

    -- Las marcas que llegaron de ese ID antes de existir el vínculo quedan a nombre del empleado.
    UPDATE rrhh_marcas SET empleado_id = p_empleado_id, estado = 'valida', updated_at = NOW()
     WHERE dispositivo_id = p_dispositivo_id AND id_externo = v_ext AND estado = 'sin_asignar' AND deleted_at IS NULL;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_dispositivo_usuarios(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_dispositivo_usuarios(p_dispositivo_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empleado_id bigint, empleado_codigo character varying, empleado_nombre character varying, id_en_dispositivo character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT u.id, u.empleado_id, e.codigo, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR, u.id_en_dispositivo
      FROM rrhh_dispositivo_usuarios u
      JOIN rrhh_empleados e ON e.id = u.empleado_id
     WHERE u.dispositivo_id = p_dispositivo_id AND u.empresa_id = p_empresa_id
     ORDER BY u.id_en_dispositivo::TEXT;
END; $$;


--
-- Name: sp_rrhh_emp_concepto_create(bigint, bigint, bigint, numeric, date, date, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_emp_concepto_create(p_empresa_id bigint, p_empleado_id bigint, p_concepto_id bigint, p_monto numeric, p_desde date, p_hasta date, p_nota character varying) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rrhh_conceptos c WHERE c.id = p_concepto_id AND c.empresa_id = p_empresa_id AND c.deleted_at IS NULL AND c.is_active) THEN
        RAISE EXCEPTION 'CONCEPTO_INVALIDO: El concepto no existe o está inactivo.';
    END IF;
    IF COALESCE(p_monto, 0) <= 0 THEN RAISE EXCEPTION 'CONCEPTO_INVALIDO: El monto debe ser mayor que cero.'; END IF;
    IF p_desde IS NULL THEN RAISE EXCEPTION 'FECHA_INVALIDA: Indique desde cuándo aplica.'; END IF;
    IF p_hasta IS NOT NULL AND p_hasta < p_desde THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha final es anterior a la inicial.'; END IF;
    INSERT INTO rrhh_empleado_conceptos (empresa_id, empleado_id, concepto_id, monto, desde, hasta, nota)
    VALUES (p_empresa_id, p_empleado_id, p_concepto_id, p_monto, p_desde, p_hasta, NULLIF(btrim(COALESCE(p_nota, '')), ''))
    RETURNING rrhh_empleado_conceptos.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_emp_concepto_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_emp_concepto_delete(p_empresa_id bigint, p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n INTEGER;
BEGIN
    UPDATE rrhh_empleado_conceptos SET deleted_at = NOW(), updated_at = NOW() WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n > 0;
END; $$;


--
-- Name: sp_rrhh_emp_concepto_list(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_emp_concepto_list(p_empresa_id bigint, p_empleado_id bigint DEFAULT NULL::bigint) RETURNS TABLE(id bigint, empleado_id bigint, empleado_codigo character varying, empleado_nombre character varying, concepto_id bigint, concepto_codigo character varying, concepto_nombre character varying, tipo character varying, monto numeric, desde date, hasta date, nota character varying)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT ec.id, ec.empleado_id, e.codigo::VARCHAR, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR,
           ec.concepto_id, c.codigo::VARCHAR, c.nombre::VARCHAR, c.tipo::VARCHAR, ec.monto, ec.desde, ec.hasta, ec.nota::VARCHAR
      FROM rrhh_empleado_conceptos ec
      JOIN rrhh_empleados e ON e.id = ec.empleado_id
      JOIN rrhh_conceptos c ON c.id = ec.concepto_id
     WHERE ec.empresa_id = p_empresa_id AND ec.deleted_at IS NULL AND (p_empleado_id IS NULL OR ec.empleado_id = p_empleado_id)
     ORDER BY e.nombre, e.apellido1, c.nombre, ec.desde;
END; $$;


--
-- Name: sp_rrhh_emp_concepto_update(bigint, bigint, numeric, date, date, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_emp_concepto_update(p_empresa_id bigint, p_id bigint, p_monto numeric, p_desde date, p_hasta date, p_nota character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n INTEGER;
BEGIN
    IF COALESCE(p_monto, 0) <= 0 THEN RAISE EXCEPTION 'CONCEPTO_INVALIDO: El monto debe ser mayor que cero.'; END IF;
    IF p_desde IS NULL THEN RAISE EXCEPTION 'FECHA_INVALIDA: Indique desde cuándo aplica.'; END IF;
    IF p_hasta IS NOT NULL AND p_hasta < p_desde THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha final es anterior a la inicial.'; END IF;
    UPDATE rrhh_empleado_conceptos
       SET monto = p_monto, desde = p_desde, hasta = p_hasta, nota = NULLIF(btrim(COALESCE(p_nota, '')), ''), updated_at = NOW()
     WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n > 0;
END; $$;


--
-- Name: sp_rrhh_empleado_create(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_empleado_create(p_empresa_id bigint, p_d jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
    v_id     BIGINT;
    v_codigo VARCHAR;
    v_jefe   BIGINT := NULLIF(p_d->>'jefe_id', '')::BIGINT;
BEGIN
    PERFORM fn_rrhh_valida_empleado_refs(p_empresa_id, NULL, p_d);
    PERFORM fn_rrhh_valida_jefe(p_empresa_id, NULL, v_jefe);

    -- Código correlativo por empresa si no se indica (el candado evita repetirlo con dos altas a la vez)
    PERFORM pg_advisory_xact_lock(hashtext('rrhh_empleado_codigo'), p_empresa_id::int);
    v_codigo := NULLIF(btrim(COALESCE(p_d->>'codigo', '')), '');
    IF v_codigo IS NULL THEN
        SELECT lpad((COALESCE(MAX(substring(e.codigo from '^[0-9]{1,9}$')::INT), 0) + 1)::TEXT, 4, '0')
          INTO v_codigo FROM rrhh_empleados e WHERE e.empresa_id = p_empresa_id;
    END IF;

    INSERT INTO rrhh_empleados (
        empresa_id, funcionario_id, codigo, tipo_identificacion, identificacion, nombre, apellido1, apellido2,
        fecha_nacimiento, sexo, estado_civil, nacionalidad, email, telefono, direccion, tiene_conyuge, cantidad_hijos,
        contacto_emergencia_nombre, contacto_emergencia_telefono, contacto_emergencia_parentesco,
        departamento_id, puesto_id, jefe_id, sucursal_id, fecha_ingreso, tipo_contrato, fecha_fin_contrato,
        jornada, horas_semanales, periodo_pago, salario_base, moneda, banco, iban, numero_ccss, notas)
    VALUES (
        p_empresa_id, NULLIF(p_d->>'funcionario_id', '')::BIGINT, v_codigo,
        COALESCE(NULLIF(p_d->>'tipo_identificacion', ''), 'cedula'), btrim(p_d->>'identificacion'),
        btrim(p_d->>'nombre'), btrim(p_d->>'apellido1'), NULLIF(btrim(COALESCE(p_d->>'apellido2', '')), ''),
        NULLIF(p_d->>'fecha_nacimiento', '')::DATE, NULLIF(p_d->>'sexo', ''), NULLIF(p_d->>'estado_civil', ''),
        COALESCE(NULLIF(btrim(COALESCE(p_d->>'nacionalidad', '')), ''), 'Costarricense'),
        NULLIF(btrim(COALESCE(p_d->>'email', '')), ''), NULLIF(btrim(COALESCE(p_d->>'telefono', '')), ''),
        NULLIF(btrim(COALESCE(p_d->>'direccion', '')), ''),
        COALESCE((p_d->>'tiene_conyuge')::BOOLEAN, FALSE), COALESCE(NULLIF(p_d->>'cantidad_hijos', '')::INT, 0),
        NULLIF(btrim(COALESCE(p_d->>'contacto_emergencia_nombre', '')), ''),
        NULLIF(btrim(COALESCE(p_d->>'contacto_emergencia_telefono', '')), ''),
        NULLIF(btrim(COALESCE(p_d->>'contacto_emergencia_parentesco', '')), ''),
        NULLIF(p_d->>'departamento_id', '')::BIGINT, NULLIF(p_d->>'puesto_id', '')::BIGINT, v_jefe,
        NULLIF(p_d->>'sucursal_id', '')::BIGINT, (p_d->>'fecha_ingreso')::DATE,
        COALESCE(NULLIF(p_d->>'tipo_contrato', ''), 'indefinido'), NULLIF(p_d->>'fecha_fin_contrato', '')::DATE,
        COALESCE(NULLIF(p_d->>'jornada', ''), 'diurna'), COALESCE(NULLIF(p_d->>'horas_semanales', '')::NUMERIC, 48),
        COALESCE(NULLIF(p_d->>'periodo_pago', ''), 'mensual'), COALESCE(NULLIF(p_d->>'salario_base', '')::NUMERIC, 0),
        COALESCE(NULLIF(p_d->>'moneda', ''), 'CRC'), NULLIF(btrim(COALESCE(p_d->>'banco', '')), ''),
        NULLIF(upper(replace(COALESCE(p_d->>'iban', ''), ' ', '')), ''), NULLIF(btrim(COALESCE(p_d->>'numero_ccss', '')), ''),
        NULLIF(btrim(COALESCE(p_d->>'notas', '')), ''))
    RETURNING rrhh_empleados.id INTO v_id;

    PERFORM fn_rrhh_movimiento(p_empresa_id, v_id, 'ingreso', 'Ingreso a la empresa', NULL,
        jsonb_build_object('puesto_id', NULLIF(p_d->>'puesto_id', ''), 'departamento_id', NULLIF(p_d->>'departamento_id', ''),
                           'salario_base', COALESCE(NULLIF(p_d->>'salario_base', '')::NUMERIC, 0)),
        (p_d->>'fecha_ingreso')::DATE);
    RETURN v_id;
END; $_$;


--
-- Name: sp_rrhh_empleado_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_empleado_get(p_id bigint, p_empresa_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v JSONB;
BEGIN
    SELECT to_jsonb(e) || jsonb_build_object(
               'departamento_nombre', d.nombre,
               'puesto_nombre', p.nombre,
               'jefe_nombre', btrim(j.nombre || ' ' || j.apellido1 || ' ' || COALESCE(j.apellido2, '')),
               'funcionario_nombre', f.name)
      INTO v
      FROM rrhh_empleados e
      LEFT JOIN rrhh_departamentos d ON d.id = e.departamento_id
      LEFT JOIN rrhh_puestos       p ON p.id = e.puesto_id
      LEFT JOIN rrhh_empleados     j ON j.id = e.jefe_id
      LEFT JOIN funcionarios       f ON f.id = e.funcionario_id
     WHERE e.id = p_id AND e.empresa_id = p_empresa_id;
    RETURN v;
END; $$;


--
-- Name: sp_rrhh_empleado_horarios(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_empleado_horarios(p_empleado_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, horario_id bigint, horario_nombre character varying, vigente_desde date, vigente_hasta date, vigente boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT a.id, a.horario_id, h.nombre, a.vigente_desde, a.vigente_hasta,
           (a.vigente_desde <= CURRENT_DATE AND (a.vigente_hasta IS NULL OR a.vigente_hasta >= CURRENT_DATE))
      FROM rrhh_empleado_horarios a
      JOIN rrhh_horarios h ON h.id = a.horario_id
     WHERE a.empleado_id = p_empleado_id AND a.empresa_id = p_empresa_id AND a.deleted_at IS NULL
     ORDER BY a.vigente_desde DESC, a.id DESC;
END; $$;


--
-- Name: sp_rrhh_empleado_list(bigint, boolean, character varying, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_empleado_list(p_empresa_id bigint, p_eliminados boolean DEFAULT false, p_estado character varying DEFAULT NULL::character varying, p_departamento_id bigint DEFAULT NULL::bigint, p_buscar character varying DEFAULT NULL::character varying) RETURNS TABLE(id bigint, codigo character varying, identificacion character varying, nombre_completo character varying, email character varying, telefono character varying, departamento_id bigint, departamento_nombre character varying, puesto_id bigint, puesto_nombre character varying, jefe_id bigint, jefe_nombre character varying, fecha_ingreso date, fecha_salida date, tipo_contrato character varying, salario_base numeric, moneda character varying, estado character varying, subordinados bigint, deleted_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT e.id, e.codigo, e.identificacion,
           btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR,
           e.email, e.telefono, e.departamento_id, d.nombre, e.puesto_id, p.nombre,
           e.jefe_id, btrim(j.nombre || ' ' || j.apellido1 || ' ' || COALESCE(j.apellido2, ''))::VARCHAR,
           e.fecha_ingreso, e.fecha_salida, e.tipo_contrato, e.salario_base, e.moneda, e.estado,
           (SELECT COUNT(*) FROM rrhh_empleados s WHERE s.jefe_id = e.id AND s.deleted_at IS NULL AND s.estado <> 'liquidado'),
           e.deleted_at
    FROM rrhh_empleados e
    LEFT JOIN rrhh_departamentos d ON d.id = e.departamento_id
    LEFT JOIN rrhh_puestos       p ON p.id = e.puesto_id
    LEFT JOIN rrhh_empleados     j ON j.id = e.jefe_id
    WHERE e.empresa_id = p_empresa_id
      AND ((p_eliminados AND e.deleted_at IS NOT NULL) OR (NOT p_eliminados AND e.deleted_at IS NULL))
      AND (p_estado IS NULL OR p_estado = '' OR e.estado = p_estado)
      AND (p_departamento_id IS NULL OR e.departamento_id = p_departamento_id)
      AND (p_buscar IS NULL OR btrim(p_buscar) = '' OR
           lower(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, '') || ' ' || e.codigo || ' ' || e.identificacion)
               LIKE '%' || lower(btrim(p_buscar)) || '%')
    ORDER BY lower(e.apellido1), lower(COALESCE(e.apellido2, '')), lower(e.nombre);
END; $$;


--
-- Name: sp_rrhh_empleado_movimientos(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_empleado_movimientos(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, tipo character varying, fecha date, descripcion text, usuario_id bigint, created_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT m.id, m.tipo, m.fecha, m.descripcion, m.usuario_id, m.created_at
    FROM rrhh_empleado_movimientos m
    WHERE m.empleado_id = p_id AND m.empresa_id = p_empresa_id AND m.deleted_at IS NULL
    ORDER BY m.fecha DESC, m.id DESC;
END; $$;


--
-- Name: sp_rrhh_empleado_por_funcionario(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_empleado_por_funcionario(p_empresa_id bigint, p_funcionario_id bigint) RETURNS TABLE(id bigint, codigo character varying, nombre_completo character varying, departamento_id bigint, departamento_nombre character varying, jefe_id bigint, fecha_ingreso date, estado character varying, subordinados integer)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT e.id, e.codigo::VARCHAR, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR,
           e.departamento_id, dp.nombre::VARCHAR, e.jefe_id, e.fecha_ingreso, e.estado::VARCHAR,
           (SELECT COUNT(*)::INTEGER FROM rrhh_empleados s WHERE s.empresa_id = e.empresa_id AND s.jefe_id = e.id AND s.deleted_at IS NULL)
      FROM rrhh_empleados e LEFT JOIN rrhh_departamentos dp ON dp.id = e.departamento_id
     WHERE e.empresa_id = p_empresa_id AND e.funcionario_id = p_funcionario_id AND e.deleted_at IS NULL
     LIMIT 1;
END; $$;


--
-- Name: sp_rrhh_empleado_restore(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_empleado_restore(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE rrhh_empleados SET deleted_at = NULL, is_active = TRUE, updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NOT NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_empleado_set_estado(bigint, bigint, character varying, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_empleado_set_estado(p_id bigint, p_empresa_id bigint, p_estado character varying, p_motivo character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_actual VARCHAR;
BEGIN
    IF p_estado NOT IN ('activo', 'suspendido') THEN
        RAISE EXCEPTION 'ESTADO_INVALIDO: Estado no permitido.';
    END IF;
    SELECT estado INTO v_actual FROM rrhh_empleados
     WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF v_actual = 'liquidado' THEN
        RAISE EXCEPTION 'EMPLEADO_LIQUIDADO: El expediente está liquidado y ya no se puede modificar.';
    END IF;
    IF v_actual = p_estado THEN RETURN TRUE; END IF;

    UPDATE rrhh_empleados SET estado = p_estado, updated_at = NOW() WHERE id = p_id;
    PERFORM fn_rrhh_movimiento(p_empresa_id, p_id, CASE p_estado WHEN 'suspendido' THEN 'suspension' ELSE 'reactivacion' END,
        CASE p_estado WHEN 'suspendido' THEN 'Suspensión del contrato' ELSE 'Reactivación del contrato' END
            || COALESCE(': ' || NULLIF(btrim(p_motivo), ''), ''),
        jsonb_build_object('estado', v_actual), jsonb_build_object('estado', p_estado));
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_empleado_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_empleado_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_n FROM rrhh_empleados
     WHERE jefe_id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL AND estado <> 'liquidado';
    IF v_n > 0 THEN
        RAISE EXCEPTION 'EMPLEADO_EN_USO: Es jefe de % empleado(s); asígneles otro jefe antes de eliminarlo.', v_n;
    END IF;
    SELECT COUNT(*) INTO v_n FROM rrhh_departamentos
     WHERE jefe_empleado_id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'EMPLEADO_EN_USO: Es jefe de % departamento(s); asigne otro jefe antes de eliminarlo.', v_n;
    END IF;
    UPDATE rrhh_empleados SET is_active = FALSE, deleted_at = NOW(), updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_empleado_update(bigint, bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_empleado_update(p_id bigint, p_empresa_id bigint, p_d jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    o        rrhh_empleados%ROWTYPE;
    v_jefe   BIGINT := NULLIF(p_d->>'jefe_id', '')::BIGINT;
    v_depto  BIGINT := NULLIF(p_d->>'departamento_id', '')::BIGINT;
    v_puesto BIGINT := NULLIF(p_d->>'puesto_id', '')::BIGINT;
    v_sal    NUMERIC := COALESCE(NULLIF(p_d->>'salario_base', '')::NUMERIC, 0);
    v_cont   VARCHAR := COALESCE(NULLIF(p_d->>'tipo_contrato', ''), 'indefinido');
    v_jorn   VARCHAR := COALESCE(NULLIF(p_d->>'jornada', ''), 'diurna');
BEGIN
    SELECT * INTO o FROM rrhh_empleados WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF o.estado = 'liquidado' THEN
        RAISE EXCEPTION 'EMPLEADO_LIQUIDADO: El expediente está liquidado y ya no se puede modificar.';
    END IF;

    PERFORM fn_rrhh_valida_empleado_refs(p_empresa_id, p_id, p_d);
    PERFORM fn_rrhh_valida_jefe(p_empresa_id, p_id, v_jefe);

    UPDATE rrhh_empleados SET
        funcionario_id = NULLIF(p_d->>'funcionario_id', '')::BIGINT,
        codigo = COALESCE(NULLIF(btrim(COALESCE(p_d->>'codigo', '')), ''), o.codigo),
        tipo_identificacion = COALESCE(NULLIF(p_d->>'tipo_identificacion', ''), 'cedula'),
        identificacion = btrim(p_d->>'identificacion'),
        nombre = btrim(p_d->>'nombre'), apellido1 = btrim(p_d->>'apellido1'),
        apellido2 = NULLIF(btrim(COALESCE(p_d->>'apellido2', '')), ''),
        fecha_nacimiento = NULLIF(p_d->>'fecha_nacimiento', '')::DATE,
        sexo = NULLIF(p_d->>'sexo', ''), estado_civil = NULLIF(p_d->>'estado_civil', ''),
        nacionalidad = COALESCE(NULLIF(btrim(COALESCE(p_d->>'nacionalidad', '')), ''), 'Costarricense'),
        email = NULLIF(btrim(COALESCE(p_d->>'email', '')), ''), telefono = NULLIF(btrim(COALESCE(p_d->>'telefono', '')), ''),
        direccion = NULLIF(btrim(COALESCE(p_d->>'direccion', '')), ''),
        tiene_conyuge = COALESCE((p_d->>'tiene_conyuge')::BOOLEAN, FALSE),
        cantidad_hijos = COALESCE(NULLIF(p_d->>'cantidad_hijos', '')::INT, 0),
        contacto_emergencia_nombre = NULLIF(btrim(COALESCE(p_d->>'contacto_emergencia_nombre', '')), ''),
        contacto_emergencia_telefono = NULLIF(btrim(COALESCE(p_d->>'contacto_emergencia_telefono', '')), ''),
        contacto_emergencia_parentesco = NULLIF(btrim(COALESCE(p_d->>'contacto_emergencia_parentesco', '')), ''),
        departamento_id = v_depto, puesto_id = v_puesto, jefe_id = v_jefe,
        sucursal_id = NULLIF(p_d->>'sucursal_id', '')::BIGINT,
        fecha_ingreso = (p_d->>'fecha_ingreso')::DATE,
        tipo_contrato = v_cont, fecha_fin_contrato = NULLIF(p_d->>'fecha_fin_contrato', '')::DATE,
        jornada = v_jorn, horas_semanales = COALESCE(NULLIF(p_d->>'horas_semanales', '')::NUMERIC, 48),
        periodo_pago = COALESCE(NULLIF(p_d->>'periodo_pago', ''), 'mensual'),
        salario_base = v_sal, moneda = COALESCE(NULLIF(p_d->>'moneda', ''), 'CRC'),
        banco = NULLIF(btrim(COALESCE(p_d->>'banco', '')), ''),
        iban = NULLIF(upper(replace(COALESCE(p_d->>'iban', ''), ' ', '')), ''),
        numero_ccss = NULLIF(btrim(COALESCE(p_d->>'numero_ccss', '')), ''),
        notas = NULLIF(btrim(COALESCE(p_d->>'notas', '')), ''),
        updated_at = NOW()
    WHERE id = p_id;

    -- Historial del expediente: solo lo que cambió de la relación laboral
    IF o.puesto_id IS DISTINCT FROM v_puesto THEN
        PERFORM fn_rrhh_movimiento(p_empresa_id, p_id, 'cambio_puesto',
            'Puesto: ' || COALESCE((SELECT nombre FROM rrhh_puestos WHERE id = o.puesto_id), 'sin puesto') || ' → ' ||
                          COALESCE((SELECT nombre FROM rrhh_puestos WHERE id = v_puesto), 'sin puesto'),
            jsonb_build_object('puesto_id', o.puesto_id), jsonb_build_object('puesto_id', v_puesto));
    END IF;
    IF o.departamento_id IS DISTINCT FROM v_depto THEN
        PERFORM fn_rrhh_movimiento(p_empresa_id, p_id, 'cambio_departamento',
            'Departamento: ' || COALESCE((SELECT nombre FROM rrhh_departamentos WHERE id = o.departamento_id), 'sin departamento') || ' → ' ||
                                COALESCE((SELECT nombre FROM rrhh_departamentos WHERE id = v_depto), 'sin departamento'),
            jsonb_build_object('departamento_id', o.departamento_id), jsonb_build_object('departamento_id', v_depto));
    END IF;
    IF o.jefe_id IS DISTINCT FROM v_jefe THEN
        PERFORM fn_rrhh_movimiento(p_empresa_id, p_id, 'cambio_jefe',
            'Jefe inmediato: ' ||
              COALESCE((SELECT btrim(nombre || ' ' || apellido1) FROM rrhh_empleados WHERE id = o.jefe_id), 'sin jefe') || ' → ' ||
              COALESCE((SELECT btrim(nombre || ' ' || apellido1) FROM rrhh_empleados WHERE id = v_jefe), 'sin jefe'),
            jsonb_build_object('jefe_id', o.jefe_id), jsonb_build_object('jefe_id', v_jefe));
    END IF;
    IF o.salario_base IS DISTINCT FROM v_sal THEN
        PERFORM fn_rrhh_movimiento(p_empresa_id, p_id, 'ajuste_salarial',
            'Salario base: ' || to_char(o.salario_base, 'FM999G999G999D00') || ' → ' || to_char(v_sal, 'FM999G999G999D00'),
            jsonb_build_object('salario_base', o.salario_base), jsonb_build_object('salario_base', v_sal));
    END IF;
    IF o.tipo_contrato IS DISTINCT FROM v_cont OR o.jornada IS DISTINCT FROM v_jorn THEN
        PERFORM fn_rrhh_movimiento(p_empresa_id, p_id, 'cambio_contrato',
            'Contrato/jornada: ' || o.tipo_contrato || ' ' || o.jornada || ' → ' || v_cont || ' ' || v_jorn,
            jsonb_build_object('tipo_contrato', o.tipo_contrato, 'jornada', o.jornada),
            jsonb_build_object('tipo_contrato', v_cont, 'jornada', v_jorn));
    END IF;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_feriado_cargar(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_feriado_cargar(p_empresa_id bigint, p_items jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n INTEGER;
BEGIN
    WITH ins AS (
        INSERT INTO rrhh_feriados (empresa_id, fecha, nombre, pago_obligatorio)
        SELECT p_empresa_id, (x->>'fecha')::DATE, x->>'nombre', COALESCE((x->>'pago_obligatorio')::BOOLEAN, TRUE)
          FROM jsonb_array_elements(p_items) x
         WHERE NOT EXISTS (SELECT 1 FROM rrhh_feriados f WHERE f.empresa_id = p_empresa_id AND f.fecha = (x->>'fecha')::DATE AND f.deleted_at IS NULL)
        RETURNING 1)
    SELECT COUNT(*) INTO v_n FROM ins;
    RETURN v_n;
END; $$;


--
-- Name: sp_rrhh_feriado_create(bigint, date, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_feriado_create(p_empresa_id bigint, p_fecha date, p_nombre character varying, p_pago_obligatorio boolean) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO rrhh_feriados (empresa_id, fecha, nombre, pago_obligatorio)
    VALUES (p_empresa_id, p_fecha, btrim(p_nombre), COALESCE(p_pago_obligatorio, TRUE))
    RETURNING rrhh_feriados.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_feriado_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_feriado_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE rrhh_feriados SET deleted_at = NOW(), updated_at = NOW()
     WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_feriado_list(bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_feriado_list(p_empresa_id bigint, p_anio integer) RETURNS TABLE(id bigint, fecha date, nombre character varying, pago_obligatorio boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT f.id, f.fecha, f.nombre, f.pago_obligatorio
      FROM rrhh_feriados f
     WHERE f.empresa_id = p_empresa_id AND f.deleted_at IS NULL AND EXTRACT(YEAR FROM f.fecha) = p_anio
     ORDER BY f.fecha;
END; $$;


--
-- Name: sp_rrhh_feriado_update(bigint, bigint, date, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_feriado_update(p_id bigint, p_empresa_id bigint, p_fecha date, p_nombre character varying, p_pago_obligatorio boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE rrhh_feriados SET fecha = p_fecha, nombre = btrim(p_nombre), pago_obligatorio = COALESCE(p_pago_obligatorio, TRUE), updated_at = NOW()
     WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_horario_asignar(bigint, bigint, bigint, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_horario_asignar(p_empresa_id bigint, p_empleado_id bigint, p_horario_id bigint, p_desde date) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_emp    RECORD;
    v_id     BIGINT;
    v_nombre VARCHAR;
BEGIN
    SELECT e.id, e.estado, e.fecha_ingreso INTO v_emp
      FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.'; END IF;
    IF v_emp.estado = 'liquidado' THEN RAISE EXCEPTION 'EMPLEADO_LIQUIDADO: El expediente está liquidado y no admite cambios.'; END IF;
    SELECT h.nombre INTO v_nombre FROM rrhh_horarios h
     WHERE h.id = p_horario_id AND h.empresa_id = p_empresa_id AND h.deleted_at IS NULL AND h.is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'REF_INVALIDA: El horario no existe o está inactivo.'; END IF;
    IF EXISTS (SELECT 1 FROM rrhh_empleado_horarios a WHERE a.empleado_id = p_empleado_id AND a.deleted_at IS NULL AND a.vigente_desde >= p_desde) THEN
        RAISE EXCEPTION 'FECHA_INVALIDA: El empleado ya tiene un horario asignado desde esa fecha o una posterior; indique una fecha más reciente.';
    END IF;

    UPDATE rrhh_empleado_horarios SET vigente_hasta = p_desde - 1, updated_at = NOW()
     WHERE empleado_id = p_empleado_id AND deleted_at IS NULL AND (vigente_hasta IS NULL OR vigente_hasta >= p_desde);

    INSERT INTO rrhh_empleado_horarios (empresa_id, empleado_id, horario_id, vigente_desde)
    VALUES (p_empresa_id, p_empleado_id, p_horario_id, p_desde) RETURNING rrhh_empleado_horarios.id INTO v_id;

    PERFORM fn_rrhh_movimiento(p_empresa_id, p_empleado_id, 'horario',
        'Horario «' || v_nombre || '» desde ' || to_char(p_desde, 'DD/MM/YYYY'), NULL,
        jsonb_build_object('horario_id', p_horario_id, 'vigente_desde', p_desde), p_desde);
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_horario_create(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_horario_create(p_empresa_id bigint, p_datos jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT;
BEGIN
    PERFORM fn_rrhh_valida_horario(COALESCE(p_datos->>'jornada', 'diurna'), p_datos->'dias');
    INSERT INTO rrhh_horarios (empresa_id, nombre, descripcion, jornada, tolerancia_entrada_min, tolerancia_salida_min, minutos_minimos_extra)
    VALUES (p_empresa_id, btrim(p_datos->>'nombre'), NULLIF(btrim(COALESCE(p_datos->>'descripcion', '')), ''),
            COALESCE(p_datos->>'jornada', 'diurna'),
            COALESCE((p_datos->>'tolerancia_entrada_min')::SMALLINT, 10),
            COALESCE((p_datos->>'tolerancia_salida_min')::SMALLINT, 0),
            COALESCE((p_datos->>'minutos_minimos_extra')::SMALLINT, 30))
    RETURNING rrhh_horarios.id INTO v_id;
    PERFORM fn_rrhh_horario_guardar_dias(v_id, p_datos->'dias');
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_horario_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_horario_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, nombre character varying, descripcion character varying, jornada character varying, tolerancia_entrada_min smallint, tolerancia_salida_min smallint, minutos_minimos_extra smallint, is_active boolean, deleted_at timestamp without time zone, dias jsonb, horas_semanales numeric, empleados bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT l.id, l.empresa_id, l.nombre, l.descripcion, l.jornada, l.tolerancia_entrada_min, l.tolerancia_salida_min,
           l.minutos_minimos_extra, l.is_active, l.deleted_at, l.dias, l.horas_semanales, l.empleados
      FROM (SELECT * FROM sp_rrhh_horario_list(p_empresa_id, FALSE)
            UNION ALL SELECT * FROM sp_rrhh_horario_list(p_empresa_id, TRUE)) l
     WHERE l.id = p_id;
END; $$;


--
-- Name: sp_rrhh_horario_list(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_horario_list(p_empresa_id bigint, p_eliminados boolean DEFAULT false) RETURNS TABLE(id bigint, empresa_id bigint, nombre character varying, descripcion character varying, jornada character varying, tolerancia_entrada_min smallint, tolerancia_salida_min smallint, minutos_minimos_extra smallint, is_active boolean, deleted_at timestamp without time zone, dias jsonb, horas_semanales numeric, empleados bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT h.id, h.empresa_id, h.nombre, h.descripcion, h.jornada, h.tolerancia_entrada_min, h.tolerancia_salida_min,
           h.minutos_minimos_extra, h.is_active, h.deleted_at,
           COALESCE((SELECT jsonb_agg(jsonb_build_object('dia_semana', d.dia_semana,
                                                         'hora_entrada', to_char(d.hora_entrada, 'HH24:MI'),
                                                         'hora_salida', to_char(d.hora_salida, 'HH24:MI'),
                                                         'minutos_descanso', d.minutos_descanso) ORDER BY d.dia_semana)
                       FROM rrhh_horario_dias d WHERE d.horario_id = h.id), '[]'::jsonb),
           COALESCE((SELECT round(SUM(fn_rrhh_minutos_dia(d.hora_entrada, d.hora_salida, d.minutos_descanso)) / 60.0, 2)
                       FROM rrhh_horario_dias d WHERE d.horario_id = h.id), 0),
           (SELECT COUNT(*) FROM rrhh_empleado_horarios a
              JOIN rrhh_empleados e ON e.id = a.empleado_id AND e.deleted_at IS NULL AND e.estado <> 'liquidado'
             WHERE a.horario_id = h.id AND a.deleted_at IS NULL
               AND a.vigente_desde <= CURRENT_DATE AND (a.vigente_hasta IS NULL OR a.vigente_hasta >= CURRENT_DATE))
    FROM rrhh_horarios h
    WHERE h.empresa_id = p_empresa_id
      AND ((p_eliminados AND h.deleted_at IS NOT NULL) OR (NOT p_eliminados AND h.deleted_at IS NULL))
    ORDER BY lower(h.nombre);
END; $$;


--
-- Name: sp_rrhh_horario_restore(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_horario_restore(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE rrhh_horarios SET deleted_at = NULL, updated_at = NOW()
     WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NOT NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_horario_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_horario_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_horarios WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RETURN FALSE;
    END IF;
    IF EXISTS (SELECT 1 FROM rrhh_empleado_horarios a JOIN rrhh_empleados e ON e.id = a.empleado_id AND e.deleted_at IS NULL AND e.estado <> 'liquidado'
                WHERE a.horario_id = p_id AND a.deleted_at IS NULL AND (a.vigente_hasta IS NULL OR a.vigente_hasta >= CURRENT_DATE)) THEN
        RAISE EXCEPTION 'HORARIO_EN_USO: El horario está asignado a empleados vigentes; reasígnelos antes de eliminarlo.';
    END IF;
    UPDATE rrhh_horarios SET deleted_at = NOW(), updated_at = NOW() WHERE id = p_id AND empresa_id = p_empresa_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_horario_update(bigint, bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_horario_update(p_id bigint, p_empresa_id bigint, p_datos jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_horarios WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RETURN FALSE;
    END IF;
    PERFORM fn_rrhh_valida_horario(COALESCE(p_datos->>'jornada', 'diurna'), p_datos->'dias');
    UPDATE rrhh_horarios SET
        nombre = btrim(p_datos->>'nombre'),
        descripcion = NULLIF(btrim(COALESCE(p_datos->>'descripcion', '')), ''),
        jornada = COALESCE(p_datos->>'jornada', 'diurna'),
        tolerancia_entrada_min = COALESCE((p_datos->>'tolerancia_entrada_min')::SMALLINT, 10),
        tolerancia_salida_min = COALESCE((p_datos->>'tolerancia_salida_min')::SMALLINT, 0),
        minutos_minimos_extra = COALESCE((p_datos->>'minutos_minimos_extra')::SMALLINT, 30),
        is_active = COALESCE((p_datos->>'is_active')::BOOLEAN, TRUE),
        updated_at = NOW()
     WHERE id = p_id AND empresa_id = p_empresa_id;
    PERFORM fn_rrhh_horario_guardar_dias(p_id, p_datos->'dias');
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_horas_extra(bigint, date, date, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_horas_extra(p_empresa_id bigint, p_desde date, p_hasta date, p_empleado_id bigint DEFAULT NULL::bigint, p_departamento_id bigint DEFAULT NULL::bigint) RETURNS TABLE(empleado_id bigint, empleado_codigo character varying, empleado_nombre character varying, departamento_nombre character varying, dias_con_extra integer, minutos_calculados integer, minutos_pendientes integer, minutos_aprobados integer, minutos_aprobados_1_5 integer, minutos_aprobados_2_0 integer, valor_hora numeric, monto_aprobado numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    WITH r AS (
        SELECT * FROM sp_rrhh_asistencia_resumen(p_empresa_id, p_desde, p_hasta, p_empleado_id, p_departamento_id, NULL)
         WHERE minutos_extra > 0
    ),
    t AS (
        SELECT r.empleado_id AS eid, MAX(r.empleado_codigo) AS cod, MAX(r.empleado_nombre) AS nom, MAX(r.departamento_nombre) AS dep,
               COUNT(*)::INTEGER AS dias, SUM(r.minutos_extra)::INTEGER AS calc,
               COALESCE(SUM(r.minutos_extra) FILTER (WHERE r.extra_estado = 'pendiente'), 0)::INTEGER AS pend,
               COALESCE(SUM(r.extra_minutos_aprobados), 0)::INTEGER AS aprob,
               COALESCE(SUM(r.extra_minutos_aprobados) FILTER (WHERE r.factor_extra = 1.5), 0)::INTEGER AS a15,
               COALESCE(SUM(r.extra_minutos_aprobados) FILTER (WHERE r.factor_extra = 2.0), 0)::INTEGER AS a20
          FROM r GROUP BY r.empleado_id
    )
    SELECT t.eid, t.cod::VARCHAR, t.nom::VARCHAR, t.dep::VARCHAR, t.dias, t.calc, t.pend, t.aprob, t.a15, t.a20,
           round(v.hora, 2),
           round(v.hora * (t.a15 * 1.5 + t.a20 * 2.0) / 60.0, 2)
      FROM t
      JOIN rrhh_empleados e ON e.id = t.eid
      CROSS JOIN LATERAL (
          SELECT e.salario_base / (CASE e.periodo_pago WHEN 'mensual' THEN 30 WHEN 'quincenal' THEN 15 ELSE 6 END)
                 / (CASE e.jornada WHEN 'mixta' THEN 7 WHEN 'nocturna' THEN 6 ELSE 8 END) AS hora
      ) v
     ORDER BY t.nom;
END; $$;


--
-- Name: sp_rrhh_inc_actualizar(bigint, bigint, character varying, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_inc_actualizar(p_empresa_id bigint, p_id bigint, p_boleta character varying, p_obs character varying, p_completa boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n INTEGER;
BEGIN
    UPDATE rrhh_incapacidades
       SET numero_boleta = NULLIF(btrim(COALESCE(p_boleta, '')), ''), observaciones = NULLIF(btrim(COALESCE(p_obs, '')), ''),
           patrono_completa = COALESCE(p_completa, patrono_completa), updated_at = NOW()
     WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL AND estado = 'registrada';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n > 0;
END; $$;


--
-- Name: sp_rrhh_inc_anular(bigint, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_inc_anular(p_empresa_id bigint, p_id bigint, p_nota character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_i    RECORD;
    v_nota VARCHAR := NULLIF(btrim(COALESCE(p_nota, '')), '');
    v_user BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
BEGIN
    SELECT i.* INTO v_i FROM rrhh_incapacidades i WHERE i.id = p_id AND i.empresa_id = p_empresa_id AND i.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF v_i.estado <> 'registrada' THEN RAISE EXCEPTION 'INCAPACIDAD_INVALIDA: La incapacidad ya estaba anulada.'; END IF;
    IF v_nota IS NULL THEN RAISE EXCEPTION 'INCAPACIDAD_INVALIDA: Indique el motivo de la anulación.'; END IF;
    IF v_i.vac_movimiento_id IS NOT NULL THEN
        UPDATE rrhh_vacaciones_movimientos SET deleted_at = NOW(), updated_at = NOW() WHERE id = v_i.vac_movimiento_id AND deleted_at IS NULL;
    END IF;
    UPDATE rrhh_incapacidades
       SET estado = 'anulada', anulada_por = v_user, anulada_at = NOW(), anulada_nota = v_nota, vac_repuestos = 0, vac_movimiento_id = NULL, updated_at = NOW()
     WHERE id = p_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_inc_list(bigint, bigint, character varying, character varying, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_inc_list(p_empresa_id bigint, p_empleado_id bigint DEFAULT NULL::bigint, p_tipo character varying DEFAULT NULL::character varying, p_estado character varying DEFAULT NULL::character varying, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date) RETURNS TABLE(id bigint, empleado_id bigint, empleado_codigo character varying, empleado_nombre character varying, departamento_nombre character varying, tipo character varying, entidad character varying, fecha_inicio date, fecha_fin date, dias integer, numero_boleta character varying, observaciones character varying, patrono_completa boolean, valor_dia numeric, estado character varying, vac_repuestos numeric, anulada_nota character varying, monto_patrono numeric, monto_entidad numeric, monto_complemento numeric, created_at timestamp without time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT i.id, i.empleado_id, e.codigo::VARCHAR, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR,
           dp.nombre::VARCHAR, i.tipo::VARCHAR, i.entidad::VARCHAR, i.fecha_inicio, i.fecha_fin, i.dias, i.numero_boleta::VARCHAR, i.observaciones::VARCHAR,
           i.patrono_completa, i.valor_dia, i.estado::VARCHAR, i.vac_repuestos, i.anulada_nota::VARCHAR,
           COALESCE(m.mp, 0), COALESCE(m.me, 0), COALESCE(m.mc, 0), i.created_at
      FROM rrhh_incapacidades i
      JOIN rrhh_empleados e ON e.id = i.empleado_id
      LEFT JOIN rrhh_departamentos dp ON dp.id = e.departamento_id
      LEFT JOIN LATERAL (
          SELECT SUM(x.monto_patrono) AS mp, SUM(x.monto_entidad) AS me, SUM(x.monto_complemento) AS mc
            FROM fn_rrhh_inc_tramos(i.empleado_id, i.tipo, i.fecha_inicio, i.fecha_fin, i.valor_dia, i.patrono_completa, i.id) x
           WHERE i.estado = 'registrada'
      ) m ON TRUE
     WHERE i.empresa_id = p_empresa_id AND i.deleted_at IS NULL
       AND (p_empleado_id IS NULL OR i.empleado_id = p_empleado_id)
       AND (p_tipo IS NULL OR i.tipo = p_tipo)
       AND (p_estado IS NULL OR i.estado = p_estado)
       AND (p_desde IS NULL OR i.fecha_fin >= p_desde)
       AND (p_hasta IS NULL OR i.fecha_inicio <= p_hasta)
     ORDER BY i.fecha_inicio DESC, i.id DESC
     LIMIT 300;
END; $$;


--
-- Name: sp_rrhh_inc_previsualizar(bigint, bigint, character varying, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_inc_previsualizar(p_empresa_id bigint, p_empleado_id bigint, p_tipo character varying, p_inicio date, p_fin date) RETURNS TABLE(dias integer, dias_previos integer, valor_dia numeric, entidad character varying, vac_dias numeric, valida boolean, mensaje character varying)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_msg VARCHAR := NULL;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.';
    END IF;
    dias := CASE WHEN p_fin >= p_inicio AND p_fin - p_inicio <= 730 THEN p_fin - p_inicio + 1 ELSE 0 END;
    dias_previos := CASE WHEN dias > 0 AND p_tipo IN ('enfermedad', 'maternidad', 'riesgo_trabajo')
                         THEN fn_rrhh_inc_dias_previos(p_empleado_id, p_tipo, p_inicio, NULL) ELSE 0 END;
    valor_dia := COALESCE(fn_rrhh_inc_valor_dia(p_empleado_id), 0);
    entidad := CASE WHEN p_tipo = 'riesgo_trabajo' THEN 'INS' ELSE 'CCSS' END;
    vac_dias := CASE WHEN dias > 0 THEN fn_rrhh_inc_vac_traslape(p_empresa_id, p_empleado_id, p_inicio, p_fin) ELSE 0 END;
    BEGIN
        PERFORM fn_rrhh_inc_validar(p_empresa_id, p_empleado_id, p_tipo, p_inicio, p_fin);
    EXCEPTION WHEN OTHERS THEN
        v_msg := regexp_replace(SQLERRM, '^[A-Z_]+:\s*', '');
    END;
    valida := v_msg IS NULL;
    mensaje := v_msg;
    RETURN NEXT;
END; $$;


--
-- Name: sp_rrhh_inc_registrar(bigint, bigint, character varying, date, date, character varying, character varying, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_inc_registrar(p_empresa_id bigint, p_empleado_id bigint, p_tipo character varying, p_inicio date, p_fin date, p_boleta character varying, p_obs character varying, p_completa boolean DEFAULT true, p_reponer_vac boolean DEFAULT false) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_user BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    v_id   BIGINT;
    v_vac  NUMERIC;
    v_mov  BIGINT;
BEGIN
    PERFORM fn_rrhh_inc_validar(p_empresa_id, p_empleado_id, p_tipo, p_inicio, p_fin);
    INSERT INTO rrhh_incapacidades (empresa_id, empleado_id, tipo, entidad, fecha_inicio, fecha_fin, dias, numero_boleta, observaciones,
                                    patrono_completa, valor_dia, creada_por)
    VALUES (p_empresa_id, p_empleado_id, p_tipo, CASE WHEN p_tipo = 'riesgo_trabajo' THEN 'INS' ELSE 'CCSS' END, p_inicio, p_fin,
            p_fin - p_inicio + 1, NULLIF(btrim(COALESCE(p_boleta, '')), ''), NULLIF(btrim(COALESCE(p_obs, '')), ''),
            COALESCE(p_completa, TRUE), COALESCE(fn_rrhh_inc_valor_dia(p_empleado_id), 0), v_user)
    RETURNING id INTO v_id;

    IF p_reponer_vac THEN
        v_vac := fn_rrhh_inc_vac_traslape(p_empresa_id, p_empleado_id, p_inicio, p_fin);
        IF v_vac > 0 THEN
            INSERT INTO rrhh_vacaciones_movimientos (empresa_id, empleado_id, tipo, dias, fecha, motivo, usuario_id)
            VALUES (p_empresa_id, p_empleado_id, 'ajuste', v_vac, CURRENT_DATE,
                    'Incapacidad #' || v_id || ' dentro de vacaciones aprobadas (se reponen los días)', v_user)
            RETURNING id INTO v_mov;
            UPDATE rrhh_incapacidades SET vac_repuestos = v_vac, vac_movimiento_id = v_mov WHERE id = v_id;
        END IF;
    END IF;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_inc_subsidio(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_inc_subsidio(p_empresa_id bigint, p_id bigint) RETURNS TABLE(desde date, hasta date, dias integer, patrono_pct numeric, entidad_pct numeric, complemento_pct numeric, monto_patrono numeric, monto_entidad numeric, monto_complemento numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_i RECORD;
BEGIN
    SELECT i.* INTO v_i FROM rrhh_incapacidades i WHERE i.id = p_id AND i.empresa_id = p_empresa_id AND i.deleted_at IS NULL;
    IF NOT FOUND OR v_i.estado <> 'registrada' THEN RETURN; END IF;
    RETURN QUERY SELECT * FROM fn_rrhh_inc_tramos(v_i.empleado_id, v_i.tipo, v_i.fecha_inicio, v_i.fecha_fin, v_i.valor_dia, v_i.patrono_completa, v_i.id);
END; $$;


--
-- Name: sp_rrhh_inc_tramos_calc(bigint, bigint, character varying, date, date, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_inc_tramos_calc(p_empresa_id bigint, p_empleado_id bigint, p_tipo character varying, p_inicio date, p_fin date, p_completa boolean DEFAULT true) RETURNS TABLE(desde date, hasta date, dias integer, patrono_pct numeric, entidad_pct numeric, complemento_pct numeric, monto_patrono numeric, monto_entidad numeric, monto_complemento numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.';
    END IF;
    IF p_tipo NOT IN ('enfermedad', 'maternidad', 'riesgo_trabajo') OR p_fin < p_inicio OR p_fin - p_inicio > 730 THEN RETURN; END IF;
    RETURN QUERY SELECT * FROM fn_rrhh_inc_tramos(p_empleado_id, p_tipo, p_inicio, p_fin, COALESCE(fn_rrhh_inc_valor_dia(p_empleado_id), 0), COALESCE(p_completa, TRUE), NULL);
END; $$;


--
-- Name: sp_rrhh_marca_list(bigint, date, date, bigint, character varying, character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_marca_list(p_empresa_id bigint, p_desde date, p_hasta date, p_empleado_id bigint DEFAULT NULL::bigint, p_estado character varying DEFAULT NULL::character varying, p_origen character varying DEFAULT NULL::character varying, p_limite integer DEFAULT 1000) RETURNS TABLE(id bigint, empleado_id bigint, empleado_codigo character varying, empleado_nombre character varying, fecha_hora timestamp without time zone, tipo character varying, origen character varying, metodo character varying, dispositivo_id bigint, dispositivo_nombre character varying, id_externo character varying, estado character varying, motivo character varying, registrado_por bigint, resuelto_por bigint, resuelto_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF p_hasta - p_desde > 93 THEN RAISE EXCEPTION 'FECHA_INVALIDA: El rango de fechas no puede pasar de 93 días.'; END IF;
    RETURN QUERY
    WITH ses AS (
        SELECT * FROM fn_rrhh_sesiones(p_empresa_id, p_empleado_id, (p_desde - 1)::TIMESTAMP, (p_hasta + 2)::TIMESTAMP)
    )
    SELECT m.id, m.empleado_id, e.codigo, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR,
           m.fecha_hora,
           (CASE WHEN EXISTS (SELECT 1 FROM ses s WHERE s.s_entrada_id = m.id) THEN 'entrada'
                 WHEN EXISTS (SELECT 1 FROM ses s WHERE s.s_salida_id = m.id) THEN 'salida' END)::VARCHAR,
           m.origen, m.metodo, m.dispositivo_id, d.nombre, m.id_externo, m.estado, m.motivo, m.registrado_por, m.resuelto_por, m.resuelto_at
      FROM rrhh_marcas m
      LEFT JOIN rrhh_empleados e ON e.id = m.empleado_id
      LEFT JOIN rrhh_dispositivos d ON d.id = m.dispositivo_id
     WHERE m.empresa_id = p_empresa_id AND m.deleted_at IS NULL
       AND m.fecha_hora >= p_desde::TIMESTAMP AND m.fecha_hora < (p_hasta + 1)::TIMESTAMP
       AND (p_empleado_id IS NULL OR m.empleado_id = p_empleado_id)
       AND (p_estado IS NULL OR m.estado = p_estado)
       AND (p_origen IS NULL OR m.origen = p_origen)
     ORDER BY m.fecha_hora DESC, m.id DESC
     LIMIT GREATEST(1, LEAST(COALESCE(p_limite, 1000), 5000));
END; $$;


--
-- Name: sp_rrhh_marca_registrar(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_marca_registrar(p_empresa_id bigint, p_datos jsonb) RETURNS TABLE(marca_id bigint, duplicada boolean, tipo character varying, estado character varying, empleado_id bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_emp     BIGINT := NULLIF(p_datos->>'empleado_id', '')::BIGINT;
    v_fecha   TIMESTAMP := (p_datos->>'fecha_hora')::TIMESTAMP;
    v_disp    BIGINT := NULLIF(p_datos->>'dispositivo_id', '')::BIGINT;
    v_ext     VARCHAR := NULLIF(btrim(COALESCE(p_datos->>'id_externo', '')), '');
    v_ref     VARCHAR := NULLIF(btrim(COALESCE(p_datos->>'referencia_externa', '')), '');
    v_estado  VARCHAR := COALESCE(p_datos->>'estado', 'valida');
    v_id      BIGINT;
    v_tipo    VARCHAR := NULL;
    v_empl    RECORD;
BEGIN
    IF v_fecha IS NULL THEN RAISE EXCEPTION 'MARCA_INVALIDA: Falta la fecha y hora de la marca.'; END IF;
    IF v_fecha > NOW() + INTERVAL '5 minutes' THEN RAISE EXCEPTION 'MARCA_INVALIDA: La marca no puede estar en el futuro.'; END IF;

    -- Reenvío de una marca de dispositivo ya guardada
    IF v_disp IS NOT NULL AND v_ref IS NOT NULL THEN
        SELECT m.id, m.empleado_id, m.estado INTO v_id, v_emp, v_estado
          FROM rrhh_marcas m WHERE m.dispositivo_id = v_disp AND m.referencia_externa = v_ref;
        IF FOUND THEN
            RETURN QUERY SELECT v_id, TRUE, NULL::VARCHAR, v_estado, v_emp; RETURN;
        END IF;
        v_estado := COALESCE(p_datos->>'estado', 'valida');
    END IF;

    -- Usuario del dispositivo → empleado
    IF v_emp IS NULL AND v_disp IS NOT NULL AND v_ext IS NOT NULL THEN
        SELECT u.empleado_id INTO v_emp FROM rrhh_dispositivo_usuarios u
         WHERE u.dispositivo_id = v_disp AND u.id_en_dispositivo = v_ext AND u.empresa_id = p_empresa_id;
        IF v_emp IS NULL THEN v_estado := 'sin_asignar'; END IF;
    END IF;
    IF v_emp IS NULL AND v_estado <> 'sin_asignar' THEN
        RAISE EXCEPTION 'MARCA_INVALIDA: La marca no indica el empleado.';
    END IF;

    IF v_emp IS NOT NULL THEN
        SELECT e.estado, e.fecha_ingreso, e.fecha_salida INTO v_empl
          FROM rrhh_empleados e WHERE e.id = v_emp AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL;
        IF NOT FOUND THEN RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.'; END IF;
        IF v_empl.estado = 'liquidado' THEN RAISE EXCEPTION 'EMPLEADO_LIQUIDADO: El expediente está liquidado y no admite marcas.'; END IF;

        SELECT m.id INTO v_id FROM rrhh_marcas m
         WHERE m.empleado_id = v_emp AND m.deleted_at IS NULL AND m.estado IN ('valida', 'pendiente')
           AND abs(EXTRACT(EPOCH FROM (m.fecha_hora - v_fecha))) < 60
         LIMIT 1;
        IF FOUND THEN
            RETURN QUERY SELECT v_id, TRUE, NULL::VARCHAR, 'valida'::VARCHAR, v_emp; RETURN;
        END IF;
    END IF;

    INSERT INTO rrhh_marcas (empresa_id, empleado_id, fecha_hora, origen, metodo, dispositivo_id, agente_id, id_externo,
                             referencia_externa, estado, motivo, ip, registrado_por)
    VALUES (p_empresa_id, v_emp, v_fecha, p_datos->>'origen', COALESCE(p_datos->>'metodo', 'pin'), v_disp,
            NULLIF(p_datos->>'agente_id', '')::BIGINT, v_ext, v_ref, v_estado, NULLIF(btrim(COALESCE(p_datos->>'motivo', '')), ''),
            LEFT(p_datos->>'ip', 45), NULLIF(p_datos->>'registrado_por', '')::BIGINT)
    RETURNING id INTO v_id;

    IF v_disp IS NOT NULL THEN
        UPDATE rrhh_dispositivos SET ultima_marca = GREATEST(COALESCE(ultima_marca, v_fecha), v_fecha) WHERE id = v_disp;
    END IF;

    IF v_estado = 'valida' AND v_emp IS NOT NULL THEN
        SELECT CASE WHEN s.s_entrada_id = v_id THEN 'entrada' ELSE 'salida' END INTO v_tipo
          FROM fn_rrhh_sesiones(p_empresa_id, v_emp, v_fecha - INTERVAL '2 days', v_fecha + INTERVAL '2 days') s
         WHERE s.s_entrada_id = v_id OR s.s_salida_id = v_id;
    END IF;

    RETURN QUERY SELECT v_id, FALSE, v_tipo, v_estado, v_emp;
END; $$;


--
-- Name: sp_rrhh_marca_resolver(bigint, bigint, boolean, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_marca_resolver(p_id bigint, p_empresa_id bigint, p_aprobar boolean, p_motivo character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_m RECORD;
BEGIN
    SELECT m.estado, m.empleado_id INTO v_m FROM rrhh_marcas m WHERE m.id = p_id AND m.empresa_id = p_empresa_id AND m.deleted_at IS NULL;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF p_aprobar THEN
        IF v_m.estado <> 'pendiente' THEN RAISE EXCEPTION 'MARCA_INVALIDA: Solo se pueden aprobar marcas pendientes.'; END IF;
        UPDATE rrhh_marcas SET estado = 'valida', resuelto_por = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT,
               resuelto_at = NOW(), updated_at = NOW() WHERE id = p_id;
    ELSE
        IF v_m.estado = 'rechazada' THEN RAISE EXCEPTION 'MARCA_INVALIDA: La marca ya estaba rechazada.'; END IF;
        IF COALESCE(btrim(p_motivo), '') = '' THEN RAISE EXCEPTION 'MARCA_INVALIDA: Indique el motivo.'; END IF;
        UPDATE rrhh_marcas SET estado = 'rechazada', motivo = LEFT(btrim(p_motivo), 255),
               resuelto_por = NULLIF(current_setting('app.current_user_id', true), '')::BIGINT, resuelto_at = NOW(), updated_at = NOW()
         WHERE id = p_id;
    END IF;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_organigrama(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_organigrama(p_empresa_id bigint) RETURNS TABLE(id bigint, jefe_id bigint, nivel integer, nombre_completo character varying, puesto_nombre character varying, departamento_nombre character varying, estado character varying, subordinados_directos bigint, subordinados_total bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE vigentes AS (
        SELECT e.* FROM rrhh_empleados e
        WHERE e.empresa_id = p_empresa_id AND e.deleted_at IS NULL AND e.estado <> 'liquidado'
    ),
    arbol AS (
        SELECT v.id, v.jefe_id, 1 AS nivel, ARRAY[v.id] AS ruta
          FROM vigentes v
         WHERE v.jefe_id IS NULL OR v.jefe_id NOT IN (SELECT x.id FROM vigentes x)
        UNION ALL
        SELECT v.id, v.jefe_id, a.nivel + 1, a.ruta || v.id
          FROM vigentes v JOIN arbol a ON v.jefe_id = a.id
         WHERE NOT v.id = ANY(a.ruta)
    ),
    descendientes AS (
        SELECT a.id AS raiz, a.id AS desc_id FROM arbol a
        UNION ALL
        SELECT d.raiz, v.id FROM descendientes d JOIN vigentes v ON v.jefe_id = d.desc_id
    )
    SELECT a.id, a.jefe_id, a.nivel,
           btrim(v.nombre || ' ' || v.apellido1 || ' ' || COALESCE(v.apellido2, ''))::VARCHAR,
           p.nombre, d.nombre, v.estado,
           (SELECT COUNT(*) FROM vigentes s WHERE s.jefe_id = a.id),
           (SELECT COUNT(*) - 1 FROM descendientes ds WHERE ds.raiz = a.id)
    FROM arbol a
    JOIN vigentes v ON v.id = a.id
    LEFT JOIN rrhh_puestos p ON p.id = v.puesto_id
    LEFT JOIN rrhh_departamentos d ON d.id = v.departamento_id
    ORDER BY a.nivel, lower(v.apellido1), lower(v.nombre);
END; $$;


--
-- Name: sp_rrhh_permiso_cancelar(bigint, bigint, bigint, boolean, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_permiso_cancelar(p_empresa_id bigint, p_id bigint, p_actor_empleado_id bigint, p_es_rrhh boolean, p_nota character varying DEFAULT NULL::character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_s    RECORD;
    v_user BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
BEGIN
    SELECT s.* INTO v_s FROM rrhh_permiso_solicitudes s WHERE s.id = p_id AND s.empresa_id = p_empresa_id AND s.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF NOT p_es_rrhh AND (p_actor_empleado_id IS NULL OR p_actor_empleado_id <> v_s.empleado_id) THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: Solo quien pidió el permiso puede cancelarlo.';
    END IF;
    IF v_s.estado IN ('pendiente_jefe', 'pendiente_rrhh') THEN
        NULL;
    ELSIF v_s.estado = 'aprobada' THEN
        IF NOT p_es_rrhh THEN RAISE EXCEPTION 'PERMISO_INVALIDO: Un permiso aprobado solo lo puede cancelar Recursos Humanos.'; END IF;
        IF v_s.fecha_inicio <= CURRENT_DATE THEN RAISE EXCEPTION 'PERMISO_INVALIDO: El permiso ya empezó y no se puede cancelar.'; END IF;
    ELSE
        RAISE EXCEPTION 'PERMISO_INVALIDO: La solicitud ya estaba %.', v_s.estado;
    END IF;
    UPDATE rrhh_permiso_solicitudes
       SET estado = 'cancelada', rrhh_resuelto_por = CASE WHEN p_es_rrhh THEN v_user ELSE rrhh_resuelto_por END,
           rrhh_resuelto_at = CASE WHEN p_es_rrhh THEN NOW() ELSE rrhh_resuelto_at END,
           rrhh_nota = CASE WHEN p_es_rrhh THEN NULLIF(btrim(COALESCE(p_nota, '')), '') ELSE rrhh_nota END, updated_at = NOW()
     WHERE id = p_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_permiso_list(bigint, character varying, bigint, date, date, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_permiso_list(p_empresa_id bigint, p_estado character varying DEFAULT NULL::character varying, p_empleado_id bigint DEFAULT NULL::bigint, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_jefe_id bigint DEFAULT NULL::bigint) RETURNS TABLE(id bigint, empleado_id bigint, empleado_codigo character varying, empleado_nombre character varying, departamento_id bigint, departamento_nombre character varying, tipo_id bigint, tipo_nombre character varying, unidad character varying, con_goce boolean, fecha_inicio date, fecha_fin date, hora_inicio time without time zone, hora_fin time without time zone, cantidad numeric, estado character varying, jefe_id bigint, jefe_nombre character varying, motivo character varying, jefe_resuelto_at timestamp without time zone, jefe_nota character varying, rrhh_resuelto_at timestamp without time zone, rrhh_nota character varying, created_at timestamp without time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT s.id, s.empleado_id, e.codigo::VARCHAR, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR,
           e.departamento_id, dp.nombre::VARCHAR, s.tipo_id, t.nombre::VARCHAR, s.unidad::VARCHAR, s.con_goce, s.fecha_inicio, s.fecha_fin,
           s.hora_inicio, s.hora_fin, s.cantidad, s.estado::VARCHAR, s.jefe_id,
           btrim(j.nombre || ' ' || j.apellido1 || ' ' || COALESCE(j.apellido2, ''))::VARCHAR, s.motivo::VARCHAR,
           s.jefe_resuelto_at, s.jefe_nota::VARCHAR, s.rrhh_resuelto_at, s.rrhh_nota::VARCHAR, s.created_at
      FROM rrhh_permiso_solicitudes s
      JOIN rrhh_empleados e ON e.id = s.empleado_id
      JOIN rrhh_permiso_tipos t ON t.id = s.tipo_id
      LEFT JOIN rrhh_departamentos dp ON dp.id = e.departamento_id
      LEFT JOIN rrhh_empleados j ON j.id = s.jefe_id
     WHERE s.empresa_id = p_empresa_id AND s.deleted_at IS NULL
       AND (p_estado IS NULL OR s.estado = p_estado)
       AND (p_empleado_id IS NULL OR s.empleado_id = p_empleado_id)
       AND (p_jefe_id IS NULL OR s.jefe_id = p_jefe_id)
       AND (p_desde IS NULL OR s.fecha_fin >= p_desde)
       AND (p_hasta IS NULL OR s.fecha_inicio <= p_hasta)
     ORDER BY (s.estado IN ('pendiente_jefe', 'pendiente_rrhh')) DESC, s.fecha_inicio DESC, s.id DESC
     LIMIT 500;
END; $$;


--
-- Name: sp_rrhh_permiso_previsualizar(bigint, bigint, bigint, date, date, time without time zone, time without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_permiso_previsualizar(p_empresa_id bigint, p_empleado_id bigint, p_tipo_id bigint, p_inicio date, p_fin date, p_hi time without time zone, p_hf time without time zone) RETURNS TABLE(cantidad numeric, unidad character varying, con_goce boolean, usado_anio numeric, max_por_solicitud numeric, max_por_anio numeric, valida boolean, mensaje character varying)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_t   RECORD;
    v_msg VARCHAR := NULL;
BEGIN
    SELECT t.* INTO v_t FROM rrhh_permiso_tipos t WHERE t.id = p_tipo_id AND t.empresa_id = p_empresa_id AND t.deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'PERMISO_INVALIDO: El tipo de permiso no existe.'; END IF;
    IF NOT EXISTS (SELECT 1 FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.';
    END IF;

    unidad := v_t.unidad; con_goce := v_t.con_goce; max_por_solicitud := v_t.max_por_solicitud; max_por_anio := v_t.max_por_anio;
    IF v_t.unidad = 'horas' THEN
        cantidad := CASE WHEN p_hi IS NOT NULL AND p_hf IS NOT NULL AND p_hf > p_hi THEN round(EXTRACT(EPOCH FROM (p_hf - p_hi)) / 3600.0, 2) ELSE 0 END;
    ELSE
        cantidad := CASE WHEN p_fin >= p_inicio AND p_fin - p_inicio <= 400 THEN fn_rrhh_dias_habiles(p_empresa_id, p_empleado_id, p_inicio, p_fin) ELSE 0 END;
    END IF;
    SELECT COALESCE(SUM(s.cantidad), 0) INTO usado_anio FROM rrhh_permiso_solicitudes s
     WHERE s.empleado_id = p_empleado_id AND s.tipo_id = p_tipo_id AND s.deleted_at IS NULL
       AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada') AND EXTRACT(YEAR FROM s.fecha_inicio) = EXTRACT(YEAR FROM p_inicio);
    BEGIN
        PERFORM fn_rrhh_permiso_validar(p_empresa_id, p_empleado_id, p_tipo_id, p_inicio, p_fin, p_hi, p_hf, NULL);
    EXCEPTION WHEN OTHERS THEN
        v_msg := regexp_replace(SQLERRM, '^[A-Z_]+:\s*', '');
    END;
    valida := v_msg IS NULL;
    mensaje := v_msg;
    RETURN NEXT;
END; $$;


--
-- Name: sp_rrhh_permiso_resolver(bigint, bigint, character varying, boolean, character varying, bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_permiso_resolver(p_empresa_id bigint, p_id bigint, p_etapa character varying, p_aprobar boolean, p_nota character varying, p_actor_empleado_id bigint DEFAULT NULL::bigint, p_omitir_jefe boolean DEFAULT false) RETURNS character varying
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_s     RECORD;
    v_nota  VARCHAR := NULLIF(btrim(COALESCE(p_nota, '')), '');
    v_user  BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    v_cant  NUMERIC;
BEGIN
    SELECT s.* INTO v_s FROM rrhh_permiso_solicitudes s WHERE s.id = p_id AND s.empresa_id = p_empresa_id AND s.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF p_actor_empleado_id IS NOT NULL AND p_actor_empleado_id = v_s.empleado_id THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: No puede resolver su propia solicitud.';
    END IF;

    IF p_etapa = 'jefe' THEN
        IF v_s.estado <> 'pendiente_jefe' THEN RAISE EXCEPTION 'PERMISO_INVALIDO: La solicitud ya no espera la aprobación del jefe.'; END IF;
        IF p_actor_empleado_id IS NULL OR p_actor_empleado_id IS DISTINCT FROM v_s.jefe_id THEN
            RAISE EXCEPTION 'PERMISO_INVALIDO: Solo el jefe inmediato del empleado puede resolver esta etapa.';
        END IF;
        IF NOT p_aprobar AND v_nota IS NULL THEN RAISE EXCEPTION 'PERMISO_INVALIDO: Indique el motivo del rechazo.'; END IF;
        UPDATE rrhh_permiso_solicitudes
           SET estado = CASE WHEN p_aprobar THEN 'pendiente_rrhh' ELSE 'rechazada' END,
               jefe_resuelto_por = v_user, jefe_resuelto_at = NOW(), jefe_nota = v_nota, updated_at = NOW()
         WHERE id = p_id;
        RETURN CASE WHEN p_aprobar THEN 'pendiente_rrhh' ELSE 'rechazada' END;
    END IF;

    IF p_etapa <> 'rrhh' THEN RAISE EXCEPTION 'PERMISO_INVALIDO: Etapa desconocida.'; END IF;
    IF v_s.estado = 'pendiente_jefe' THEN
        IF NOT p_omitir_jefe THEN RAISE EXCEPTION 'PERMISO_INVALIDO: Falta la aprobación del jefe inmediato.'; END IF;
        IF v_nota IS NULL THEN RAISE EXCEPTION 'PERMISO_INVALIDO: Indique por qué se resuelve sin el jefe.'; END IF;
    ELSIF v_s.estado <> 'pendiente_rrhh' THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: La solicitud ya no está pendiente.';
    END IF;
    IF NOT p_aprobar AND v_nota IS NULL THEN RAISE EXCEPTION 'PERMISO_INVALIDO: Indique el motivo del rechazo.'; END IF;

    IF p_aprobar THEN
        -- Se vuelve a validar: desde que se pidió pudo cambiar el horario, un tope o aparecer otra ausencia.
        v_cant := fn_rrhh_permiso_validar(p_empresa_id, v_s.empleado_id, v_s.tipo_id, v_s.fecha_inicio, v_s.fecha_fin, v_s.hora_inicio, v_s.hora_fin, v_s.id);
    END IF;
    UPDATE rrhh_permiso_solicitudes
       SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END,
           cantidad = COALESCE(v_cant, cantidad),
           rrhh_resuelto_por = v_user, rrhh_resuelto_at = NOW(), rrhh_nota = v_nota, updated_at = NOW()
     WHERE id = p_id;
    RETURN CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END;
END; $$;


--
-- Name: sp_rrhh_permiso_solicitar(bigint, bigint, bigint, date, date, time without time zone, time without time zone, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_permiso_solicitar(p_empresa_id bigint, p_empleado_id bigint, p_tipo_id bigint, p_inicio date, p_fin date, p_hi time without time zone, p_hf time without time zone, p_motivo character varying, p_directa boolean DEFAULT false) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_cant   NUMERIC;
    v_t      RECORD;
    v_jefe   BIGINT;
    v_estado VARCHAR;
    v_user   BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    v_id     BIGINT;
BEGIN
    IF p_inicio < CURRENT_DATE AND NOT p_directa THEN
        RAISE EXCEPTION 'FECHA_INVALIDA: La fecha del permiso no puede ser anterior a hoy.';
    END IF;
    v_cant := fn_rrhh_permiso_validar(p_empresa_id, p_empleado_id, p_tipo_id, p_inicio, p_fin, p_hi, p_hf, NULL);
    SELECT t.unidad, t.con_goce INTO v_t FROM rrhh_permiso_tipos t WHERE t.id = p_tipo_id;

    SELECT j.id INTO v_jefe FROM rrhh_empleados e
      JOIN rrhh_empleados j ON j.id = e.jefe_id AND j.deleted_at IS NULL AND j.estado = 'activo'
     WHERE e.id = p_empleado_id;

    v_estado := CASE WHEN p_directa THEN 'aprobada' WHEN v_jefe IS NOT NULL THEN 'pendiente_jefe' ELSE 'pendiente_rrhh' END;
    INSERT INTO rrhh_permiso_solicitudes (empresa_id, empleado_id, tipo_id, fecha_inicio, fecha_fin, hora_inicio, hora_fin, cantidad, unidad, con_goce,
                                          estado, jefe_id, motivo, creada_por, rrhh_resuelto_por, rrhh_resuelto_at, rrhh_nota)
    VALUES (p_empresa_id, p_empleado_id, p_tipo_id, p_inicio, p_fin,
            CASE WHEN v_t.unidad = 'horas' THEN p_hi END, CASE WHEN v_t.unidad = 'horas' THEN p_hf END,
            v_cant, v_t.unidad, v_t.con_goce, v_estado, v_jefe, NULLIF(btrim(COALESCE(p_motivo, '')), ''), v_user,
            CASE WHEN p_directa THEN v_user END, CASE WHEN p_directa THEN NOW() END, CASE WHEN p_directa THEN 'Registrado directamente por RRHH' END)
    RETURNING id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_permiso_tipo_cargar(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_permiso_tipo_cargar(p_empresa_id bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n INTEGER;
BEGIN
    WITH sug (nombre, unidad, con_goce, max_sol, max_anio, descr) AS (
        VALUES ('Cita médica', 'horas', TRUE, 4::NUMERIC, NULL::NUMERIC, 'Consulta o examen médico propio, con comprobante.'),
               ('Fallecimiento de un familiar', 'dias', TRUE, 3, NULL, 'Duelo por familiar cercano.'),
               ('Matrimonio', 'dias', TRUE, 3, NULL, NULL),
               ('Calamidad doméstica', 'dias', TRUE, 2, NULL, 'Imprevisto grave en el hogar.'),
               ('Lactancia', 'horas', TRUE, 1, NULL, 'Tiempo para lactar o extraer leche.'),
               ('Estudio o examen', 'horas', FALSE, 8, NULL, NULL),
               ('Asunto personal', 'dias', FALSE, NULL, NULL, 'Permiso sin goce de salario.')
    ), ins AS (
        INSERT INTO rrhh_permiso_tipos (empresa_id, nombre, unidad, con_goce, max_por_solicitud, max_por_anio, descripcion)
        SELECT p_empresa_id, s.nombre, s.unidad, s.con_goce, s.max_sol, s.max_anio, s.descr FROM sug s
         WHERE NOT EXISTS (SELECT 1 FROM rrhh_permiso_tipos t WHERE t.empresa_id = p_empresa_id AND lower(t.nombre) = lower(s.nombre) AND t.deleted_at IS NULL)
        RETURNING 1
    )
    SELECT COUNT(*)::INTEGER INTO v_n FROM ins;
    RETURN v_n;
END; $$;


--
-- Name: sp_rrhh_permiso_tipo_create(bigint, character varying, character varying, boolean, numeric, numeric, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_permiso_tipo_create(p_empresa_id bigint, p_nombre character varying, p_unidad character varying, p_con_goce boolean, p_max_solicitud numeric, p_max_anio numeric, p_descripcion character varying) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT; v_nombre VARCHAR := btrim(COALESCE(p_nombre, ''));
BEGIN
    IF v_nombre = '' THEN RAISE EXCEPTION 'PERMISO_INVALIDO: Indique el nombre del tipo de permiso.'; END IF;
    IF p_unidad NOT IN ('dias', 'horas') THEN RAISE EXCEPTION 'PERMISO_INVALIDO: La unidad debe ser días u horas.'; END IF;
    IF EXISTS (SELECT 1 FROM rrhh_permiso_tipos t WHERE t.empresa_id = p_empresa_id AND lower(t.nombre) = lower(v_nombre) AND t.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: Ya existe un tipo de permiso con ese nombre.';
    END IF;
    INSERT INTO rrhh_permiso_tipos (empresa_id, nombre, unidad, con_goce, max_por_solicitud, max_por_anio, descripcion)
    VALUES (p_empresa_id, v_nombre, p_unidad, COALESCE(p_con_goce, TRUE), p_max_solicitud, p_max_anio, NULLIF(btrim(COALESCE(p_descripcion, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_permiso_tipo_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_permiso_tipo_delete(p_empresa_id bigint, p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n INTEGER;
BEGIN
    IF EXISTS (SELECT 1 FROM rrhh_permiso_solicitudes s WHERE s.tipo_id = p_id AND s.empresa_id = p_empresa_id AND s.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: Este tipo ya tiene solicitudes; en lugar de eliminarlo, desactívelo.';
    END IF;
    UPDATE rrhh_permiso_tipos SET deleted_at = NOW(), updated_at = NOW() WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n > 0;
END; $$;


--
-- Name: sp_rrhh_permiso_tipo_list(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_permiso_tipo_list(p_empresa_id bigint, p_solo_activos boolean DEFAULT false) RETURNS TABLE(id bigint, nombre character varying, unidad character varying, con_goce boolean, max_por_solicitud numeric, max_por_anio numeric, descripcion character varying, is_active boolean, usos bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT t.id, t.nombre::VARCHAR, t.unidad::VARCHAR, t.con_goce, t.max_por_solicitud, t.max_por_anio, t.descripcion::VARCHAR, t.is_active,
           (SELECT COUNT(*) FROM rrhh_permiso_solicitudes s WHERE s.tipo_id = t.id AND s.deleted_at IS NULL)
      FROM rrhh_permiso_tipos t
     WHERE t.empresa_id = p_empresa_id AND t.deleted_at IS NULL AND (NOT p_solo_activos OR t.is_active)
     ORDER BY lower(t.nombre);
END; $$;


--
-- Name: sp_rrhh_permiso_tipo_update(bigint, bigint, character varying, character varying, boolean, numeric, numeric, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_permiso_tipo_update(p_empresa_id bigint, p_id bigint, p_nombre character varying, p_unidad character varying, p_con_goce boolean, p_max_solicitud numeric, p_max_anio numeric, p_descripcion character varying, p_is_active boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_t RECORD; v_nombre VARCHAR := btrim(COALESCE(p_nombre, ''));
BEGIN
    SELECT t.* INTO v_t FROM rrhh_permiso_tipos t WHERE t.id = p_id AND t.empresa_id = p_empresa_id AND t.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF v_nombre = '' THEN RAISE EXCEPTION 'PERMISO_INVALIDO: Indique el nombre del tipo de permiso.'; END IF;
    IF p_unidad NOT IN ('dias', 'horas') THEN RAISE EXCEPTION 'PERMISO_INVALIDO: La unidad debe ser días u horas.'; END IF;
    IF p_unidad <> v_t.unidad AND EXISTS (SELECT 1 FROM rrhh_permiso_solicitudes s WHERE s.tipo_id = p_id AND s.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: Este tipo ya tiene solicitudes; no se puede cambiar entre días y horas. Cree otro tipo.';
    END IF;
    IF EXISTS (SELECT 1 FROM rrhh_permiso_tipos t WHERE t.empresa_id = p_empresa_id AND lower(t.nombre) = lower(v_nombre) AND t.deleted_at IS NULL AND t.id <> p_id) THEN
        RAISE EXCEPTION 'PERMISO_INVALIDO: Ya existe un tipo de permiso con ese nombre.';
    END IF;
    UPDATE rrhh_permiso_tipos
       SET nombre = v_nombre, unidad = p_unidad, con_goce = COALESCE(p_con_goce, con_goce), max_por_solicitud = p_max_solicitud,
           max_por_anio = p_max_anio, descripcion = NULLIF(btrim(COALESCE(p_descripcion, '')), ''), is_active = COALESCE(p_is_active, is_active),
           updated_at = NOW()
     WHERE id = p_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_pin_get(bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_pin_get(p_empresa_id bigint, p_codigo character varying) RETURNS TABLE(empleado_id bigint, nombre character varying, estado character varying, pin_hash character varying, bloqueado boolean, bloqueado_hasta timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT e.id, btrim(e.nombre || ' ' || e.apellido1)::VARCHAR, e.estado, p.pin_hash,
           (p.bloqueado_hasta IS NOT NULL AND p.bloqueado_hasta > NOW()), p.bloqueado_hasta
      FROM rrhh_empleados e
      LEFT JOIN rrhh_empleado_pin p ON p.empleado_id = e.id
     WHERE e.empresa_id = p_empresa_id AND e.deleted_at IS NULL AND lower(e.codigo) = lower(btrim(p_codigo));
END; $$;


--
-- Name: sp_rrhh_pin_resultado(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_pin_resultado(p_empleado_id bigint, p_ok boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF p_ok THEN
        UPDATE rrhh_empleado_pin SET intentos = 0, bloqueado_hasta = NULL WHERE empleado_id = p_empleado_id AND (intentos > 0 OR bloqueado_hasta IS NOT NULL);
    ELSE
        UPDATE rrhh_empleado_pin SET
            intentos = CASE WHEN intentos + 1 >= 5 THEN 0 ELSE intentos + 1 END,
            bloqueado_hasta = CASE WHEN intentos + 1 >= 5 THEN NOW() + INTERVAL '10 minutes' ELSE bloqueado_hasta END
         WHERE empleado_id = p_empleado_id;
    END IF;
END; $$;


--
-- Name: sp_rrhh_pin_set(bigint, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_pin_set(p_empresa_id bigint, p_empleado_id bigint, p_hash character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_empleados WHERE id = p_empleado_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.';
    END IF;
    INSERT INTO rrhh_empleado_pin (empleado_id, empresa_id, pin_hash) VALUES (p_empleado_id, p_empresa_id, p_hash)
    ON CONFLICT (empleado_id) DO UPDATE SET pin_hash = EXCLUDED.pin_hash, intentos = 0, bloqueado_hasta = NULL, cambiado_at = NOW();
    PERFORM fn_rrhh_movimiento(p_empresa_id, p_empleado_id, 'pin', 'PIN de marca asignado o restablecido');
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_planilla_calcular(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_planilla_calcular(p_empresa_id bigint, p_id bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_p        RECORD;
    v_e        RECORD;
    v_i        RECORD;
    v_s        RECORD;
    v_anio     INTEGER;
    v_validado BOOLEAN;
    v_cr_hijo  NUMERIC;
    v_cr_cony  NUMERIC;
    v_pct_ob   NUMERIC;
    v_pct_pa   NUMERIC;
    v_div_cal  NUMERIC;
    v_div_lab  NUMERIC;
    v_dias_per INTEGER;
    v_ini      DATE;
    v_fin      DATE;
    v_vin      INTEGER;
    v_sal      NUMERIC;
    v_sal_per  NUMERIC;
    v_vdia     NUMERIC;
    v_vhora    NUMERIC;
    v_aus_d    INTEGER;
    v_tard_m   INTEGER;
    v_perm_d   NUMERIC;
    v_perm_h   NUMERIC;
    v_inc_d    INTEGER;
    v_ov_ini   DATE;
    v_ov_fin   DATE;
    v_prev     INTEGER;
    v_pago_raw NUMERIC;
    v_x        NUMERIC;
    v_d_inc    NUMERIC;
    v_d_aus    NUMERIC;
    v_d_perm   NUMERIC;
    v_d_tard   NUMERIC;
    v_rem      NUMERIC;
    v_pago_inc NUMERIC;
    v_hx       NUMERIC;
    v_hx_min   INTEGER;
    v_hx_pend  INTEGER;
    v_vac      NUMERIC;
    v_ing      NUMERIC;
    v_ing_ccss NUMERIC;
    v_ing_rta  NUMERIC;
    v_ded      NUMERIC;
    v_neto_sal NUMERIC;
    v_dev      NUMERIC;
    v_b_ccss   NUMERIC;
    v_b_rta    NUMERIC;
    v_ccss_ob  NUMERIC;
    v_ccss_pa  NUMERIC;
    v_mes      DATE;
    v_ac_base  NUMERIC;
    v_ac_rta   NUMERIC;
    v_cum      NUMERIC;
    v_tax      NUMERIC;
    v_renta    NUMERIC;
    v_neto     NUMERIC;
    v_adv      TEXT[];
    v_n        INTEGER := 0;
BEGIN
    SELECT * INTO v_p FROM rrhh_planillas pl WHERE pl.id = p_id AND pl.empresa_id = p_empresa_id AND pl.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: La planilla no existe.'; END IF;
    IF v_p.estado NOT IN ('borrador', 'calculada') THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Solo se puede calcular una planilla en borrador o calculada.'; END IF;

    v_anio := EXTRACT(YEAR FROM v_p.fecha_fin)::INTEGER;
    PERFORM sp_rrhh_tasas_cargar(p_empresa_id, v_anio);
    SELECT t.validado, t.credito_hijo, t.credito_conyuge INTO v_validado, v_cr_hijo, v_cr_cony
      FROM rrhh_tasas_anio t WHERE t.empresa_id = p_empresa_id AND t.anio = v_anio;
    SELECT COALESCE(SUM(c.porcentaje) FILTER (WHERE c.parte = 'obrero'), 0), COALESCE(SUM(c.porcentaje) FILTER (WHERE c.parte = 'patronal'), 0)
      INTO v_pct_ob, v_pct_pa FROM rrhh_cargas_sociales c WHERE c.empresa_id = p_empresa_id AND c.anio = v_anio;
    IF NOT EXISTS (SELECT 1 FROM rrhh_renta_tramos r WHERE r.empresa_id = p_empresa_id AND r.anio = v_anio) THEN
        RAISE EXCEPTION 'PLANILLA_INVALIDA: No hay tramos de renta para %.', v_anio;
    END IF;

    v_div_cal  := CASE v_p.periodicidad WHEN 'mensual' THEN 30 WHEN 'quincenal' THEN 15 ELSE 7 END;
    v_div_lab  := CASE v_p.periodicidad WHEN 'mensual' THEN 30 WHEN 'quincenal' THEN 15 ELSE 6 END;
    v_dias_per := v_p.fecha_fin - v_p.fecha_inicio + 1;
    v_mes      := date_trunc('month', v_p.fecha_fin)::DATE;

    DELETE FROM rrhh_planilla_empleados WHERE planilla_id = p_id;
    DELETE FROM rrhh_planilla_lineas WHERE planilla_id = p_id AND origen = 'recurrente';

    FOR v_e IN
        SELECT e.*, d.nombre AS depto, pu.nombre AS puesto_nombre
          FROM rrhh_empleados e
          LEFT JOIN rrhh_departamentos d ON d.id = e.departamento_id
          LEFT JOIN rrhh_puestos pu ON pu.id = e.puesto_id
         WHERE e.empresa_id = p_empresa_id AND e.deleted_at IS NULL AND e.periodo_pago = v_p.periodicidad AND e.moneda = v_p.moneda
           AND e.fecha_ingreso <= v_p.fecha_fin AND (e.fecha_salida IS NULL OR e.fecha_salida >= v_p.fecha_inicio)
           AND (e.estado = 'activo' OR (e.estado = 'liquidado' AND e.fecha_salida IS NOT NULL))
         ORDER BY e.codigo
    LOOP
        v_adv := ARRAY[]::TEXT[];
        v_ini := GREATEST(v_p.fecha_inicio, v_e.fecha_ingreso);
        v_fin := LEAST(v_p.fecha_fin, COALESCE(v_e.fecha_salida, v_p.fecha_fin));
        v_vin := v_fin - v_ini + 1;
        v_sal := v_e.salario_base;
        IF v_sal <= 0 THEN v_adv := array_append(v_adv, 'El expediente no tiene salario.'::TEXT); END IF;

        v_sal_per := CASE WHEN v_vin >= v_dias_per THEN v_sal ELSE round(v_sal * LEAST(v_vin, v_div_cal) / v_div_cal, 2) END;
        v_vdia    := v_sal / v_div_lab;
        v_vhora   := v_vdia / (CASE v_e.jornada WHEN 'mixta' THEN 7 WHEN 'nocturna' THEN 6 ELSE 8 END);

        -- Asistencia: faltas y tardanzas
        SELECT COUNT(*) FILTER (WHERE r.estado = 'ausente')::INTEGER,
               COALESCE(SUM(COALESCE(r.minutos_tarde, 0) + COALESCE(r.minutos_salida_anticipada, 0)), 0)::INTEGER
          INTO v_aus_d, v_tard_m
          FROM sp_rrhh_asistencia_resumen(p_empresa_id, v_ini, v_fin, v_e.id, NULL, NULL) r;
        v_d_aus  := round(v_aus_d * v_vdia, 2);
        v_d_tard := CASE WHEN v_p.descontar_tardanzas THEN round(v_tard_m / 60.0 * v_vhora, 2) ELSE 0 END;

        -- Permisos sin goce
        v_perm_d := 0; v_perm_h := 0;
        FOR v_s IN
            SELECT s.* FROM rrhh_permiso_solicitudes s
             WHERE s.empleado_id = v_e.id AND s.deleted_at IS NULL AND s.estado = 'aprobada' AND NOT s.con_goce
               AND s.fecha_inicio <= v_fin AND s.fecha_fin >= v_ini
        LOOP
            IF v_s.unidad = 'dias' THEN
                v_perm_d := v_perm_d + fn_rrhh_dias_habiles(p_empresa_id, v_e.id, GREATEST(v_s.fecha_inicio, v_ini), LEAST(v_s.fecha_fin, v_fin));
            ELSE
                v_perm_h := v_perm_h + v_s.cantidad;
            END IF;
        END LOOP;
        v_d_perm := round(v_perm_d * v_vdia + v_perm_h * v_vhora, 2);

        -- Incapacidades: se descuenta el día natural y el patrono paga su parte (y el complemento si lo cubre)
        v_inc_d := 0; v_d_inc := 0; v_pago_raw := 0;
        FOR v_i IN
            SELECT i.* FROM rrhh_incapacidades i
             WHERE i.empleado_id = v_e.id AND i.deleted_at IS NULL AND i.estado = 'registrada'
               AND i.fecha_inicio <= v_fin AND i.fecha_fin >= v_ini
             ORDER BY i.fecha_inicio
        LOOP
            v_ov_ini := GREATEST(v_i.fecha_inicio, v_ini);
            v_ov_fin := LEAST(v_i.fecha_fin, v_fin);
            v_prev   := fn_rrhh_inc_dias_previos(v_e.id, v_i.tipo, v_i.fecha_inicio, v_i.id);
            v_inc_d  := v_inc_d + (v_ov_fin - v_ov_ini + 1);
            v_d_inc  := v_d_inc + (v_ov_fin - v_ov_ini + 1) * v_i.valor_dia;
            SELECT COALESCE(SUM(v_i.valor_dia * (CASE WHEN v_i.patrono_completa
                                                      THEN 100 - (CASE WHEN v_i.tipo = 'maternidad' THEN 50 WHEN q.n <= 3 THEN 0 ELSE 60 END)
                                                      ELSE (CASE WHEN v_i.tipo = 'maternidad' THEN 50 WHEN q.n <= 3 THEN 50 ELSE 0 END) END) / 100), 0)
              INTO v_x
              FROM generate_series(v_ov_ini::TIMESTAMP, v_ov_fin::TIMESTAMP, INTERVAL '1 day') g
              CROSS JOIN LATERAL (SELECT v_prev + (g::DATE - v_i.fecha_inicio) + 1 AS n) q;
            v_pago_raw := v_pago_raw + v_x;
        END LOOP;
        IF v_inc_d >= v_vin AND v_vin > 0 THEN
            -- todo el período con incapacidad: el salario completo se sustituye por el subsidio, ajustado al divisor
            v_d_inc := v_sal_per;
            v_pago_raw := v_pago_raw * v_sal_per / NULLIF(v_sal / v_div_cal * v_vin, 0);
        END IF;
        v_pago_inc := round(COALESCE(v_pago_raw, 0), 2);
        v_d_inc    := round(v_d_inc, 2);

        -- Los descuentos nunca dejan el salario del período por debajo de cero
        v_rem := v_sal_per;
        v_d_inc  := LEAST(v_d_inc, v_rem);  v_rem := v_rem - v_d_inc;
        v_d_aus  := LEAST(v_d_aus, v_rem);  v_rem := v_rem - v_d_aus;
        v_d_perm := LEAST(v_d_perm, v_rem); v_rem := v_rem - v_d_perm;
        v_d_tard := LEAST(v_d_tard, v_rem); v_rem := v_rem - v_d_tard;
        v_neto_sal := v_rem;

        -- Horas extra aprobadas y extras de vacaciones
        SELECT COALESCE(SUM(x.monto_aprobado), 0), COALESCE(SUM(x.minutos_aprobados), 0)::INTEGER, COALESCE(SUM(x.minutos_pendientes), 0)::INTEGER
          INTO v_hx, v_hx_min, v_hx_pend FROM sp_rrhh_horas_extra(p_empresa_id, v_ini, v_fin, v_e.id, NULL) x;
        IF v_hx_pend > 0 THEN v_adv := array_append(v_adv, ('Hay ' || v_hx_pend || ' minutos de horas extra pendientes de aprobar que no se pagan.')::TEXT); END IF;
        SELECT COALESCE(SUM(x.monto_extras), 0) INTO v_vac FROM sp_rrhh_vac_pagos(p_empresa_id, v_ini, v_fin, v_e.id) x;

        -- Conceptos recurrentes del empleado
        INSERT INTO rrhh_planilla_lineas (planilla_id, empleado_id, concepto_id, codigo, descripcion, tipo, monto, origen, afecta_ccss, afecta_renta)
        SELECT p_id, v_e.id, c.id, c.codigo, c.nombre, c.tipo, ec.monto, 'recurrente', c.afecta_ccss, c.afecta_renta
          FROM rrhh_empleado_conceptos ec JOIN rrhh_conceptos c ON c.id = ec.concepto_id
         WHERE ec.empleado_id = v_e.id AND ec.deleted_at IS NULL AND c.deleted_at IS NULL AND c.is_active
           AND ec.desde <= v_p.fecha_fin AND (ec.hasta IS NULL OR ec.hasta >= v_p.fecha_inicio);
        SELECT COALESCE(SUM(l.monto) FILTER (WHERE l.tipo = 'ingreso'), 0),
               COALESCE(SUM(l.monto) FILTER (WHERE l.tipo = 'ingreso' AND l.afecta_ccss), 0),
               COALESCE(SUM(l.monto) FILTER (WHERE l.tipo = 'ingreso' AND l.afecta_renta), 0),
               COALESCE(SUM(l.monto) FILTER (WHERE l.tipo = 'deduccion'), 0)
          INTO v_ing, v_ing_ccss, v_ing_rta, v_ded
          FROM rrhh_planilla_lineas l WHERE l.planilla_id = p_id AND l.empleado_id = v_e.id;

        v_dev    := v_neto_sal + v_pago_inc + v_hx + v_vac + v_ing;
        v_b_ccss := v_neto_sal + v_pago_inc + v_hx + v_vac + v_ing_ccss;
        v_b_rta  := v_neto_sal + v_pago_inc + v_hx + v_vac + v_ing_rta;
        v_ccss_ob := round(v_b_ccss * v_pct_ob / 100, 2);
        v_ccss_pa := round(v_b_ccss * v_pct_pa / 100, 2);

        -- Renta: acumulado del mes calendario (de la fecha final) con las planillas anteriores del mismo empleado
        SELECT COALESCE(SUM(pe.base_renta), 0), COALESCE(SUM(pe.renta), 0) INTO v_ac_base, v_ac_rta
          FROM rrhh_planilla_empleados pe JOIN rrhh_planillas pl ON pl.id = pe.planilla_id
         WHERE pe.empleado_id = v_e.id AND pl.empresa_id = p_empresa_id AND pl.id <> p_id AND pl.estado <> 'anulada' AND pl.deleted_at IS NULL
           AND date_trunc('month', pl.fecha_fin)::DATE = v_mes
           AND (pl.fecha_fin < v_p.fecha_fin OR (pl.fecha_fin = v_p.fecha_fin AND pl.id < p_id));
        v_cum := v_ac_base + v_b_rta;
        SELECT COALESCE(SUM(GREATEST(LEAST(v_cum, COALESCE(t.hasta, 1e15)) - t.desde, 0) * t.porcentaje / 100), 0) INTO v_tax
          FROM rrhh_renta_tramos t WHERE t.empresa_id = p_empresa_id AND t.anio = v_anio;
        IF v_tax > 0 THEN
            v_tax := GREATEST(v_tax - (v_e.cantidad_hijos * v_cr_hijo + CASE WHEN v_e.tiene_conyuge THEN v_cr_cony ELSE 0 END), 0);
        END IF;
        v_renta := GREATEST(round(v_tax - v_ac_rta, 2), 0);

        v_neto := v_dev - v_ccss_ob - v_renta - v_ded;
        IF v_neto < 0 THEN v_adv := array_append(v_adv, 'El neto es negativo: las deducciones superan lo devengado.'::TEXT); END IF;
        IF v_e.banco IS NULL OR v_e.iban IS NULL THEN v_adv := array_append(v_adv, 'Sin banco o cuenta IBAN para el pago.'::TEXT); END IF;
        IF v_e.numero_ccss IS NULL THEN v_adv := array_append(v_adv, 'Sin número de asegurado de la CCSS.'::TEXT); END IF;

        INSERT INTO rrhh_planilla_empleados (
            planilla_id, empleado_id, codigo, nombre, tipo_identificacion, identificacion, departamento, puesto, banco, iban, numero_ccss,
            dias_vinculo, dias_ausente, minutos_tardanza, dias_permiso_sg, dias_incapacidad, minutos_extra,
            salario_base, salario_periodo, desc_ausencias, desc_tardanzas, desc_permisos, desc_incapacidad, pago_incapacidad,
            horas_extra, vac_extras, otros_ingresos, devengado, base_ccss, ccss_obrero, base_renta, renta, otras_deducciones, neto,
            ccss_patronal, advertencias
        ) VALUES (
            p_id, v_e.id, v_e.codigo, btrim(v_e.nombre || ' ' || v_e.apellido1 || ' ' || COALESCE(v_e.apellido2, '')), v_e.tipo_identificacion,
            v_e.identificacion, v_e.depto, v_e.puesto_nombre, v_e.banco, v_e.iban, v_e.numero_ccss,
            v_vin, v_aus_d, v_tard_m, v_perm_d + v_perm_h / 8.0, v_inc_d, v_hx_min,
            v_sal, v_sal_per, v_d_aus, v_d_tard, v_d_perm, v_d_inc, v_pago_inc,
            v_hx, v_vac, v_ing, v_dev, v_b_ccss, v_ccss_ob, v_b_rta, v_renta, v_ded, v_neto,
            v_ccss_pa, to_jsonb(v_adv)
        );
        v_n := v_n + 1;
    END LOOP;

    -- Líneas manuales de empleados que ya no entran en la planilla
    DELETE FROM rrhh_planilla_lineas l
     WHERE l.planilla_id = p_id AND NOT EXISTS (SELECT 1 FROM rrhh_planilla_empleados pe WHERE pe.planilla_id = p_id AND pe.empleado_id = l.empleado_id);

    UPDATE rrhh_planillas pl
       SET estado = 'calculada', calculada_at = NOW(), tasas_validadas = COALESCE(v_validado, FALSE), updated_at = NOW(),
           total_empleados = v_n,
           total_devengado = COALESCE((SELECT SUM(pe.devengado) FROM rrhh_planilla_empleados pe WHERE pe.planilla_id = p_id), 0),
           total_ccss_obrero = COALESCE((SELECT SUM(pe.ccss_obrero) FROM rrhh_planilla_empleados pe WHERE pe.planilla_id = p_id), 0),
           total_renta = COALESCE((SELECT SUM(pe.renta) FROM rrhh_planilla_empleados pe WHERE pe.planilla_id = p_id), 0),
           total_otras_ded = COALESCE((SELECT SUM(pe.otras_deducciones) FROM rrhh_planilla_empleados pe WHERE pe.planilla_id = p_id), 0),
           total_neto = COALESCE((SELECT SUM(pe.neto) FROM rrhh_planilla_empleados pe WHERE pe.planilla_id = p_id), 0),
           total_ccss_patronal = COALESCE((SELECT SUM(pe.ccss_patronal) FROM rrhh_planilla_empleados pe WHERE pe.planilla_id = p_id), 0)
     WHERE pl.id = p_id;
    RETURN v_n;
END; $$;


--
-- Name: sp_rrhh_planilla_create(bigint, character varying, character varying, date, date, date, character varying, boolean, character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_planilla_create(p_empresa_id bigint, p_nombre character varying, p_periodicidad character varying, p_inicio date, p_fin date, p_pago date, p_moneda character varying, p_descontar_tardanzas boolean, p_notas character varying, p_user_id bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT; v_nom VARCHAR := btrim(COALESCE(p_nombre, ''));
BEGIN
    IF v_nom = '' THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Indique el nombre de la planilla.'; END IF;
    IF p_periodicidad NOT IN ('mensual', 'quincenal', 'semanal') THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Periodicidad inválida.'; END IF;
    IF p_inicio IS NULL OR p_fin IS NULL OR p_pago IS NULL THEN RAISE EXCEPTION 'FECHA_INVALIDA: Indique el período y la fecha de pago.'; END IF;
    IF p_fin < p_inicio THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha final es anterior a la inicial.'; END IF;
    IF p_fin - p_inicio > 31 THEN RAISE EXCEPTION 'FECHA_INVALIDA: El período no puede pasar de 32 días.'; END IF;
    IF p_pago < p_inicio THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha de pago es anterior al inicio del período.'; END IF;
    IF EXISTS (SELECT 1 FROM rrhh_planillas pl WHERE pl.empresa_id = p_empresa_id AND pl.deleted_at IS NULL AND pl.estado <> 'anulada'
                  AND pl.periodicidad = p_periodicidad AND pl.moneda = COALESCE(p_moneda, 'CRC')
                  AND pl.fecha_inicio <= p_fin AND pl.fecha_fin >= p_inicio) THEN
        RAISE EXCEPTION 'PLANILLA_INVALIDA: Ya existe una planilla % en % que se traslapa con ese período.', p_periodicidad, COALESCE(p_moneda, 'CRC');
    END IF;
    INSERT INTO rrhh_planillas (empresa_id, nombre, periodicidad, fecha_inicio, fecha_fin, fecha_pago, moneda, descontar_tardanzas, notas, creada_por)
    VALUES (p_empresa_id, v_nom, p_periodicidad, p_inicio, p_fin, p_pago, COALESCE(p_moneda, 'CRC'), COALESCE(p_descontar_tardanzas, TRUE),
            NULLIF(btrim(COALESCE(p_notas, '')), ''), p_user_id)
    RETURNING rrhh_planillas.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_planilla_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_planilla_delete(p_empresa_id bigint, p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_estado VARCHAR;
BEGIN
    SELECT pl.estado INTO v_estado FROM rrhh_planillas pl WHERE pl.id = p_id AND pl.empresa_id = p_empresa_id AND pl.deleted_at IS NULL;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF v_estado NOT IN ('borrador', 'calculada', 'anulada') THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Una planilla aprobada o pagada no se elimina; anúlela si corresponde.'; END IF;
    DELETE FROM rrhh_planilla_lineas WHERE planilla_id = p_id;
    DELETE FROM rrhh_planilla_empleados WHERE planilla_id = p_id;
    UPDATE rrhh_planillas SET deleted_at = NOW(), updated_at = NOW() WHERE id = p_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_planilla_empleados(bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_planilla_empleados(p_empresa_id bigint, p_id bigint, p_empleado_id bigint DEFAULT NULL::bigint) RETURNS TABLE(empleado_id bigint, codigo character varying, nombre character varying, tipo_identificacion character varying, identificacion character varying, departamento character varying, puesto character varying, banco character varying, iban character varying, numero_ccss character varying, dias_vinculo integer, dias_ausente integer, minutos_tardanza integer, dias_permiso_sg numeric, dias_incapacidad integer, minutos_extra integer, salario_base numeric, salario_periodo numeric, desc_ausencias numeric, desc_tardanzas numeric, desc_permisos numeric, desc_incapacidad numeric, pago_incapacidad numeric, horas_extra numeric, vac_extras numeric, otros_ingresos numeric, devengado numeric, base_ccss numeric, ccss_obrero numeric, base_renta numeric, renta numeric, otras_deducciones numeric, neto numeric, ccss_patronal numeric, advertencias jsonb)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT pe.empleado_id, pe.codigo::VARCHAR, pe.nombre::VARCHAR, pe.tipo_identificacion::VARCHAR, pe.identificacion::VARCHAR, pe.departamento::VARCHAR,
           pe.puesto::VARCHAR, pe.banco::VARCHAR, pe.iban::VARCHAR, pe.numero_ccss::VARCHAR, pe.dias_vinculo, pe.dias_ausente, pe.minutos_tardanza,
           pe.dias_permiso_sg, pe.dias_incapacidad, pe.minutos_extra, pe.salario_base, pe.salario_periodo, pe.desc_ausencias, pe.desc_tardanzas,
           pe.desc_permisos, pe.desc_incapacidad, pe.pago_incapacidad, pe.horas_extra, pe.vac_extras, pe.otros_ingresos, pe.devengado, pe.base_ccss,
           pe.ccss_obrero, pe.base_renta, pe.renta, pe.otras_deducciones, pe.neto, pe.ccss_patronal, pe.advertencias
      FROM rrhh_planilla_empleados pe JOIN rrhh_planillas pl ON pl.id = pe.planilla_id
     WHERE pl.id = p_id AND pl.empresa_id = p_empresa_id AND pl.deleted_at IS NULL AND (p_empleado_id IS NULL OR pe.empleado_id = p_empleado_id)
     ORDER BY pe.codigo;
END; $$;


--
-- Name: sp_rrhh_planilla_estado(bigint, bigint, character varying, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_planilla_estado(p_empresa_id bigint, p_id bigint, p_accion character varying, p_user_id bigint, p_nota character varying DEFAULT NULL::character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_p RECORD;
BEGIN
    SELECT * INTO v_p FROM rrhh_planillas pl WHERE pl.id = p_id AND pl.empresa_id = p_empresa_id AND pl.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;

    IF p_accion = 'aprobar' THEN
        IF v_p.estado <> 'calculada' THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Solo se puede aprobar una planilla calculada.'; END IF;
        IF v_p.total_empleados = 0 THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: La planilla no tiene empleados.'; END IF;
        UPDATE rrhh_planillas SET estado = 'aprobada', aprobada_por = p_user_id, aprobada_at = NOW(), updated_at = NOW() WHERE id = p_id;
    ELSIF p_accion = 'reabrir' THEN
        IF v_p.estado <> 'aprobada' THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Solo se puede reabrir una planilla aprobada.'; END IF;
        UPDATE rrhh_planillas SET estado = 'calculada', aprobada_por = NULL, aprobada_at = NULL, updated_at = NOW() WHERE id = p_id;
    ELSIF p_accion = 'pagar' THEN
        IF v_p.estado <> 'aprobada' THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Solo se puede marcar como pagada una planilla aprobada.'; END IF;
        UPDATE rrhh_planillas SET estado = 'pagada', pagada_por = p_user_id, pagada_at = NOW(), updated_at = NOW() WHERE id = p_id;
    ELSIF p_accion = 'anular' THEN
        IF v_p.estado NOT IN ('borrador', 'calculada', 'aprobada') THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: No se puede anular una planilla %.', v_p.estado; END IF;
        IF btrim(COALESCE(p_nota, '')) = '' THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Indique el motivo de la anulación.'; END IF;
        UPDATE rrhh_planillas SET estado = 'anulada', anulada_por = p_user_id, anulada_at = NOW(), anulada_nota = btrim(p_nota), updated_at = NOW() WHERE id = p_id;
    ELSE
        RAISE EXCEPTION 'PLANILLA_INVALIDA: Acción desconocida.';
    END IF;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_planilla_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_planilla_get(p_empresa_id bigint, p_id bigint) RETURNS TABLE(id bigint, nombre character varying, periodicidad character varying, fecha_inicio date, fecha_fin date, fecha_pago date, moneda character varying, descontar_tardanzas boolean, estado character varying, notas character varying, tasas_validadas boolean, total_empleados integer, total_devengado numeric, total_ccss_obrero numeric, total_renta numeric, total_otras_ded numeric, total_neto numeric, total_ccss_patronal numeric, calculada_at timestamp without time zone, aprobada_at timestamp without time zone, pagada_at timestamp without time zone, anulada_nota character varying, created_at timestamp without time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT pl.id, pl.nombre::VARCHAR, pl.periodicidad::VARCHAR, pl.fecha_inicio, pl.fecha_fin, pl.fecha_pago, pl.moneda::VARCHAR, pl.descontar_tardanzas, pl.estado::VARCHAR, pl.notas::VARCHAR, pl.tasas_validadas, pl.total_empleados, pl.total_devengado, pl.total_ccss_obrero, pl.total_renta, pl.total_otras_ded, pl.total_neto, pl.total_ccss_patronal, pl.calculada_at, pl.aprobada_at, pl.pagada_at, pl.anulada_nota::VARCHAR, pl.created_at FROM rrhh_planillas pl WHERE pl.empresa_id = p_empresa_id AND pl.id = p_id AND pl.deleted_at IS NULL;
END; $$;


--
-- Name: sp_rrhh_planilla_linea_create(bigint, bigint, bigint, bigint, character varying, character varying, numeric, boolean, boolean, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_planilla_linea_create(p_empresa_id bigint, p_id bigint, p_empleado_id bigint, p_concepto_id bigint, p_descripcion character varying, p_tipo character varying, p_monto numeric, p_afecta_ccss boolean, p_afecta_renta boolean, p_user_id bigint) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_estado VARCHAR; v_c RECORD; v_id BIGINT; v_desc VARCHAR := btrim(COALESCE(p_descripcion, '')); v_tipo VARCHAR := p_tipo; v_cod VARCHAR := NULL;
        v_ccss BOOLEAN := COALESCE(p_afecta_ccss, FALSE); v_rta BOOLEAN := COALESCE(p_afecta_renta, FALSE);
BEGIN
    SELECT pl.estado INTO v_estado FROM rrhh_planillas pl WHERE pl.id = p_id AND pl.empresa_id = p_empresa_id AND pl.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: La planilla no existe.'; END IF;
    IF v_estado NOT IN ('borrador', 'calculada') THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Solo se pueden agregar líneas a una planilla en borrador o calculada.'; END IF;
    IF NOT EXISTS (SELECT 1 FROM rrhh_planilla_empleados pe WHERE pe.planilla_id = p_id AND pe.empleado_id = p_empleado_id) THEN
        RAISE EXCEPTION 'PLANILLA_INVALIDA: El empleado no está en la planilla; calcúlela primero.';
    END IF;
    IF COALESCE(p_monto, 0) <= 0 THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: El monto debe ser mayor que cero.'; END IF;
    IF p_concepto_id IS NOT NULL THEN
        SELECT * INTO v_c FROM rrhh_conceptos c WHERE c.id = p_concepto_id AND c.empresa_id = p_empresa_id AND c.deleted_at IS NULL AND c.is_active;
        IF NOT FOUND THEN RAISE EXCEPTION 'CONCEPTO_INVALIDO: El concepto no existe o está inactivo.'; END IF;
        v_tipo := v_c.tipo; v_cod := v_c.codigo; v_ccss := v_c.afecta_ccss; v_rta := v_c.afecta_renta;
        IF v_desc = '' THEN v_desc := v_c.nombre; END IF;
    END IF;
    IF v_tipo NOT IN ('ingreso', 'deduccion') THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: El tipo debe ser ingreso o deducción.'; END IF;
    IF v_desc = '' THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Indique la descripción de la línea.'; END IF;
    IF v_tipo = 'deduccion' THEN v_ccss := FALSE; v_rta := FALSE; END IF;
    INSERT INTO rrhh_planilla_lineas (planilla_id, empleado_id, concepto_id, codigo, descripcion, tipo, monto, origen, afecta_ccss, afecta_renta, creada_por)
    VALUES (p_id, p_empleado_id, p_concepto_id, v_cod, v_desc, v_tipo, p_monto, 'manual', v_ccss, v_rta, p_user_id)
    RETURNING rrhh_planilla_lineas.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_planilla_linea_delete(bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_planilla_linea_delete(p_empresa_id bigint, p_id bigint, p_linea_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_estado VARCHAR; v_n INTEGER;
BEGIN
    SELECT pl.estado INTO v_estado FROM rrhh_planillas pl WHERE pl.id = p_id AND pl.empresa_id = p_empresa_id AND pl.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF v_estado NOT IN ('borrador', 'calculada') THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Solo se pueden quitar líneas de una planilla en borrador o calculada.'; END IF;
    DELETE FROM rrhh_planilla_lineas WHERE id = p_linea_id AND planilla_id = p_id AND origen = 'manual';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n > 0;
END; $$;


--
-- Name: sp_rrhh_planilla_lineas(bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_planilla_lineas(p_empresa_id bigint, p_id bigint, p_empleado_id bigint DEFAULT NULL::bigint) RETURNS TABLE(id bigint, empleado_id bigint, concepto_id bigint, codigo character varying, descripcion character varying, tipo character varying, monto numeric, origen character varying, afecta_ccss boolean, afecta_renta boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT l.id, l.empleado_id, l.concepto_id, l.codigo::VARCHAR, l.descripcion::VARCHAR, l.tipo::VARCHAR, l.monto, l.origen::VARCHAR, l.afecta_ccss, l.afecta_renta
      FROM rrhh_planilla_lineas l JOIN rrhh_planillas pl ON pl.id = l.planilla_id
     WHERE pl.id = p_id AND pl.empresa_id = p_empresa_id AND pl.deleted_at IS NULL AND (p_empleado_id IS NULL OR l.empleado_id = p_empleado_id)
     ORDER BY l.empleado_id, l.tipo DESC, l.id;
END; $$;


--
-- Name: sp_rrhh_planilla_list(bigint, character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_planilla_list(p_empresa_id bigint, p_estado character varying DEFAULT NULL::character varying, p_anio integer DEFAULT NULL::integer) RETURNS TABLE(id bigint, nombre character varying, periodicidad character varying, fecha_inicio date, fecha_fin date, fecha_pago date, moneda character varying, descontar_tardanzas boolean, estado character varying, notas character varying, tasas_validadas boolean, total_empleados integer, total_devengado numeric, total_ccss_obrero numeric, total_renta numeric, total_otras_ded numeric, total_neto numeric, total_ccss_patronal numeric, calculada_at timestamp without time zone, aprobada_at timestamp without time zone, pagada_at timestamp without time zone, anulada_nota character varying, created_at timestamp without time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT pl.id, pl.nombre::VARCHAR, pl.periodicidad::VARCHAR, pl.fecha_inicio, pl.fecha_fin, pl.fecha_pago, pl.moneda::VARCHAR, pl.descontar_tardanzas, pl.estado::VARCHAR, pl.notas::VARCHAR, pl.tasas_validadas, pl.total_empleados, pl.total_devengado, pl.total_ccss_obrero, pl.total_renta, pl.total_otras_ded, pl.total_neto, pl.total_ccss_patronal, pl.calculada_at, pl.aprobada_at, pl.pagada_at, pl.anulada_nota::VARCHAR, pl.created_at FROM rrhh_planillas pl
     WHERE pl.empresa_id = p_empresa_id AND pl.deleted_at IS NULL
       AND (p_estado IS NULL OR pl.estado = p_estado)
       AND (p_anio IS NULL OR EXTRACT(YEAR FROM pl.fecha_fin) = p_anio)
     ORDER BY pl.fecha_inicio DESC, pl.id DESC;
END; $$;


--
-- Name: sp_rrhh_planilla_update(bigint, bigint, character varying, date, boolean, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_planilla_update(p_empresa_id bigint, p_id bigint, p_nombre character varying, p_pago date, p_descontar_tardanzas boolean, p_notas character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_p RECORD; v_nom VARCHAR := btrim(COALESCE(p_nombre, ''));
BEGIN
    SELECT * INTO v_p FROM rrhh_planillas pl WHERE pl.id = p_id AND pl.empresa_id = p_empresa_id AND pl.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF v_p.estado NOT IN ('borrador', 'calculada') THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Solo se puede editar una planilla en borrador o calculada.'; END IF;
    IF v_nom = '' THEN RAISE EXCEPTION 'PLANILLA_INVALIDA: Indique el nombre de la planilla.'; END IF;
    IF p_pago IS NULL OR p_pago < v_p.fecha_inicio THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha de pago es anterior al inicio del período.'; END IF;
    UPDATE rrhh_planillas
       SET nombre = v_nom, fecha_pago = p_pago, notas = NULLIF(btrim(COALESCE(p_notas, '')), ''), updated_at = NOW(),
           descontar_tardanzas = COALESCE(p_descontar_tardanzas, descontar_tardanzas),
           estado = CASE WHEN descontar_tardanzas IS DISTINCT FROM COALESCE(p_descontar_tardanzas, descontar_tardanzas) THEN 'borrador' ELSE estado END
     WHERE id = p_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_puesto_create(bigint, character varying, character varying, bigint, character varying, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_puesto_create(p_empresa_id bigint, p_nombre character varying, p_descripcion character varying, p_departamento_id bigint, p_categoria character varying, p_salario_minimo numeric, p_salario_maximo numeric) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_id BIGINT;
BEGIN
    IF p_departamento_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM rrhh_departamentos WHERE id = p_departamento_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El departamento indicado no existe.';
    END IF;
    INSERT INTO rrhh_puestos (empresa_id, nombre, descripcion, departamento_id, categoria, salario_minimo, salario_maximo)
    VALUES (p_empresa_id, btrim(p_nombre), NULLIF(btrim(COALESCE(p_descripcion, '')), ''), p_departamento_id,
            NULLIF(p_categoria, ''), p_salario_minimo, p_salario_maximo)
    RETURNING rrhh_puestos.id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_puesto_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_puesto_get(p_id bigint, p_empresa_id bigint) RETURNS TABLE(id bigint, empresa_id bigint, nombre character varying, descripcion character varying, departamento_id bigint, categoria character varying, salario_minimo numeric, salario_maximo numeric, is_active boolean, deleted_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT p.id, p.empresa_id, p.nombre, p.descripcion, p.departamento_id, p.categoria,
           p.salario_minimo, p.salario_maximo, p.is_active, p.deleted_at
    FROM rrhh_puestos p WHERE p.id = p_id AND p.empresa_id = p_empresa_id;
END; $$;


--
-- Name: sp_rrhh_puesto_list(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_puesto_list(p_empresa_id bigint, p_eliminados boolean DEFAULT false) RETURNS TABLE(id bigint, empresa_id bigint, nombre character varying, descripcion character varying, departamento_id bigint, departamento_nombre character varying, categoria character varying, salario_minimo numeric, salario_maximo numeric, is_active boolean, deleted_at timestamp without time zone, empleados bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT p.id, p.empresa_id, p.nombre, p.descripcion, p.departamento_id, d.nombre, p.categoria,
           p.salario_minimo, p.salario_maximo, p.is_active, p.deleted_at,
           (SELECT COUNT(*) FROM rrhh_empleados e
             WHERE e.puesto_id = p.id AND e.deleted_at IS NULL AND e.estado <> 'liquidado')
    FROM rrhh_puestos p
    LEFT JOIN rrhh_departamentos d ON d.id = p.departamento_id
    WHERE p.empresa_id = p_empresa_id
      AND ((p_eliminados AND p.deleted_at IS NOT NULL) OR (NOT p_eliminados AND p.deleted_at IS NULL))
    ORDER BY lower(p.nombre);
END; $$;


--
-- Name: sp_rrhh_puesto_restore(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_puesto_restore(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    UPDATE rrhh_puestos SET deleted_at = NULL, is_active = TRUE, updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NOT NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_puesto_soft_delete(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_puesto_soft_delete(p_id bigint, p_empresa_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_n FROM rrhh_empleados
     WHERE puesto_id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL AND estado <> 'liquidado';
    IF v_n > 0 THEN
        RAISE EXCEPTION 'PUESTO_EN_USO: El puesto lo ocupan % empleado(s); cámbieles el puesto antes de eliminarlo.', v_n;
    END IF;
    UPDATE rrhh_puestos SET is_active = FALSE, deleted_at = NOW(), updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_puesto_update(bigint, bigint, character varying, character varying, bigint, character varying, numeric, numeric, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_puesto_update(p_id bigint, p_empresa_id bigint, p_nombre character varying, p_descripcion character varying, p_departamento_id bigint, p_categoria character varying, p_salario_minimo numeric, p_salario_maximo numeric, p_is_active boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF p_departamento_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM rrhh_departamentos WHERE id = p_departamento_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El departamento indicado no existe.';
    END IF;
    UPDATE rrhh_puestos SET
        nombre = btrim(p_nombre), descripcion = NULLIF(btrim(COALESCE(p_descripcion, '')), ''),
        departamento_id = p_departamento_id, categoria = NULLIF(p_categoria, ''),
        salario_minimo = p_salario_minimo, salario_maximo = p_salario_maximo,
        is_active = p_is_active, updated_at = NOW()
    WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    RETURN FOUND;
END; $$;


--
-- Name: sp_rrhh_renta_tramos_list(bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_renta_tramos_list(p_empresa_id bigint, p_anio integer) RETURNS TABLE(orden integer, desde numeric, hasta numeric, porcentaje numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT r.orden, r.desde, r.hasta, r.porcentaje FROM rrhh_renta_tramos r
     WHERE r.empresa_id = p_empresa_id AND r.anio = p_anio ORDER BY r.orden;
$$;


--
-- Name: sp_rrhh_tasas_anios(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_tasas_anios(p_empresa_id bigint) RETURNS TABLE(anio integer, credito_hijo numeric, credito_conyuge numeric, fuente character varying, validado boolean, obrero_pct numeric, patronal_pct numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT t.anio, t.credito_hijo, t.credito_conyuge, t.fuente::VARCHAR, t.validado,
           COALESCE((SELECT SUM(c.porcentaje) FROM rrhh_cargas_sociales c WHERE c.empresa_id = t.empresa_id AND c.anio = t.anio AND c.parte = 'obrero'), 0)::NUMERIC,
           COALESCE((SELECT SUM(c.porcentaje) FROM rrhh_cargas_sociales c WHERE c.empresa_id = t.empresa_id AND c.anio = t.anio AND c.parte = 'patronal'), 0)::NUMERIC
      FROM rrhh_tasas_anio t WHERE t.empresa_id = p_empresa_id ORDER BY t.anio DESC;
END; $$;


--
-- Name: sp_rrhh_tasas_cargar(bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_tasas_cargar(p_empresa_id bigint, p_anio integer) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_prev INTEGER;
BEGIN
    IF p_anio IS NULL OR p_anio < 2000 OR p_anio > 2100 THEN RAISE EXCEPTION 'TASAS_INVALIDAS: Año inválido.'; END IF;
    IF EXISTS (SELECT 1 FROM rrhh_tasas_anio t WHERE t.empresa_id = p_empresa_id AND t.anio = p_anio) THEN RETURN FALSE; END IF;

    SELECT MAX(t.anio) INTO v_prev FROM rrhh_tasas_anio t WHERE t.empresa_id = p_empresa_id AND t.anio < p_anio;
    IF v_prev IS NOT NULL THEN
        INSERT INTO rrhh_tasas_anio (empresa_id, anio, credito_hijo, credito_conyuge, fuente, validado)
        SELECT p_empresa_id, p_anio, t.credito_hijo, t.credito_conyuge, 'Copiado de ' || v_prev || ': verifique los valores del año', FALSE
          FROM rrhh_tasas_anio t WHERE t.empresa_id = p_empresa_id AND t.anio = v_prev;
        INSERT INTO rrhh_cargas_sociales (empresa_id, anio, rubro, parte, porcentaje, orden)
        SELECT p_empresa_id, p_anio, c.rubro, c.parte, c.porcentaje, c.orden FROM rrhh_cargas_sociales c WHERE c.empresa_id = p_empresa_id AND c.anio = v_prev;
        INSERT INTO rrhh_renta_tramos (empresa_id, anio, orden, desde, hasta, porcentaje)
        SELECT p_empresa_id, p_anio, r.orden, r.desde, r.hasta, r.porcentaje FROM rrhh_renta_tramos r WHERE r.empresa_id = p_empresa_id AND r.anio = v_prev;
        RETURN TRUE;
    END IF;

    INSERT INTO rrhh_tasas_anio (empresa_id, anio, credito_hijo, credito_conyuge, fuente, validado)
    VALUES (p_empresa_id, p_anio, 1710, 2590,
            'Valores 2026: Decreto 45333-H (renta salarios) y tasas CCSS vigentes. Validar con el contador.', FALSE);

    INSERT INTO rrhh_cargas_sociales (empresa_id, anio, rubro, parte, porcentaje, orden)
    VALUES (p_empresa_id, p_anio, 'SEM (Enfermedad y Maternidad)', 'obrero', 5.50, 1),
           (p_empresa_id, p_anio, 'IVM (Invalidez, Vejez y Muerte)', 'obrero', 4.33, 2),
           (p_empresa_id, p_anio, 'Banco Popular (aporte obrero)', 'obrero', 1.00, 3),
           (p_empresa_id, p_anio, 'SEM (Enfermedad y Maternidad)', 'patronal', 9.25, 1),
           (p_empresa_id, p_anio, 'IVM (Invalidez, Vejez y Muerte)', 'patronal', 5.58, 2),
           (p_empresa_id, p_anio, 'Cuota Banco Popular', 'patronal', 0.25, 3),
           (p_empresa_id, p_anio, 'Asignaciones Familiares (FODESAF)', 'patronal', 5.00, 4),
           (p_empresa_id, p_anio, 'IMAS', 'patronal', 0.50, 5),
           (p_empresa_id, p_anio, 'INA', 'patronal', 1.50, 6),
           (p_empresa_id, p_anio, 'Aporte Banco Popular', 'patronal', 0.25, 7),
           (p_empresa_id, p_anio, 'Fondo de Capitalización Laboral', 'patronal', 1.50, 8),
           (p_empresa_id, p_anio, 'Operadora de Pensiones (ROP)', 'patronal', 2.00, 9),
           (p_empresa_id, p_anio, 'INS (Riesgos del Trabajo)', 'patronal', 1.00, 10);

    INSERT INTO rrhh_renta_tramos (empresa_id, anio, orden, desde, hasta, porcentaje)
    VALUES (p_empresa_id, p_anio, 1, 0, 918000, 0),
           (p_empresa_id, p_anio, 2, 918000, 1347000, 10),
           (p_empresa_id, p_anio, 3, 1347000, 2364000, 15),
           (p_empresa_id, p_anio, 4, 2364000, 4727000, 20),
           (p_empresa_id, p_anio, 5, 4727000, NULL, 25);
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_tasas_guardar(bigint, integer, numeric, numeric, character varying, boolean, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_tasas_guardar(p_empresa_id bigint, p_anio integer, p_credito_hijo numeric, p_credito_conyuge numeric, p_fuente character varying, p_validado boolean, p_cargas jsonb, p_tramos jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_prev NUMERIC := NULL; v_r RECORD; v_n INTEGER := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_tasas_anio t WHERE t.empresa_id = p_empresa_id AND t.anio = p_anio) THEN
        RAISE EXCEPTION 'TASAS_INVALIDAS: Las tasas de ese año no existen.';
    END IF;
    IF COALESCE(p_credito_hijo, 0) < 0 OR COALESCE(p_credito_conyuge, 0) < 0 THEN RAISE EXCEPTION 'TASAS_INVALIDAS: Los créditos no pueden ser negativos.'; END IF;
    IF jsonb_typeof(p_cargas) <> 'array' OR jsonb_typeof(p_tramos) <> 'array' THEN RAISE EXCEPTION 'TASAS_INVALIDAS: Datos incompletos.'; END IF;

    -- tramos: contiguos y ascendentes, el último sin tope
    FOR v_r IN SELECT x.desde, x.hasta, x.porcentaje FROM jsonb_to_recordset(p_tramos) AS x(desde NUMERIC, hasta NUMERIC, porcentaje NUMERIC) LOOP
        v_n := v_n + 1;
        IF v_r.desde IS NULL OR v_r.porcentaje IS NULL OR v_r.porcentaje < 0 OR v_r.porcentaje > 100 THEN RAISE EXCEPTION 'TASAS_INVALIDAS: Tramo de renta %: datos inválidos.', v_n; END IF;
        IF v_prev IS NULL AND v_r.desde <> 0 THEN RAISE EXCEPTION 'TASAS_INVALIDAS: El primer tramo debe empezar en 0.'; END IF;
        IF v_prev IS NOT NULL AND v_r.desde <> v_prev THEN RAISE EXCEPTION 'TASAS_INVALIDAS: El tramo % debe empezar donde termina el anterior.', v_n; END IF;
        IF v_r.hasta IS NOT NULL AND v_r.hasta <= v_r.desde THEN RAISE EXCEPTION 'TASAS_INVALIDAS: Tramo de renta %: el límite superior debe ser mayor que el inferior.', v_n; END IF;
        v_prev := v_r.hasta;
        IF v_r.hasta IS NULL THEN EXIT; END IF;
    END LOOP;
    IF v_n = 0 THEN RAISE EXCEPTION 'TASAS_INVALIDAS: Indique al menos un tramo de renta.'; END IF;
    IF v_prev IS NOT NULL THEN RAISE EXCEPTION 'TASAS_INVALIDAS: El último tramo de renta debe quedar sin tope.'; END IF;

    FOR v_r IN SELECT x.rubro, x.parte, x.porcentaje FROM jsonb_to_recordset(p_cargas) AS x(rubro TEXT, parte TEXT, porcentaje NUMERIC) LOOP
        IF btrim(COALESCE(v_r.rubro, '')) = '' OR v_r.parte NOT IN ('obrero', 'patronal') OR v_r.porcentaje IS NULL OR v_r.porcentaje < 0 OR v_r.porcentaje > 100 THEN
            RAISE EXCEPTION 'TASAS_INVALIDAS: Hay una carga social con datos inválidos.';
        END IF;
    END LOOP;

    UPDATE rrhh_tasas_anio
       SET credito_hijo = COALESCE(p_credito_hijo, 0), credito_conyuge = COALESCE(p_credito_conyuge, 0),
           fuente = NULLIF(btrim(COALESCE(p_fuente, '')), ''), validado = COALESCE(p_validado, FALSE), updated_at = NOW()
     WHERE empresa_id = p_empresa_id AND anio = p_anio;

    DELETE FROM rrhh_cargas_sociales WHERE empresa_id = p_empresa_id AND anio = p_anio;
    INSERT INTO rrhh_cargas_sociales (empresa_id, anio, rubro, parte, porcentaje, orden)
    SELECT p_empresa_id, p_anio, btrim(x.rubro), x.parte, x.porcentaje, (row_number() OVER ())::INTEGER
      FROM jsonb_to_recordset(p_cargas) AS x(rubro TEXT, parte TEXT, porcentaje NUMERIC);

    DELETE FROM rrhh_renta_tramos WHERE empresa_id = p_empresa_id AND anio = p_anio;
    INSERT INTO rrhh_renta_tramos (empresa_id, anio, orden, desde, hasta, porcentaje)
    SELECT p_empresa_id, p_anio, (row_number() OVER ())::INTEGER, x.desde, x.hasta, x.porcentaje
      FROM jsonb_to_recordset(p_tramos) AS x(desde NUMERIC, hasta NUMERIC, porcentaje NUMERIC);
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_vac_calendario(bigint, date, date, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_calendario(p_empresa_id bigint, p_desde date, p_hasta date, p_departamento_id bigint DEFAULT NULL::bigint) RETURNS TABLE(id bigint, empleado_id bigint, empleado_nombre character varying, departamento_id bigint, departamento_nombre character varying, departamento_total integer, fecha_inicio date, fecha_fin date, dias integer, estado character varying)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF p_hasta < p_desde THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha final es anterior a la inicial.'; END IF;
    IF p_hasta - p_desde > 92 THEN RAISE EXCEPTION 'FECHA_INVALIDA: El rango de fechas no puede pasar de 93 días.'; END IF;
    RETURN QUERY
    SELECT s.id, s.empleado_id, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR,
           e.departamento_id, dp.nombre::VARCHAR,
           (SELECT COUNT(*)::INTEGER FROM rrhh_empleados x WHERE x.empresa_id = p_empresa_id AND x.deleted_at IS NULL AND x.estado = 'activo'
               AND x.departamento_id IS NOT DISTINCT FROM e.departamento_id),
           s.fecha_inicio, s.fecha_fin, s.dias, s.estado::VARCHAR
      FROM rrhh_vacaciones_solicitudes s
      JOIN rrhh_empleados e ON e.id = s.empleado_id
      LEFT JOIN rrhh_departamentos dp ON dp.id = e.departamento_id
     WHERE s.empresa_id = p_empresa_id AND s.deleted_at IS NULL AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada')
       AND s.fecha_inicio <= p_hasta AND s.fecha_fin >= p_desde
       AND (p_departamento_id IS NULL OR e.departamento_id = p_departamento_id)
     ORDER BY dp.nombre NULLS LAST, s.fecha_inicio, e.nombre;
END; $$;


--
-- Name: sp_rrhh_vac_cancelar(bigint, bigint, bigint, boolean, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_cancelar(p_empresa_id bigint, p_id bigint, p_actor_empleado_id bigint, p_es_rrhh boolean, p_nota character varying DEFAULT NULL::character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_s    RECORD;
    v_user BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
BEGIN
    SELECT s.* INTO v_s FROM rrhh_vacaciones_solicitudes s WHERE s.id = p_id AND s.empresa_id = p_empresa_id AND s.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    IF NOT p_es_rrhh AND (p_actor_empleado_id IS NULL OR p_actor_empleado_id <> v_s.empleado_id) THEN
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: Solo quien solicitó las vacaciones puede cancelarlas.';
    END IF;
    IF v_s.estado IN ('pendiente_jefe', 'pendiente_rrhh') THEN
        NULL;
    ELSIF v_s.estado = 'aprobada' THEN
        IF NOT p_es_rrhh THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: Una solicitud aprobada solo la puede cancelar Recursos Humanos.'; END IF;
        IF v_s.fecha_inicio <= CURRENT_DATE THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: Las vacaciones ya empezaron; corrija el saldo con un ajuste.'; END IF;
    ELSE
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: La solicitud ya estaba %.', v_s.estado;
    END IF;
    UPDATE rrhh_vacaciones_solicitudes
       SET estado = 'cancelada', rrhh_resuelto_por = CASE WHEN p_es_rrhh THEN v_user ELSE rrhh_resuelto_por END,
           rrhh_resuelto_at = CASE WHEN p_es_rrhh THEN NOW() ELSE rrhh_resuelto_at END,
           rrhh_nota = CASE WHEN p_es_rrhh THEN NULLIF(btrim(COALESCE(p_nota, '')), '') ELSE rrhh_nota END, updated_at = NOW()
     WHERE id = p_id;
    RETURN TRUE;
END; $$;


--
-- Name: sp_rrhh_vac_mov_eliminar(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_mov_eliminar(p_empresa_id bigint, p_id bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_n INTEGER;
BEGIN
    UPDATE rrhh_vacaciones_movimientos SET deleted_at = NOW(), updated_at = NOW() WHERE id = p_id AND empresa_id = p_empresa_id AND deleted_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n > 0;
END; $$;


--
-- Name: sp_rrhh_vac_mov_guardar(bigint, bigint, character varying, numeric, date, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_mov_guardar(p_empresa_id bigint, p_empleado_id bigint, p_tipo character varying, p_dias numeric, p_fecha date, p_motivo character varying) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_user   BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    v_motivo VARCHAR := NULLIF(btrim(COALESCE(p_motivo, '')), '');
    v_dias   NUMERIC := p_dias;
    v_id     BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM rrhh_empleados WHERE id = p_empleado_id AND empresa_id = p_empresa_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.';
    END IF;
    IF p_tipo = 'saldo_inicial' THEN
        -- Se recibe lo ya disfrutado (positivo) y se guarda como descuento.
        IF p_dias IS NULL OR p_dias <= 0 THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: Indique cuántos días ya disfrutó (mayor que cero).'; END IF;
        v_dias := -p_dias;
        UPDATE rrhh_vacaciones_movimientos SET dias = v_dias, fecha = p_fecha, motivo = v_motivo, usuario_id = v_user, updated_at = NOW()
         WHERE empleado_id = p_empleado_id AND tipo = 'saldo_inicial' AND deleted_at IS NULL
        RETURNING id INTO v_id;
    ELSIF p_tipo = 'ajuste' THEN
        IF p_dias IS NULL OR p_dias = 0 THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: El ajuste no puede ser cero.'; END IF;
        IF v_motivo IS NULL THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: Indique el motivo del ajuste.'; END IF;
    ELSE
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: Tipo de movimiento desconocido.';
    END IF;
    IF v_id IS NULL THEN
        INSERT INTO rrhh_vacaciones_movimientos (empresa_id, empleado_id, tipo, dias, fecha, motivo, usuario_id)
        VALUES (p_empresa_id, p_empleado_id, p_tipo, v_dias, p_fecha, v_motivo, v_user) RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_vac_mov_list(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_mov_list(p_empresa_id bigint, p_empleado_id bigint) RETURNS TABLE(id bigint, tipo character varying, dias numeric, fecha date, motivo character varying, usuario_id bigint, created_at timestamp without time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT m.id, m.tipo::VARCHAR, m.dias, m.fecha, m.motivo::VARCHAR, m.usuario_id, m.created_at
      FROM rrhh_vacaciones_movimientos m
     WHERE m.empresa_id = p_empresa_id AND m.empleado_id = p_empleado_id AND m.deleted_at IS NULL
     ORDER BY m.created_at DESC, m.id DESC;
END; $$;


--
-- Name: sp_rrhh_vac_pagos(bigint, date, date, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_pagos(p_empresa_id bigint, p_desde date, p_hasta date, p_empleado_id bigint DEFAULT NULL::bigint) RETURNS TABLE(solicitud_id bigint, empleado_id bigint, empleado_codigo character varying, empleado_nombre character varying, fecha_inicio date, fecha_fin date, dias integer, valor_dia numeric, extras_dia numeric, promedio_dia numeric, monto numeric, monto_ordinario numeric, monto_extras numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    IF p_hasta < p_desde THEN RAISE EXCEPTION 'FECHA_INVALIDA: La fecha final es anterior a la inicial.'; END IF;
    IF p_hasta - p_desde > 366 THEN RAISE EXCEPTION 'FECHA_INVALIDA: El rango de fechas no puede pasar de un año.'; END IF;
    RETURN QUERY
    SELECT s.id, s.empleado_id, e.codigo::VARCHAR, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR,
           s.fecha_inicio, s.fecha_fin, s.dias, t.valor_dia, t.extras_dia, t.promedio_dia,
           round(s.dias * t.promedio_dia, 2), round(s.dias * t.valor_dia, 2), round(s.dias * t.extras_dia, 2)
      FROM rrhh_vacaciones_solicitudes s
      JOIN rrhh_empleados e ON e.id = s.empleado_id
      CROSS JOIN LATERAL fn_rrhh_vac_tarifa(p_empresa_id, s.empleado_id, s.fecha_inicio) t
     WHERE s.empresa_id = p_empresa_id AND s.deleted_at IS NULL AND s.estado = 'aprobada'
       AND s.fecha_inicio BETWEEN p_desde AND p_hasta AND (p_empleado_id IS NULL OR s.empleado_id = p_empleado_id)
     ORDER BY s.fecha_inicio, e.nombre;
END; $$;


--
-- Name: sp_rrhh_vac_previsualizar(bigint, bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_previsualizar(p_empresa_id bigint, p_empleado_id bigint, p_inicio date, p_fin date) RETURNS TABLE(dias integer, disponible numeric, elegible_desde date, valida boolean, mensaje character varying)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_ing DATE;
    v_msg VARCHAR := NULL;
BEGIN
    SELECT e.fecha_ingreso INTO v_ing FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'REF_INVALIDA: El empleado no existe.'; END IF;
    dias := CASE WHEN p_fin >= p_inicio AND p_fin - p_inicio <= 400 THEN fn_rrhh_dias_habiles(p_empresa_id, p_empleado_id, p_inicio, p_fin) ELSE 0 END;
    disponible := fn_rrhh_vac_devengado(p_empleado_id, p_inicio) + fn_rrhh_vac_movimientos(p_empleado_id) - fn_rrhh_vac_reservado(p_empleado_id, NULL);
    elegible_desde := v_ing + 350;
    BEGIN
        PERFORM fn_rrhh_vac_validar(p_empresa_id, p_empleado_id, p_inicio, p_fin, NULL);
    EXCEPTION WHEN OTHERS THEN
        v_msg := regexp_replace(SQLERRM, '^[A-Z_]+:\s*', '');
    END;
    valida := v_msg IS NULL;
    mensaje := v_msg;
    RETURN NEXT;
END; $$;


--
-- Name: sp_rrhh_vac_resolver(bigint, bigint, character varying, boolean, character varying, bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_resolver(p_empresa_id bigint, p_id bigint, p_etapa character varying, p_aprobar boolean, p_nota character varying, p_actor_empleado_id bigint DEFAULT NULL::bigint, p_omitir_jefe boolean DEFAULT false) RETURNS character varying
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_s     RECORD;
    v_nota  VARCHAR := NULLIF(btrim(COALESCE(p_nota, '')), '');
    v_user  BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    v_dias  INTEGER;
BEGIN
    SELECT s.* INTO v_s FROM rrhh_vacaciones_solicitudes s WHERE s.id = p_id AND s.empresa_id = p_empresa_id AND s.deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF p_actor_empleado_id IS NOT NULL AND p_actor_empleado_id = v_s.empleado_id THEN
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: No puede resolver su propia solicitud.';
    END IF;

    IF p_etapa = 'jefe' THEN
        IF v_s.estado <> 'pendiente_jefe' THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: La solicitud ya no espera la aprobación del jefe.'; END IF;
        IF p_actor_empleado_id IS NULL OR p_actor_empleado_id IS DISTINCT FROM v_s.jefe_id THEN
            RAISE EXCEPTION 'VACACIONES_INVALIDAS: Solo el jefe inmediato del empleado puede resolver esta etapa.';
        END IF;
        IF NOT p_aprobar AND v_nota IS NULL THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: Indique el motivo del rechazo.'; END IF;
        UPDATE rrhh_vacaciones_solicitudes
           SET estado = CASE WHEN p_aprobar THEN 'pendiente_rrhh' ELSE 'rechazada' END,
               jefe_resuelto_por = v_user, jefe_resuelto_at = NOW(), jefe_nota = v_nota, updated_at = NOW()
         WHERE id = p_id;
        RETURN CASE WHEN p_aprobar THEN 'pendiente_rrhh' ELSE 'rechazada' END;
    END IF;

    IF p_etapa <> 'rrhh' THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: Etapa desconocida.'; END IF;
    IF v_s.estado = 'pendiente_jefe' THEN
        IF NOT p_omitir_jefe THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: Falta la aprobación del jefe inmediato.'; END IF;
        IF v_nota IS NULL THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: Indique por qué se resuelve sin el jefe.'; END IF;
    ELSIF v_s.estado <> 'pendiente_rrhh' THEN
        RAISE EXCEPTION 'VACACIONES_INVALIDAS: La solicitud ya no está pendiente.';
    END IF;
    IF NOT p_aprobar AND v_nota IS NULL THEN RAISE EXCEPTION 'VACACIONES_INVALIDAS: Indique el motivo del rechazo.'; END IF;

    IF p_aprobar THEN
        -- Se vuelve a validar: desde que se pidió pudo cambiar el saldo, los feriados o el horario.
        v_dias := fn_rrhh_vac_validar(p_empresa_id, v_s.empleado_id, v_s.fecha_inicio, v_s.fecha_fin, v_s.id);
    END IF;
    UPDATE rrhh_vacaciones_solicitudes
       SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END,
           dias = COALESCE(v_dias, dias),
           rrhh_resuelto_por = v_user, rrhh_resuelto_at = NOW(), rrhh_nota = v_nota, updated_at = NOW()
     WHERE id = p_id;
    RETURN CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END;
END; $$;


--
-- Name: sp_rrhh_vac_saldos(bigint, date, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_saldos(p_empresa_id bigint, p_fecha date, p_departamento_id bigint DEFAULT NULL::bigint, p_empleado_id bigint DEFAULT NULL::bigint) RETURNS TABLE(empleado_id bigint, empleado_codigo character varying, empleado_nombre character varying, departamento_id bigint, departamento_nombre character varying, jefe_id bigint, jefe_nombre character varying, fecha_ingreso date, estado character varying, meses integer, elegible_desde date, elegible boolean, devengado numeric, ajustes numeric, disfrutados numeric, programados numeric, pendientes numeric, acumulado numeric, disponible numeric, alerta character varying)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    WITH a AS (
        SELECT e.id AS eid, e.codigo AS cod,
               btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, '')) AS nom,
               e.departamento_id AS did, dp.nombre AS dnom, e.jefe_id AS jid,
               btrim(j.nombre || ' ' || j.apellido1 || ' ' || COALESCE(j.apellido2, '')) AS jnom,
               e.fecha_ingreso AS ingreso, e.estado AS est,
               fn_rrhh_vac_devengado(e.id, p_fecha) AS dev,
               fn_rrhh_vac_movimientos(e.id) AS aj,
               COALESCE((SELECT SUM(s.dias) FROM rrhh_vacaciones_solicitudes s WHERE s.empleado_id = e.id AND s.deleted_at IS NULL
                          AND s.estado = 'aprobada' AND s.fecha_fin <= p_fecha), 0)::NUMERIC AS disf,
               COALESCE((SELECT SUM(s.dias) FROM rrhh_vacaciones_solicitudes s WHERE s.empleado_id = e.id AND s.deleted_at IS NULL
                          AND s.estado = 'aprobada' AND s.fecha_fin > p_fecha), 0)::NUMERIC AS prog,
               COALESCE((SELECT SUM(s.dias) FROM rrhh_vacaciones_solicitudes s WHERE s.empleado_id = e.id AND s.deleted_at IS NULL
                          AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh')), 0)::NUMERIC AS pend,
               COALESCE((SELECT SUM(i.vac_repuestos) FROM rrhh_incapacidades i WHERE i.empleado_id = e.id AND i.deleted_at IS NULL
                          AND i.estado = 'registrada' AND i.vac_repuestos > 0 AND i.fecha_fin > p_fecha), 0)::NUMERIC AS rep
          FROM rrhh_empleados e
          LEFT JOIN rrhh_departamentos dp ON dp.id = e.departamento_id
          LEFT JOIN rrhh_empleados j ON j.id = e.jefe_id
         WHERE e.empresa_id = p_empresa_id AND e.deleted_at IS NULL AND e.estado <> 'liquidado' AND e.fecha_ingreso <= p_fecha
           AND (p_departamento_id IS NULL OR e.departamento_id = p_departamento_id)
           AND (p_empleado_id IS NULL OR e.id = p_empleado_id)
    ), b AS (
        SELECT a.*, LEAST(a.rep, a.prog) AS rep_prog FROM a
    )
    SELECT b.eid, b.cod::VARCHAR, b.nom::VARCHAR, b.did, b.dnom::VARCHAR, b.jid, b.jnom::VARCHAR, b.ingreso, b.est::VARCHAR,
           (EXTRACT(YEAR FROM age(p_fecha, b.ingreso)) * 12 + EXTRACT(MONTH FROM age(p_fecha, b.ingreso)))::INTEGER,
           (b.ingreso + 350), (p_fecha >= b.ingreso + 350),
           b.dev, (b.aj - b.rep_prog), b.disf, (b.prog - b.rep_prog), b.pend,
           (b.dev + b.aj - b.disf),
           (b.dev + (b.aj - b.rep_prog) - b.disf - (b.prog - b.rep_prog) - b.pend),
           (CASE WHEN b.dev + b.aj - b.disf > 24 THEN 'excedido' WHEN b.dev + b.aj - b.disf > 12 THEN 'atencion' ELSE 'ok' END)::VARCHAR
      FROM b ORDER BY b.nom;
END; $$;


--
-- Name: sp_rrhh_vac_solicitar(bigint, bigint, date, date, character varying, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_solicitar(p_empresa_id bigint, p_empleado_id bigint, p_inicio date, p_fin date, p_motivo character varying, p_directa boolean DEFAULT false) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_dias   INTEGER;
    v_jefe   BIGINT;
    v_estado VARCHAR;
    v_user   BIGINT := NULLIF(current_setting('app.current_user_id', true), '')::BIGINT;
    v_id     BIGINT;
BEGIN
    IF p_inicio < CURRENT_DATE AND NOT p_directa THEN
        RAISE EXCEPTION 'FECHA_INVALIDA: La fecha de inicio no puede ser anterior a hoy.';
    END IF;
    v_dias := fn_rrhh_vac_validar(p_empresa_id, p_empleado_id, p_inicio, p_fin, NULL);

    SELECT j.id INTO v_jefe FROM rrhh_empleados e
      JOIN rrhh_empleados j ON j.id = e.jefe_id AND j.deleted_at IS NULL AND j.estado = 'activo'
     WHERE e.id = p_empleado_id;

    v_estado := CASE WHEN p_directa THEN 'aprobada' WHEN v_jefe IS NOT NULL THEN 'pendiente_jefe' ELSE 'pendiente_rrhh' END;
    INSERT INTO rrhh_vacaciones_solicitudes (empresa_id, empleado_id, fecha_inicio, fecha_fin, dias, estado, jefe_id, motivo, creada_por,
                                             rrhh_resuelto_por, rrhh_resuelto_at, rrhh_nota)
    VALUES (p_empresa_id, p_empleado_id, p_inicio, p_fin, v_dias, v_estado, v_jefe, NULLIF(btrim(COALESCE(p_motivo, '')), ''), v_user,
            CASE WHEN p_directa THEN v_user END, CASE WHEN p_directa THEN NOW() END, CASE WHEN p_directa THEN 'Registrada directamente por RRHH' END)
    RETURNING id INTO v_id;
    RETURN v_id;
END; $$;


--
-- Name: sp_rrhh_vac_solicitud_list(bigint, character varying, bigint, date, date, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_solicitud_list(p_empresa_id bigint, p_estado character varying DEFAULT NULL::character varying, p_empleado_id bigint DEFAULT NULL::bigint, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_jefe_id bigint DEFAULT NULL::bigint) RETURNS TABLE(id bigint, empleado_id bigint, empleado_codigo character varying, empleado_nombre character varying, departamento_id bigint, departamento_nombre character varying, fecha_inicio date, fecha_fin date, dias integer, estado character varying, jefe_id bigint, jefe_nombre character varying, motivo character varying, jefe_resuelto_at timestamp without time zone, jefe_nota character varying, rrhh_resuelto_at timestamp without time zone, rrhh_nota character varying, created_at timestamp without time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT s.id, s.empleado_id, e.codigo::VARCHAR, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR,
           e.departamento_id, dp.nombre::VARCHAR, s.fecha_inicio, s.fecha_fin, s.dias, s.estado::VARCHAR, s.jefe_id,
           btrim(j.nombre || ' ' || j.apellido1 || ' ' || COALESCE(j.apellido2, ''))::VARCHAR, s.motivo::VARCHAR,
           s.jefe_resuelto_at, s.jefe_nota::VARCHAR, s.rrhh_resuelto_at, s.rrhh_nota::VARCHAR, s.created_at
      FROM rrhh_vacaciones_solicitudes s
      JOIN rrhh_empleados e ON e.id = s.empleado_id
      LEFT JOIN rrhh_departamentos dp ON dp.id = e.departamento_id
      LEFT JOIN rrhh_empleados j ON j.id = s.jefe_id
     WHERE s.empresa_id = p_empresa_id AND s.deleted_at IS NULL
       AND (p_estado IS NULL OR s.estado = p_estado)
       AND (p_empleado_id IS NULL OR s.empleado_id = p_empleado_id)
       AND (p_jefe_id IS NULL OR s.jefe_id = p_jefe_id)
       AND (p_desde IS NULL OR s.fecha_fin >= p_desde)
       AND (p_hasta IS NULL OR s.fecha_inicio <= p_hasta)
     ORDER BY (s.estado IN ('pendiente_jefe', 'pendiente_rrhh')) DESC, s.fecha_inicio DESC, s.id DESC
     LIMIT 500;
END; $$;


--
-- Name: sp_rrhh_vac_traslapes(bigint, bigint, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_traslapes(p_empresa_id bigint, p_empleado_id bigint, p_desde date, p_hasta date) RETURNS TABLE(empleado_id bigint, empleado_nombre character varying, fecha_inicio date, fecha_fin date, estado character varying, departamento_total integer)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_depto BIGINT;
BEGIN
    SELECT e.departamento_id INTO v_depto FROM rrhh_empleados e WHERE e.id = p_empleado_id AND e.empresa_id = p_empresa_id AND e.deleted_at IS NULL;
    IF v_depto IS NULL THEN RETURN; END IF;
    RETURN QUERY
    SELECT s.empleado_id, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR, s.fecha_inicio, s.fecha_fin, s.estado::VARCHAR,
           (SELECT COUNT(*)::INTEGER FROM rrhh_empleados x WHERE x.empresa_id = p_empresa_id AND x.deleted_at IS NULL AND x.estado = 'activo' AND x.departamento_id = v_depto)
      FROM rrhh_vacaciones_solicitudes s JOIN rrhh_empleados e ON e.id = s.empleado_id
     WHERE s.empresa_id = p_empresa_id AND s.deleted_at IS NULL AND s.estado IN ('pendiente_jefe', 'pendiente_rrhh', 'aprobada')
       AND e.departamento_id = v_depto AND s.empleado_id <> p_empleado_id AND s.fecha_inicio <= p_hasta AND s.fecha_fin >= p_desde
     ORDER BY s.fecha_inicio, e.nombre;
END; $$;


--
-- Name: sp_rrhh_vac_valoracion(bigint, date, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_rrhh_vac_valoracion(p_empresa_id bigint, p_fecha date, p_empleado_id bigint DEFAULT NULL::bigint) RETURNS TABLE(empleado_id bigint, empleado_codigo character varying, empleado_nombre character varying, fecha_ingreso date, saldo_dias numeric, salario_base numeric, periodo_pago character varying, valor_dia numeric, extras_50sem numeric, extras_dia numeric, promedio_dia numeric, monto_saldo numeric, monto_ordinario numeric)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT e.id, e.codigo::VARCHAR, btrim(e.nombre || ' ' || e.apellido1 || ' ' || COALESCE(e.apellido2, ''))::VARCHAR, e.fecha_ingreso,
           GREATEST(fn_rrhh_vac_devengado(e.id, p_fecha) + fn_rrhh_vac_movimientos(e.id) - fn_rrhh_vac_reservado(e.id, NULL, TRUE), 0),
           e.salario_base, e.periodo_pago::VARCHAR, t.valor_dia, t.extras_50sem, t.extras_dia, t.promedio_dia,
           round(GREATEST(fn_rrhh_vac_devengado(e.id, p_fecha) + fn_rrhh_vac_movimientos(e.id) - fn_rrhh_vac_reservado(e.id, NULL, TRUE), 0) * t.promedio_dia, 2),
           round(GREATEST(fn_rrhh_vac_devengado(e.id, p_fecha) + fn_rrhh_vac_movimientos(e.id) - fn_rrhh_vac_reservado(e.id, NULL, TRUE), 0) * t.valor_dia, 2)
      FROM rrhh_empleados e
      CROSS JOIN LATERAL fn_rrhh_vac_tarifa(p_empresa_id, e.id, p_fecha) t
     WHERE e.empresa_id = p_empresa_id AND e.deleted_at IS NULL AND e.estado <> 'liquidado' AND e.fecha_ingreso <= p_fecha
       AND (p_empleado_id IS NULL OR e.id = p_empleado_id)
     ORDER BY e.nombre, e.apellido1;
END; $$;


--
-- Name: sp_servicio_create(bigint, character varying, character varying, text, character varying, character varying, numeric, character varying, character varying, numeric, character varying, text, character varying, character varying, character varying, character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_servicio_create(p_empresa_id bigint, p_code character varying, p_name character varying, p_description text, p_unit_measure character varying, p_cabys_code character varying, p_price numeric, p_tax_type character varying, p_tax_code character varying, p_tax_rate numeric, p_tax_tarifa_codigo character varying, p_image_url text, p_image_public_id character varying, p_moneda character varying, p_codigo_barras character varying, p_partida_arancelaria character varying DEFAULT NULL::character varying, p_duracion_minutos integer DEFAULT NULL::integer) RETURNS TABLE(id bigint, code character varying, name character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
-- Name: sp_sucursal_contacto_get(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_sucursal_contacto_get(p_empresa_id bigint, p_sucursal_id bigint DEFAULT NULL::bigint) RETURNS TABLE(sucursal_id bigint, email character varying, phone character varying, province_code character varying, canton_code character varying, district_code character varying, other_signs text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT sc.sucursal_id, sc.email, sc.phone, sc.province_code, sc.canton_code, sc.district_code, sc.other_signs
    FROM sucursal_contacto sc
    WHERE sc.empresa_id = p_empresa_id
      AND (p_sucursal_id IS NULL OR sc.sucursal_id = p_sucursal_id)
    ORDER BY sc.sucursal_id
    LIMIT 1;
END; $$;


--
-- Name: sp_sucursal_contacto_list(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_sucursal_contacto_list(p_empresa_id bigint) RETURNS TABLE(sucursal_id bigint, email character varying, phone character varying, province_code character varying, canton_code character varying, district_code character varying, other_signs text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN QUERY
    SELECT sc.sucursal_id, sc.email, sc.phone, sc.province_code, sc.canton_code, sc.district_code, sc.other_signs
    FROM sucursal_contacto sc
    WHERE sc.empresa_id = p_empresa_id
    ORDER BY sc.sucursal_id;
END; $$;


--
-- Name: sp_sucursal_contacto_upsert(bigint, bigint, character varying, character varying, character varying, character varying, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_sucursal_contacto_upsert(p_empresa_id bigint, p_sucursal_id bigint, p_email character varying, p_phone character varying, p_province_code character varying, p_canton_code character varying, p_district_code character varying, p_other_signs text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    INSERT INTO sucursal_contacto (sucursal_id, empresa_id, email, phone, province_code, canton_code, district_code, other_signs)
    VALUES (p_sucursal_id, p_empresa_id, p_email, p_phone, p_province_code, p_canton_code, p_district_code, p_other_signs)
    ON CONFLICT (sucursal_id) DO UPDATE SET
        email         = EXCLUDED.email,
        phone         = EXCLUDED.phone,
        province_code = EXCLUDED.province_code,
        canton_code   = EXCLUDED.canton_code,
        district_code = EXCLUDED.district_code,
        other_signs   = EXCLUDED.other_signs,
        updated_at    = NOW()
    WHERE sucursal_contacto.empresa_id = EXCLUDED.empresa_id;
    RETURN TRUE;
END; $$;


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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
    SET search_path TO 'public', 'pg_temp'
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
-- Name: agenda_espacios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agenda_espacios (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    sucursal_id bigint,
    nombre character varying(100) NOT NULL,
    descripcion character varying(255),
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: agenda_espacios_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agenda_espacios_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'agenda_espacios'::character varying NOT NULL,
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
-- Name: agenda_espacios_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agenda_espacios_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agenda_espacios_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agenda_espacios_auditoria_id_seq OWNED BY public.agenda_espacios_auditoria.id;


--
-- Name: agenda_espacios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agenda_espacios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agenda_espacios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agenda_espacios_id_seq OWNED BY public.agenda_espacios.id;


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
    fecha_fin timestamp without time zone NOT NULL,
    estado character varying(20) DEFAULT 'pendiente'::character varying NOT NULL,
    documento_id bigint,
    motivo_cancelacion text,
    cancelado_at timestamp without time zone,
    cancelado_por bigint,
    cancelado_por_nombre character varying(150),
    espacio_id bigint,
    CONSTRAINT chk_agenda_linea_estado CHECK (((estado)::text = ANY ((ARRAY['pendiente'::character varying, 'facturado'::character varying, 'cancelado'::character varying])::text[])))
);


--
-- Name: agenda_evento_lineas_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agenda_evento_lineas_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'agenda_evento_lineas'::character varying NOT NULL,
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
-- Name: agenda_evento_lineas_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agenda_evento_lineas_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agenda_evento_lineas_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agenda_evento_lineas_auditoria_id_seq OWNED BY public.agenda_evento_lineas_auditoria.id;


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
    motivo_cancelacion text,
    cancelado_at timestamp without time zone,
    cancelado_por bigint,
    cancelado_por_nombre character varying(150),
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
    metodo character varying(10),
    endpoint character varying(500),
    request_headers jsonb,
    request_body jsonb,
    response_status integer,
    response_body jsonb,
    ip_address character varying(45),
    user_agent text,
    duracion_ms integer,
    created_at timestamp with time zone DEFAULT now()
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
-- Name: caja_cierres_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.caja_cierres_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'caja_cierres'::character varying NOT NULL,
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
-- Name: caja_cierres_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.caja_cierres_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: caja_cierres_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.caja_cierres_auditoria_id_seq OWNED BY public.caja_cierres_auditoria.id;


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
-- Name: cliente_exoneraciones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cliente_exoneraciones (
    id bigint NOT NULL,
    client_id bigint NOT NULL,
    tipo_documento character varying(2) NOT NULL,
    tipo_documento_otro character varying(100),
    numero_documento character varying(40) NOT NULL,
    articulo character varying(10),
    inciso character varying(5),
    nombre_institucion character varying(5) NOT NULL,
    nombre_institucion_otros character varying(100),
    fecha_emision date NOT NULL,
    fecha_vencimiento date,
    tarifa_exonerada numeric(6,2) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: cliente_exoneraciones_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cliente_exoneraciones_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'cliente_exoneraciones'::character varying NOT NULL,
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
-- Name: cliente_exoneraciones_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cliente_exoneraciones_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cliente_exoneraciones_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cliente_exoneraciones_auditoria_id_seq OWNED BY public.cliente_exoneraciones_auditoria.id;


--
-- Name: cliente_exoneraciones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cliente_exoneraciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cliente_exoneraciones_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cliente_exoneraciones_id_seq OWNED BY public.cliente_exoneraciones.id;


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
    CONSTRAINT clients_auditoria_operacion_check CHECK (((operacion)::text = ANY (ARRAY[('INSERT'::character varying)::text, ('UPDATE'::character varying)::text, ('DELETE'::character varying)::text])))
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
-- Name: cobro_facturas_externas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cobro_facturas_externas (
    referencia character varying(80) NOT NULL,
    documento_id bigint NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


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
    formato_impresion_factura character varying(10) DEFAULT 'carta'::character varying NOT NULL,
    formato_impresion_tiquete character varying(10) DEFAULT 'tiquete80'::character varying NOT NULL,
    CONSTRAINT company_settings_formato_impresion_chk CHECK ((((formato_impresion_factura)::text = ANY ((ARRAY['carta'::character varying, 'tiquete80'::character varying])::text[])) AND ((formato_impresion_tiquete)::text = ANY ((ARRAY['carta'::character varying, 'tiquete80'::character varying])::text[])))),
    CONSTRAINT company_settings_hacienda_environment_check CHECK (((hacienda_environment)::text = ANY (ARRAY[('stag'::character varying)::text, ('prod'::character varying)::text]))),
    CONSTRAINT company_settings_validation_status_check CHECK (((validation_status)::text = ANY (ARRAY[('pending'::character varying)::text, ('valid'::character varying)::text, ('invalid'::character varying)::text])))
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
    CONSTRAINT compras_items_tipo_check CHECK (((tipo)::text = ANY (ARRAY[('P'::character varying)::text, ('S'::character varying)::text])))
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
-- Name: cuentas_por_cobrar_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cuentas_por_cobrar_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cuentas_por_cobrar; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cuentas_por_cobrar (
    id bigint DEFAULT nextval('public.cuentas_por_cobrar_id_seq'::regclass) NOT NULL,
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
    CONSTRAINT chk_cxc_estado CHECK (((estado)::text = ANY (ARRAY[('vigente'::character varying)::text, ('mora'::character varying)::text, ('pagada'::character varying)::text, ('anulada'::character varying)::text]))),
    CONSTRAINT chk_cxc_origen_venta CHECK (((origen_venta)::text = ANY ((ARRAY['credito'::character varying, 'apartado'::character varying])::text[])))
);


--
-- Name: cuentas_por_cobrar_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cuentas_por_cobrar_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'cuentas_por_cobrar'::character varying NOT NULL,
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
-- Name: cuentas_por_cobrar_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cuentas_por_cobrar_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cuentas_por_cobrar_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cuentas_por_cobrar_auditoria_id_seq OWNED BY public.cuentas_por_cobrar_auditoria.id;


--
-- Name: db_version; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.db_version (
    id integer NOT NULL,
    version character varying(20) NOT NULL,
    description text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: db_version_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.db_version_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: db_version_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.db_version_id_seq OWNED BY public.db_version.id;


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
-- Name: documento_cxc_aplicaciones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_cxc_aplicaciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_cxc_aplicaciones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_cxc_aplicaciones (
    id bigint DEFAULT nextval('public.documento_cxc_aplicaciones_id_seq'::regclass) NOT NULL,
    documento_id bigint NOT NULL,
    cuenta_por_cobrar_id bigint NOT NULL,
    monto_aplicado numeric(18,5) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: documento_cxc_aplicaciones_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documento_cxc_aplicaciones_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'documento_cxc_aplicaciones'::character varying NOT NULL,
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
-- Name: documento_cxc_aplicaciones_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documento_cxc_aplicaciones_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documento_cxc_aplicaciones_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documento_cxc_aplicaciones_auditoria_id_seq OWNED BY public.documento_cxc_aplicaciones_auditoria.id;


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
    ex_tipo_documento_otro character varying(100),
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
-- Name: documentos_adjuntos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documentos_adjuntos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    entidad character varying(40) NOT NULL,
    entidad_id bigint NOT NULL,
    nombre character varying(200) NOT NULL,
    clave character varying(512) NOT NULL,
    tamano_bytes bigint NOT NULL,
    sha256 character(64) NOT NULL,
    created_by bigint,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: documentos_adjuntos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documentos_adjuntos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'documentos_adjuntos'::character varying NOT NULL,
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
-- Name: documentos_adjuntos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documentos_adjuntos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documentos_adjuntos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documentos_adjuntos_auditoria_id_seq OWNED BY public.documentos_adjuntos_auditoria.id;


--
-- Name: documentos_adjuntos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.documentos_adjuntos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: documentos_adjuntos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.documentos_adjuntos_id_seq OWNED BY public.documentos_adjuntos.id;


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
-- Name: empresa_hacienda_config_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_hacienda_config_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'empresa_hacienda_config'::character varying NOT NULL,
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
-- Name: empresa_hacienda_config_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_hacienda_config_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_hacienda_config_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_hacienda_config_auditoria_id_seq OWNED BY public.empresa_hacienda_config_auditoria.id;


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
-- Name: empresa_medios_pago_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_medios_pago_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'empresa_medios_pago'::character varying NOT NULL,
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
-- Name: empresa_medios_pago_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_medios_pago_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_medios_pago_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_medios_pago_auditoria_id_seq OWNED BY public.empresa_medios_pago_auditoria.id;


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
-- Name: empresa_monedas_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_monedas_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'empresa_monedas'::character varying NOT NULL,
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
-- Name: empresa_monedas_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_monedas_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_monedas_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_monedas_auditoria_id_seq OWNED BY public.empresa_monedas_auditoria.id;


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
-- Name: empresa_perfil_fiscal; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_perfil_fiscal (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    regimen character varying(20) DEFAULT 'general'::character varying NOT NULL,
    tipo_actividad character varying(25) DEFAULT 'productos_servicios'::character varying NOT NULL,
    cargado_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT empresa_perfil_fiscal_regimen_check CHECK (((regimen)::text = ANY ((ARRAY['simplificado'::character varying, 'general'::character varying, 'agropecuario'::character varying])::text[]))),
    CONSTRAINT empresa_perfil_fiscal_tipo_actividad_check CHECK (((tipo_actividad)::text = ANY ((ARRAY['salud'::character varying, 'productos'::character varying, 'servicios'::character varying, 'productos_servicios'::character varying])::text[])))
);


--
-- Name: empresa_perfil_fiscal_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_perfil_fiscal_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'empresa_perfil_fiscal'::character varying NOT NULL,
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
-- Name: empresa_perfil_fiscal_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_perfil_fiscal_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_perfil_fiscal_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_perfil_fiscal_auditoria_id_seq OWNED BY public.empresa_perfil_fiscal_auditoria.id;


--
-- Name: empresa_perfil_fiscal_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_perfil_fiscal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_perfil_fiscal_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_perfil_fiscal_id_seq OWNED BY public.empresa_perfil_fiscal.id;


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
-- Name: empresa_tarifas_impuesto_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_tarifas_impuesto_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'empresa_tarifas_impuesto'::character varying NOT NULL,
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
-- Name: empresa_tarifas_impuesto_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_tarifas_impuesto_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_tarifas_impuesto_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_tarifas_impuesto_auditoria_id_seq OWNED BY public.empresa_tarifas_impuesto_auditoria.id;


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
    compra numeric(12,4),
    venta numeric(12,4),
    fuente character varying(100) DEFAULT 'Manual'::character varying,
    created_by bigint,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
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
-- Name: empresa_tipos_descuento_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_tipos_descuento_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'empresa_tipos_descuento'::character varying NOT NULL,
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
-- Name: empresa_tipos_descuento_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_tipos_descuento_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_tipos_descuento_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_tipos_descuento_auditoria_id_seq OWNED BY public.empresa_tipos_descuento_auditoria.id;


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
-- Name: empresa_tipos_impuesto_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.empresa_tipos_impuesto_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'empresa_tipos_impuesto'::character varying NOT NULL,
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
-- Name: empresa_tipos_impuesto_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.empresa_tipos_impuesto_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: empresa_tipos_impuesto_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.empresa_tipos_impuesto_auditoria_id_seq OWNED BY public.empresa_tipos_impuesto_auditoria.id;


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
-- Name: facturas_recibidas_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.facturas_recibidas_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'facturas_recibidas'::character varying NOT NULL,
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
-- Name: facturas_recibidas_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.facturas_recibidas_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: facturas_recibidas_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.facturas_recibidas_auditoria_id_seq OWNED BY public.facturas_recibidas_auditoria.id;


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
-- Name: funcionario_sucursales_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.funcionario_sucursales_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'funcionario_sucursales'::character varying NOT NULL,
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
-- Name: funcionario_sucursales_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.funcionario_sucursales_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: funcionario_sucursales_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.funcionario_sucursales_auditoria_id_seq OWNED BY public.funcionario_sucursales_auditoria.id;


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
-- Name: mercadeo_campanas_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mercadeo_campanas_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'mercadeo_campanas'::character varying NOT NULL,
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
-- Name: mercadeo_campanas_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mercadeo_campanas_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mercadeo_campanas_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mercadeo_campanas_auditoria_id_seq OWNED BY public.mercadeo_campanas_auditoria.id;


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
-- Name: mercadeo_imagenes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mercadeo_imagenes (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    nombre character varying(150) NOT NULL,
    clave character varying(512) NOT NULL,
    mime character varying(20) NOT NULL,
    ancho integer NOT NULL,
    alto integer NOT NULL,
    tamano_bytes bigint NOT NULL,
    created_by bigint,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_mercadeo_imagenes_mime CHECK (((mime)::text = ANY ((ARRAY['image/jpeg'::character varying, 'image/png'::character varying])::text[])))
);


--
-- Name: mercadeo_imagenes_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mercadeo_imagenes_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'mercadeo_imagenes'::character varying NOT NULL,
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
-- Name: mercadeo_imagenes_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mercadeo_imagenes_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mercadeo_imagenes_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mercadeo_imagenes_auditoria_id_seq OWNED BY public.mercadeo_imagenes_auditoria.id;


--
-- Name: mercadeo_imagenes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mercadeo_imagenes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mercadeo_imagenes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mercadeo_imagenes_id_seq OWNED BY public.mercadeo_imagenes.id;


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
-- Name: mercadeo_plantillas_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mercadeo_plantillas_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'mercadeo_plantillas'::character varying NOT NULL,
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
-- Name: mercadeo_plantillas_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mercadeo_plantillas_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mercadeo_plantillas_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mercadeo_plantillas_auditoria_id_seq OWNED BY public.mercadeo_plantillas_auditoria.id;


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
-- Name: movimientos_inventario_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.movimientos_inventario_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: movimientos_inventario; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.movimientos_inventario (
    id bigint DEFAULT nextval('public.movimientos_inventario_id_seq'::regclass) NOT NULL,
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
-- Name: producto_proveedor_equivalencias_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.producto_proveedor_equivalencias_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'producto_proveedor_equivalencias'::character varying NOT NULL,
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
-- Name: producto_proveedor_equivalencias_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.producto_proveedor_equivalencias_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: producto_proveedor_equivalencias_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.producto_proveedor_equivalencias_auditoria_id_seq OWNED BY public.producto_proveedor_equivalencias_auditoria.id;


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
    CONSTRAINT productos_type_check CHECK (((type)::text = ANY (ARRAY[('product'::character varying)::text, ('service'::character varying)::text])))
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
-- Name: recibos_adelanto_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.recibos_adelanto_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recibos_adelanto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recibos_adelanto (
    id bigint DEFAULT nextval('public.recibos_adelanto_id_seq'::regclass) NOT NULL,
    empresa_id bigint NOT NULL,
    documento_id bigint NOT NULL,
    cliente_id bigint NOT NULL,
    monto_original numeric(18,5) NOT NULL,
    saldo_disponible numeric(18,5) NOT NULL,
    estado character varying(20) DEFAULT 'disponible'::character varying NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    moneda character varying(3) DEFAULT 'CRC'::character varying NOT NULL,
    CONSTRAINT chk_adelanto_estado CHECK (((estado)::text = ANY (ARRAY[('disponible'::character varying)::text, ('agotado'::character varying)::text, ('anulado'::character varying)::text])))
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
-- Name: recibos_adelanto_aplicaciones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recibos_adelanto_aplicaciones (
    id bigint DEFAULT nextval('public.recibos_adelanto_aplicaciones_id_seq'::regclass) NOT NULL,
    recibo_adelanto_id bigint NOT NULL,
    documento_id bigint NOT NULL,
    monto_aplicado numeric(18,5) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: recibos_adelanto_aplicaciones_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recibos_adelanto_aplicaciones_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'recibos_adelanto_aplicaciones'::character varying NOT NULL,
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
-- Name: recibos_adelanto_aplicaciones_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.recibos_adelanto_aplicaciones_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recibos_adelanto_aplicaciones_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.recibos_adelanto_aplicaciones_auditoria_id_seq OWNED BY public.recibos_adelanto_aplicaciones_auditoria.id;


--
-- Name: recibos_adelanto_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recibos_adelanto_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'recibos_adelanto'::character varying NOT NULL,
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
-- Name: recibos_adelanto_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.recibos_adelanto_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: recibos_adelanto_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.recibos_adelanto_auditoria_id_seq OWNED BY public.recibos_adelanto_auditoria.id;


--
-- Name: rrhh_agentes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_agentes (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    nombre character varying(100) NOT NULL,
    sucursal_id bigint,
    token_hash character(64),
    token_prefijo character varying(8),
    version character varying(20),
    ultimo_contacto timestamp without time zone,
    ultima_ip character varying(45),
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: rrhh_agentes_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_agentes_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_agentes'::character varying NOT NULL,
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
-- Name: rrhh_agentes_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_agentes_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_agentes_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_agentes_auditoria_id_seq OWNED BY public.rrhh_agentes_auditoria.id;


--
-- Name: rrhh_agentes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_agentes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_agentes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_agentes_id_seq OWNED BY public.rrhh_agentes.id;


--
-- Name: rrhh_asistencia_ajustes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_asistencia_ajustes (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    empleado_id bigint NOT NULL,
    fecha date NOT NULL,
    tipo character varying(15) NOT NULL,
    aprobado boolean,
    minutos integer,
    motivo character varying(255),
    usuario_id bigint,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_asistencia_ajustes_minutos_check CHECK ((minutos >= 0)),
    CONSTRAINT rrhh_asistencia_ajustes_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['justificacion'::character varying, 'extra'::character varying])::text[])))
);


--
-- Name: rrhh_asistencia_ajustes_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_asistencia_ajustes_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_asistencia_ajustes'::character varying NOT NULL,
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
-- Name: rrhh_asistencia_ajustes_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_asistencia_ajustes_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_asistencia_ajustes_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_asistencia_ajustes_auditoria_id_seq OWNED BY public.rrhh_asistencia_ajustes_auditoria.id;


--
-- Name: rrhh_asistencia_ajustes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_asistencia_ajustes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_asistencia_ajustes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_asistencia_ajustes_id_seq OWNED BY public.rrhh_asistencia_ajustes.id;


--
-- Name: rrhh_cargas_sociales; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_cargas_sociales (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    anio integer NOT NULL,
    rubro character varying(60) NOT NULL,
    parte character varying(10) NOT NULL,
    porcentaje numeric(6,3) NOT NULL,
    orden integer DEFAULT 0 NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_cargas_sociales_parte_check CHECK (((parte)::text = ANY ((ARRAY['obrero'::character varying, 'patronal'::character varying])::text[]))),
    CONSTRAINT rrhh_cargas_sociales_porcentaje_check CHECK (((porcentaje >= (0)::numeric) AND (porcentaje <= (100)::numeric)))
);


--
-- Name: rrhh_cargas_sociales_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_cargas_sociales_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_cargas_sociales'::character varying NOT NULL,
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
-- Name: rrhh_cargas_sociales_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_cargas_sociales_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_cargas_sociales_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_cargas_sociales_auditoria_id_seq OWNED BY public.rrhh_cargas_sociales_auditoria.id;


--
-- Name: rrhh_cargas_sociales_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_cargas_sociales_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_cargas_sociales_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_cargas_sociales_id_seq OWNED BY public.rrhh_cargas_sociales.id;


--
-- Name: rrhh_conceptos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_conceptos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    codigo character varying(20) NOT NULL,
    nombre character varying(80) NOT NULL,
    tipo character varying(10) NOT NULL,
    afecta_ccss boolean DEFAULT false NOT NULL,
    afecta_renta boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_conceptos_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['ingreso'::character varying, 'deduccion'::character varying])::text[])))
);


--
-- Name: rrhh_conceptos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_conceptos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_conceptos'::character varying NOT NULL,
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
-- Name: rrhh_conceptos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_conceptos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_conceptos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_conceptos_auditoria_id_seq OWNED BY public.rrhh_conceptos_auditoria.id;


--
-- Name: rrhh_conceptos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_conceptos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_conceptos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_conceptos_id_seq OWNED BY public.rrhh_conceptos.id;


--
-- Name: rrhh_departamentos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_departamentos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    codigo character varying(20),
    nombre character varying(100) NOT NULL,
    descripcion character varying(255),
    departamento_padre_id bigint,
    jefe_empleado_id bigint,
    centro_costo character varying(30),
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: rrhh_departamentos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_departamentos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_departamentos'::character varying NOT NULL,
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
-- Name: rrhh_departamentos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_departamentos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_departamentos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_departamentos_auditoria_id_seq OWNED BY public.rrhh_departamentos_auditoria.id;


--
-- Name: rrhh_departamentos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_departamentos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_departamentos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_departamentos_id_seq OWNED BY public.rrhh_departamentos.id;


--
-- Name: rrhh_dispositivo_usuarios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_dispositivo_usuarios (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    dispositivo_id bigint NOT NULL,
    empleado_id bigint NOT NULL,
    id_en_dispositivo character varying(30) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: rrhh_dispositivo_usuarios_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_dispositivo_usuarios_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_dispositivo_usuarios'::character varying NOT NULL,
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
-- Name: rrhh_dispositivo_usuarios_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_dispositivo_usuarios_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_dispositivo_usuarios_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_dispositivo_usuarios_auditoria_id_seq OWNED BY public.rrhh_dispositivo_usuarios_auditoria.id;


--
-- Name: rrhh_dispositivo_usuarios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_dispositivo_usuarios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_dispositivo_usuarios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_dispositivo_usuarios_id_seq OWNED BY public.rrhh_dispositivo_usuarios.id;


--
-- Name: rrhh_dispositivos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_dispositivos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    nombre character varying(100) NOT NULL,
    tipo_lector character varying(15) DEFAULT 'huella'::character varying NOT NULL,
    marca character varying(15) DEFAULT 'otro'::character varying NOT NULL,
    modelo character varying(60),
    numero_serie character varying(60),
    ubicacion character varying(120),
    sucursal_id bigint,
    agente_id bigint,
    ultima_sincronizacion timestamp without time zone,
    ultima_marca timestamp without time zone,
    estado_conexion character varying(10) DEFAULT 'sin_datos'::character varying NOT NULL,
    ultimo_error character varying(255),
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_dispositivos_estado_conexion_check CHECK (((estado_conexion)::text = ANY ((ARRAY['sin_datos'::character varying, 'en_linea'::character varying, 'error'::character varying])::text[]))),
    CONSTRAINT rrhh_dispositivos_marca_check CHECK (((marca)::text = ANY ((ARRAY['zkteco'::character varying, 'hikvision'::character varying, 'dahua'::character varying, 'suprema'::character varying, 'anviz'::character varying, 'otro'::character varying, 'simulado'::character varying])::text[]))),
    CONSTRAINT rrhh_dispositivos_tipo_lector_check CHECK (((tipo_lector)::text = ANY ((ARRAY['huella'::character varying, 'facial'::character varying, 'huella_facial'::character varying, 'tarjeta'::character varying, 'pin'::character varying])::text[])))
);


--
-- Name: rrhh_dispositivos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_dispositivos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_dispositivos'::character varying NOT NULL,
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
-- Name: rrhh_dispositivos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_dispositivos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_dispositivos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_dispositivos_auditoria_id_seq OWNED BY public.rrhh_dispositivos_auditoria.id;


--
-- Name: rrhh_dispositivos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_dispositivos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_dispositivos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_dispositivos_id_seq OWNED BY public.rrhh_dispositivos.id;


--
-- Name: rrhh_empleado_conceptos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_empleado_conceptos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    empleado_id bigint NOT NULL,
    concepto_id bigint NOT NULL,
    monto numeric(14,2) NOT NULL,
    desde date NOT NULL,
    hasta date,
    nota character varying(255),
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_empleado_conceptos_check CHECK (((hasta IS NULL) OR (hasta >= desde))),
    CONSTRAINT rrhh_empleado_conceptos_monto_check CHECK ((monto > (0)::numeric))
);


--
-- Name: rrhh_empleado_conceptos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_empleado_conceptos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_empleado_conceptos'::character varying NOT NULL,
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
-- Name: rrhh_empleado_conceptos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_empleado_conceptos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_empleado_conceptos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_empleado_conceptos_auditoria_id_seq OWNED BY public.rrhh_empleado_conceptos_auditoria.id;


--
-- Name: rrhh_empleado_conceptos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_empleado_conceptos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_empleado_conceptos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_empleado_conceptos_id_seq OWNED BY public.rrhh_empleado_conceptos.id;


--
-- Name: rrhh_empleado_horarios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_empleado_horarios (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    empleado_id bigint NOT NULL,
    horario_id bigint NOT NULL,
    vigente_desde date NOT NULL,
    vigente_hasta date,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_empleado_horarios_check CHECK (((vigente_hasta IS NULL) OR (vigente_hasta >= vigente_desde)))
);


--
-- Name: rrhh_empleado_horarios_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_empleado_horarios_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_empleado_horarios'::character varying NOT NULL,
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
-- Name: rrhh_empleado_horarios_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_empleado_horarios_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_empleado_horarios_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_empleado_horarios_auditoria_id_seq OWNED BY public.rrhh_empleado_horarios_auditoria.id;


--
-- Name: rrhh_empleado_horarios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_empleado_horarios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_empleado_horarios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_empleado_horarios_id_seq OWNED BY public.rrhh_empleado_horarios.id;


--
-- Name: rrhh_empleado_movimientos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_empleado_movimientos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    empleado_id bigint NOT NULL,
    tipo character varying(25) NOT NULL,
    fecha date DEFAULT CURRENT_DATE NOT NULL,
    descripcion text NOT NULL,
    valor_anterior jsonb,
    valor_nuevo jsonb,
    usuario_id bigint,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: rrhh_empleado_movimientos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_empleado_movimientos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_empleado_movimientos'::character varying NOT NULL,
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
-- Name: rrhh_empleado_movimientos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_empleado_movimientos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_empleado_movimientos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_empleado_movimientos_auditoria_id_seq OWNED BY public.rrhh_empleado_movimientos_auditoria.id;


--
-- Name: rrhh_empleado_movimientos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_empleado_movimientos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_empleado_movimientos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_empleado_movimientos_id_seq OWNED BY public.rrhh_empleado_movimientos.id;


--
-- Name: rrhh_empleado_pin; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_empleado_pin (
    empleado_id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    pin_hash character varying(100) NOT NULL,
    intentos smallint DEFAULT 0 NOT NULL,
    bloqueado_hasta timestamp without time zone,
    cambiado_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: rrhh_empleados; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_empleados (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    funcionario_id bigint,
    codigo character varying(20) NOT NULL,
    tipo_identificacion character varying(10) DEFAULT 'cedula'::character varying NOT NULL,
    identificacion character varying(30) NOT NULL,
    nombre character varying(100) NOT NULL,
    apellido1 character varying(60) NOT NULL,
    apellido2 character varying(60),
    fecha_nacimiento date,
    sexo character varying(1),
    estado_civil character varying(15),
    nacionalidad character varying(60) DEFAULT 'Costarricense'::character varying NOT NULL,
    email character varying(150),
    telefono character varying(30),
    direccion text,
    tiene_conyuge boolean DEFAULT false NOT NULL,
    cantidad_hijos smallint DEFAULT 0 NOT NULL,
    contacto_emergencia_nombre character varying(120),
    contacto_emergencia_telefono character varying(30),
    contacto_emergencia_parentesco character varying(40),
    departamento_id bigint,
    puesto_id bigint,
    jefe_id bigint,
    sucursal_id bigint,
    fecha_ingreso date NOT NULL,
    fecha_salida date,
    motivo_salida character varying(40),
    tipo_contrato character varying(20) DEFAULT 'indefinido'::character varying NOT NULL,
    fecha_fin_contrato date,
    jornada character varying(15) DEFAULT 'diurna'::character varying NOT NULL,
    horas_semanales numeric(5,2) DEFAULT 48 NOT NULL,
    periodo_pago character varying(10) DEFAULT 'mensual'::character varying NOT NULL,
    salario_base numeric(14,2) DEFAULT 0 NOT NULL,
    moneda character varying(3) DEFAULT 'CRC'::character varying NOT NULL,
    banco character varying(60),
    iban character varying(34),
    numero_ccss character varying(30),
    estado character varying(12) DEFAULT 'activo'::character varying NOT NULL,
    notas text,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_empleados_cantidad_hijos_check CHECK ((cantidad_hijos >= 0)),
    CONSTRAINT rrhh_empleados_estado_check CHECK (((estado)::text = ANY ((ARRAY['activo'::character varying, 'suspendido'::character varying, 'liquidado'::character varying])::text[]))),
    CONSTRAINT rrhh_empleados_estado_civil_check CHECK (((estado_civil)::text = ANY ((ARRAY['soltero'::character varying, 'casado'::character varying, 'union_libre'::character varying, 'divorciado'::character varying, 'viudo'::character varying])::text[]))),
    CONSTRAINT rrhh_empleados_horas_semanales_check CHECK (((horas_semanales > (0)::numeric) AND (horas_semanales <= (60)::numeric))),
    CONSTRAINT rrhh_empleados_jornada_check CHECK (((jornada)::text = ANY ((ARRAY['diurna'::character varying, 'mixta'::character varying, 'nocturna'::character varying, 'acumulativa'::character varying])::text[]))),
    CONSTRAINT rrhh_empleados_periodo_pago_check CHECK (((periodo_pago)::text = ANY ((ARRAY['mensual'::character varying, 'quincenal'::character varying, 'semanal'::character varying])::text[]))),
    CONSTRAINT rrhh_empleados_salario_base_check CHECK ((salario_base >= (0)::numeric)),
    CONSTRAINT rrhh_empleados_sexo_check CHECK (((sexo)::text = ANY ((ARRAY['F'::character varying, 'M'::character varying, 'O'::character varying])::text[]))),
    CONSTRAINT rrhh_empleados_tipo_contrato_check CHECK (((tipo_contrato)::text = ANY ((ARRAY['indefinido'::character varying, 'plazo_fijo'::character varying, 'obra_determinada'::character varying])::text[]))),
    CONSTRAINT rrhh_empleados_tipo_identificacion_check CHECK (((tipo_identificacion)::text = ANY ((ARRAY['cedula'::character varying, 'dimex'::character varying, 'nite'::character varying, 'pasaporte'::character varying])::text[])))
);


--
-- Name: rrhh_empleados_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_empleados_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_empleados'::character varying NOT NULL,
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
-- Name: rrhh_empleados_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_empleados_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_empleados_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_empleados_auditoria_id_seq OWNED BY public.rrhh_empleados_auditoria.id;


--
-- Name: rrhh_empleados_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_empleados_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_empleados_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_empleados_id_seq OWNED BY public.rrhh_empleados.id;


--
-- Name: rrhh_feriados; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_feriados (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    fecha date NOT NULL,
    nombre character varying(100) NOT NULL,
    pago_obligatorio boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: rrhh_feriados_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_feriados_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_feriados'::character varying NOT NULL,
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
-- Name: rrhh_feriados_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_feriados_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_feriados_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_feriados_auditoria_id_seq OWNED BY public.rrhh_feriados_auditoria.id;


--
-- Name: rrhh_feriados_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_feriados_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_feriados_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_feriados_id_seq OWNED BY public.rrhh_feriados.id;


--
-- Name: rrhh_horario_dias; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_horario_dias (
    horario_id bigint NOT NULL,
    dia_semana smallint NOT NULL,
    hora_entrada time without time zone NOT NULL,
    hora_salida time without time zone NOT NULL,
    minutos_descanso smallint DEFAULT 0 NOT NULL,
    CONSTRAINT rrhh_horario_dias_dia_semana_check CHECK (((dia_semana >= 1) AND (dia_semana <= 7))),
    CONSTRAINT rrhh_horario_dias_minutos_descanso_check CHECK (((minutos_descanso >= 0) AND (minutos_descanso <= 240)))
);


--
-- Name: rrhh_horarios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_horarios (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    nombre character varying(100) NOT NULL,
    descripcion character varying(255),
    jornada character varying(15) DEFAULT 'diurna'::character varying NOT NULL,
    tolerancia_entrada_min smallint DEFAULT 10 NOT NULL,
    tolerancia_salida_min smallint DEFAULT 0 NOT NULL,
    minutos_minimos_extra smallint DEFAULT 30 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_horarios_jornada_check CHECK (((jornada)::text = ANY ((ARRAY['diurna'::character varying, 'mixta'::character varying, 'nocturna'::character varying, 'acumulativa'::character varying])::text[]))),
    CONSTRAINT rrhh_horarios_minutos_minimos_extra_check CHECK (((minutos_minimos_extra >= 0) AND (minutos_minimos_extra <= 240))),
    CONSTRAINT rrhh_horarios_tolerancia_entrada_min_check CHECK (((tolerancia_entrada_min >= 0) AND (tolerancia_entrada_min <= 120))),
    CONSTRAINT rrhh_horarios_tolerancia_salida_min_check CHECK (((tolerancia_salida_min >= 0) AND (tolerancia_salida_min <= 120)))
);


--
-- Name: rrhh_horarios_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_horarios_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_horarios'::character varying NOT NULL,
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
-- Name: rrhh_horarios_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_horarios_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_horarios_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_horarios_auditoria_id_seq OWNED BY public.rrhh_horarios_auditoria.id;


--
-- Name: rrhh_horarios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_horarios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_horarios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_horarios_id_seq OWNED BY public.rrhh_horarios.id;


--
-- Name: rrhh_incapacidades; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_incapacidades (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    empleado_id bigint NOT NULL,
    tipo character varying(15) NOT NULL,
    entidad character varying(4) NOT NULL,
    fecha_inicio date NOT NULL,
    fecha_fin date NOT NULL,
    dias integer NOT NULL,
    numero_boleta character varying(40),
    observaciones character varying(255),
    patrono_completa boolean DEFAULT true NOT NULL,
    valor_dia numeric(14,2) NOT NULL,
    estado character varying(10) DEFAULT 'registrada'::character varying NOT NULL,
    vac_repuestos numeric(6,2) DEFAULT 0 NOT NULL,
    vac_movimiento_id bigint,
    anulada_por bigint,
    anulada_at timestamp without time zone,
    anulada_nota character varying(255),
    creada_por bigint,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_incapacidades_check CHECK ((fecha_fin >= fecha_inicio)),
    CONSTRAINT rrhh_incapacidades_dias_check CHECK ((dias > 0)),
    CONSTRAINT rrhh_incapacidades_entidad_check CHECK (((entidad)::text = ANY ((ARRAY['CCSS'::character varying, 'INS'::character varying])::text[]))),
    CONSTRAINT rrhh_incapacidades_estado_check CHECK (((estado)::text = ANY ((ARRAY['registrada'::character varying, 'anulada'::character varying])::text[]))),
    CONSTRAINT rrhh_incapacidades_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['enfermedad'::character varying, 'maternidad'::character varying, 'riesgo_trabajo'::character varying])::text[])))
);


--
-- Name: rrhh_incapacidades_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_incapacidades_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_incapacidades'::character varying NOT NULL,
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
-- Name: rrhh_incapacidades_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_incapacidades_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_incapacidades_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_incapacidades_auditoria_id_seq OWNED BY public.rrhh_incapacidades_auditoria.id;


--
-- Name: rrhh_incapacidades_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_incapacidades_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_incapacidades_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_incapacidades_id_seq OWNED BY public.rrhh_incapacidades.id;


--
-- Name: rrhh_marcas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_marcas (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    empleado_id bigint,
    fecha_hora timestamp without time zone NOT NULL,
    origen character varying(12) NOT NULL,
    metodo character varying(10) DEFAULT 'pin'::character varying NOT NULL,
    dispositivo_id bigint,
    agente_id bigint,
    id_externo character varying(30),
    referencia_externa character varying(80),
    estado character varying(12) DEFAULT 'valida'::character varying NOT NULL,
    motivo character varying(255),
    ip character varying(45),
    registrado_por bigint,
    resuelto_por bigint,
    resuelto_at timestamp without time zone,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_marcas_estado_check CHECK (((estado)::text = ANY ((ARRAY['valida'::character varying, 'pendiente'::character varying, 'rechazada'::character varying, 'sin_asignar'::character varying])::text[]))),
    CONSTRAINT rrhh_marcas_metodo_check CHECK (((metodo)::text = ANY ((ARRAY['pin'::character varying, 'huella'::character varying, 'facial'::character varying, 'tarjeta'::character varying, 'manual'::character varying, 'otro'::character varying])::text[]))),
    CONSTRAINT rrhh_marcas_origen_check CHECK (((origen)::text = ANY ((ARRAY['web'::character varying, 'dispositivo'::character varying, 'manual'::character varying])::text[])))
);


--
-- Name: rrhh_marcas_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_marcas_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_marcas'::character varying NOT NULL,
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
-- Name: rrhh_marcas_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_marcas_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_marcas_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_marcas_auditoria_id_seq OWNED BY public.rrhh_marcas_auditoria.id;


--
-- Name: rrhh_marcas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_marcas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_marcas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_marcas_id_seq OWNED BY public.rrhh_marcas.id;


--
-- Name: rrhh_permiso_solicitudes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_permiso_solicitudes (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    empleado_id bigint NOT NULL,
    tipo_id bigint NOT NULL,
    fecha_inicio date NOT NULL,
    fecha_fin date NOT NULL,
    hora_inicio time without time zone,
    hora_fin time without time zone,
    cantidad numeric(6,2) NOT NULL,
    unidad character varying(5) NOT NULL,
    con_goce boolean NOT NULL,
    estado character varying(15) DEFAULT 'pendiente_jefe'::character varying NOT NULL,
    jefe_id bigint,
    motivo character varying(255),
    jefe_resuelto_por bigint,
    jefe_resuelto_at timestamp without time zone,
    jefe_nota character varying(255),
    rrhh_resuelto_por bigint,
    rrhh_resuelto_at timestamp without time zone,
    rrhh_nota character varying(255),
    creada_por bigint,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_permiso_solicitudes_cantidad_check CHECK ((cantidad > (0)::numeric)),
    CONSTRAINT rrhh_permiso_solicitudes_check CHECK ((fecha_fin >= fecha_inicio)),
    CONSTRAINT rrhh_permiso_solicitudes_check1 CHECK (((((unidad)::text = 'horas'::text) AND (hora_inicio IS NOT NULL) AND (hora_fin IS NOT NULL) AND (hora_fin > hora_inicio) AND (fecha_inicio = fecha_fin)) OR (((unidad)::text = 'dias'::text) AND (hora_inicio IS NULL) AND (hora_fin IS NULL)))),
    CONSTRAINT rrhh_permiso_solicitudes_estado_check CHECK (((estado)::text = ANY ((ARRAY['pendiente_jefe'::character varying, 'pendiente_rrhh'::character varying, 'aprobada'::character varying, 'rechazada'::character varying, 'cancelada'::character varying])::text[]))),
    CONSTRAINT rrhh_permiso_solicitudes_unidad_check CHECK (((unidad)::text = ANY ((ARRAY['dias'::character varying, 'horas'::character varying])::text[])))
);


--
-- Name: rrhh_permiso_solicitudes_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_permiso_solicitudes_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_permiso_solicitudes'::character varying NOT NULL,
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
-- Name: rrhh_permiso_solicitudes_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_permiso_solicitudes_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_permiso_solicitudes_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_permiso_solicitudes_auditoria_id_seq OWNED BY public.rrhh_permiso_solicitudes_auditoria.id;


--
-- Name: rrhh_permiso_solicitudes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_permiso_solicitudes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_permiso_solicitudes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_permiso_solicitudes_id_seq OWNED BY public.rrhh_permiso_solicitudes.id;


--
-- Name: rrhh_permiso_tipos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_permiso_tipos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    nombre character varying(80) NOT NULL,
    unidad character varying(5) DEFAULT 'dias'::character varying NOT NULL,
    con_goce boolean DEFAULT true NOT NULL,
    max_por_solicitud numeric(6,2),
    max_por_anio numeric(6,2),
    descripcion character varying(255),
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_permiso_tipos_max_por_anio_check CHECK (((max_por_anio IS NULL) OR (max_por_anio > (0)::numeric))),
    CONSTRAINT rrhh_permiso_tipos_max_por_solicitud_check CHECK (((max_por_solicitud IS NULL) OR (max_por_solicitud > (0)::numeric))),
    CONSTRAINT rrhh_permiso_tipos_unidad_check CHECK (((unidad)::text = ANY ((ARRAY['dias'::character varying, 'horas'::character varying])::text[])))
);


--
-- Name: rrhh_permiso_tipos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_permiso_tipos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_permiso_tipos'::character varying NOT NULL,
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
-- Name: rrhh_permiso_tipos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_permiso_tipos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_permiso_tipos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_permiso_tipos_auditoria_id_seq OWNED BY public.rrhh_permiso_tipos_auditoria.id;


--
-- Name: rrhh_permiso_tipos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_permiso_tipos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_permiso_tipos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_permiso_tipos_id_seq OWNED BY public.rrhh_permiso_tipos.id;


--
-- Name: rrhh_planilla_empleados; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_planilla_empleados (
    id bigint NOT NULL,
    planilla_id bigint NOT NULL,
    empleado_id bigint NOT NULL,
    codigo character varying(20) NOT NULL,
    nombre character varying(260) NOT NULL,
    tipo_identificacion character varying(10) NOT NULL,
    identificacion character varying(30) NOT NULL,
    departamento character varying(100),
    puesto character varying(100),
    banco character varying(60),
    iban character varying(34),
    numero_ccss character varying(30),
    dias_vinculo integer DEFAULT 0 NOT NULL,
    dias_ausente integer DEFAULT 0 NOT NULL,
    minutos_tardanza integer DEFAULT 0 NOT NULL,
    dias_permiso_sg numeric(6,2) DEFAULT 0 NOT NULL,
    dias_incapacidad integer DEFAULT 0 NOT NULL,
    minutos_extra integer DEFAULT 0 NOT NULL,
    salario_base numeric(14,2) DEFAULT 0 NOT NULL,
    salario_periodo numeric(14,2) DEFAULT 0 NOT NULL,
    desc_ausencias numeric(14,2) DEFAULT 0 NOT NULL,
    desc_tardanzas numeric(14,2) DEFAULT 0 NOT NULL,
    desc_permisos numeric(14,2) DEFAULT 0 NOT NULL,
    desc_incapacidad numeric(14,2) DEFAULT 0 NOT NULL,
    pago_incapacidad numeric(14,2) DEFAULT 0 NOT NULL,
    horas_extra numeric(14,2) DEFAULT 0 NOT NULL,
    vac_extras numeric(14,2) DEFAULT 0 NOT NULL,
    otros_ingresos numeric(14,2) DEFAULT 0 NOT NULL,
    devengado numeric(14,2) DEFAULT 0 NOT NULL,
    base_ccss numeric(14,2) DEFAULT 0 NOT NULL,
    ccss_obrero numeric(14,2) DEFAULT 0 NOT NULL,
    base_renta numeric(14,2) DEFAULT 0 NOT NULL,
    renta numeric(14,2) DEFAULT 0 NOT NULL,
    otras_deducciones numeric(14,2) DEFAULT 0 NOT NULL,
    neto numeric(14,2) DEFAULT 0 NOT NULL,
    ccss_patronal numeric(14,2) DEFAULT 0 NOT NULL,
    advertencias jsonb DEFAULT '[]'::jsonb NOT NULL
);


--
-- Name: rrhh_planilla_empleados_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_planilla_empleados_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_planilla_empleados_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_planilla_empleados_id_seq OWNED BY public.rrhh_planilla_empleados.id;


--
-- Name: rrhh_planilla_lineas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_planilla_lineas (
    id bigint NOT NULL,
    planilla_id bigint NOT NULL,
    empleado_id bigint NOT NULL,
    concepto_id bigint,
    codigo character varying(20),
    descripcion character varying(120) NOT NULL,
    tipo character varying(10) NOT NULL,
    monto numeric(14,2) NOT NULL,
    origen character varying(10) NOT NULL,
    afecta_ccss boolean DEFAULT false NOT NULL,
    afecta_renta boolean DEFAULT false NOT NULL,
    creada_por bigint,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_planilla_lineas_monto_check CHECK ((monto > (0)::numeric)),
    CONSTRAINT rrhh_planilla_lineas_origen_check CHECK (((origen)::text = ANY ((ARRAY['recurrente'::character varying, 'manual'::character varying])::text[]))),
    CONSTRAINT rrhh_planilla_lineas_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['ingreso'::character varying, 'deduccion'::character varying])::text[])))
);


--
-- Name: rrhh_planilla_lineas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_planilla_lineas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_planilla_lineas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_planilla_lineas_id_seq OWNED BY public.rrhh_planilla_lineas.id;


--
-- Name: rrhh_planillas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_planillas (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    nombre character varying(100) NOT NULL,
    periodicidad character varying(10) NOT NULL,
    fecha_inicio date NOT NULL,
    fecha_fin date NOT NULL,
    fecha_pago date NOT NULL,
    moneda character varying(3) DEFAULT 'CRC'::character varying NOT NULL,
    descontar_tardanzas boolean DEFAULT true NOT NULL,
    estado character varying(10) DEFAULT 'borrador'::character varying NOT NULL,
    notas character varying(255),
    tasas_validadas boolean DEFAULT false NOT NULL,
    total_empleados integer DEFAULT 0 NOT NULL,
    total_devengado numeric(16,2) DEFAULT 0 NOT NULL,
    total_ccss_obrero numeric(16,2) DEFAULT 0 NOT NULL,
    total_renta numeric(16,2) DEFAULT 0 NOT NULL,
    total_otras_ded numeric(16,2) DEFAULT 0 NOT NULL,
    total_neto numeric(16,2) DEFAULT 0 NOT NULL,
    total_ccss_patronal numeric(16,2) DEFAULT 0 NOT NULL,
    calculada_at timestamp without time zone,
    aprobada_por bigint,
    aprobada_at timestamp without time zone,
    pagada_por bigint,
    pagada_at timestamp without time zone,
    anulada_por bigint,
    anulada_at timestamp without time zone,
    anulada_nota character varying(255),
    creada_por bigint,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_planillas_check CHECK (((fecha_fin >= fecha_inicio) AND ((fecha_fin - fecha_inicio) <= 31))),
    CONSTRAINT rrhh_planillas_estado_check CHECK (((estado)::text = ANY ((ARRAY['borrador'::character varying, 'calculada'::character varying, 'aprobada'::character varying, 'pagada'::character varying, 'anulada'::character varying])::text[]))),
    CONSTRAINT rrhh_planillas_periodicidad_check CHECK (((periodicidad)::text = ANY ((ARRAY['mensual'::character varying, 'quincenal'::character varying, 'semanal'::character varying])::text[])))
);


--
-- Name: rrhh_planillas_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_planillas_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_planillas'::character varying NOT NULL,
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
-- Name: rrhh_planillas_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_planillas_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_planillas_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_planillas_auditoria_id_seq OWNED BY public.rrhh_planillas_auditoria.id;


--
-- Name: rrhh_planillas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_planillas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_planillas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_planillas_id_seq OWNED BY public.rrhh_planillas.id;


--
-- Name: rrhh_puestos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_puestos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    nombre character varying(100) NOT NULL,
    descripcion character varying(255),
    departamento_id bigint,
    categoria character varying(20),
    salario_minimo numeric(14,2),
    salario_maximo numeric(14,2),
    is_active boolean DEFAULT true NOT NULL,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_puestos_categoria_check CHECK (((categoria)::text = ANY ((ARRAY['no_calificado'::character varying, 'semicalificado'::character varying, 'calificado'::character varying, 'especializado'::character varying])::text[]))),
    CONSTRAINT rrhh_puestos_check CHECK (((salario_maximo IS NULL) OR (salario_minimo IS NULL) OR (salario_maximo >= salario_minimo))),
    CONSTRAINT rrhh_puestos_salario_maximo_check CHECK ((salario_maximo >= (0)::numeric)),
    CONSTRAINT rrhh_puestos_salario_minimo_check CHECK ((salario_minimo >= (0)::numeric))
);


--
-- Name: rrhh_puestos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_puestos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_puestos'::character varying NOT NULL,
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
-- Name: rrhh_puestos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_puestos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_puestos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_puestos_auditoria_id_seq OWNED BY public.rrhh_puestos_auditoria.id;


--
-- Name: rrhh_puestos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_puestos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_puestos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_puestos_id_seq OWNED BY public.rrhh_puestos.id;


--
-- Name: rrhh_renta_tramos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_renta_tramos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    anio integer NOT NULL,
    orden integer NOT NULL,
    desde numeric(14,2) NOT NULL,
    hasta numeric(14,2),
    porcentaje numeric(6,3) NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_renta_tramos_check CHECK (((hasta IS NULL) OR (hasta > desde))),
    CONSTRAINT rrhh_renta_tramos_desde_check CHECK ((desde >= (0)::numeric)),
    CONSTRAINT rrhh_renta_tramos_porcentaje_check CHECK (((porcentaje >= (0)::numeric) AND (porcentaje <= (100)::numeric)))
);


--
-- Name: rrhh_renta_tramos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_renta_tramos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_renta_tramos'::character varying NOT NULL,
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
-- Name: rrhh_renta_tramos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_renta_tramos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_renta_tramos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_renta_tramos_auditoria_id_seq OWNED BY public.rrhh_renta_tramos_auditoria.id;


--
-- Name: rrhh_renta_tramos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_renta_tramos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_renta_tramos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_renta_tramos_id_seq OWNED BY public.rrhh_renta_tramos.id;


--
-- Name: rrhh_tasas_anio; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_tasas_anio (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    anio integer NOT NULL,
    credito_hijo numeric(14,2) DEFAULT 0 NOT NULL,
    credito_conyuge numeric(14,2) DEFAULT 0 NOT NULL,
    fuente character varying(255),
    validado boolean DEFAULT false NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_tasas_anio_anio_check CHECK (((anio >= 2000) AND (anio <= 2100)))
);


--
-- Name: rrhh_tasas_anio_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_tasas_anio_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_tasas_anio'::character varying NOT NULL,
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
-- Name: rrhh_tasas_anio_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_tasas_anio_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_tasas_anio_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_tasas_anio_auditoria_id_seq OWNED BY public.rrhh_tasas_anio_auditoria.id;


--
-- Name: rrhh_tasas_anio_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_tasas_anio_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_tasas_anio_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_tasas_anio_id_seq OWNED BY public.rrhh_tasas_anio.id;


--
-- Name: rrhh_vacaciones_movimientos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_vacaciones_movimientos (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    empleado_id bigint NOT NULL,
    tipo character varying(15) NOT NULL,
    dias numeric(6,2) NOT NULL,
    fecha date DEFAULT CURRENT_DATE NOT NULL,
    motivo character varying(255),
    usuario_id bigint,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_vacaciones_movimientos_dias_check CHECK ((dias <> (0)::numeric)),
    CONSTRAINT rrhh_vacaciones_movimientos_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['saldo_inicial'::character varying, 'ajuste'::character varying])::text[])))
);


--
-- Name: rrhh_vacaciones_movimientos_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_vacaciones_movimientos_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_vacaciones_movimientos'::character varying NOT NULL,
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
-- Name: rrhh_vacaciones_movimientos_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_vacaciones_movimientos_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_vacaciones_movimientos_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_vacaciones_movimientos_auditoria_id_seq OWNED BY public.rrhh_vacaciones_movimientos_auditoria.id;


--
-- Name: rrhh_vacaciones_movimientos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_vacaciones_movimientos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_vacaciones_movimientos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_vacaciones_movimientos_id_seq OWNED BY public.rrhh_vacaciones_movimientos.id;


--
-- Name: rrhh_vacaciones_solicitudes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_vacaciones_solicitudes (
    id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    empleado_id bigint NOT NULL,
    fecha_inicio date NOT NULL,
    fecha_fin date NOT NULL,
    dias integer NOT NULL,
    estado character varying(15) DEFAULT 'pendiente_jefe'::character varying NOT NULL,
    jefe_id bigint,
    motivo character varying(255),
    jefe_resuelto_por bigint,
    jefe_resuelto_at timestamp without time zone,
    jefe_nota character varying(255),
    rrhh_resuelto_por bigint,
    rrhh_resuelto_at timestamp without time zone,
    rrhh_nota character varying(255),
    creada_por bigint,
    deleted_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT rrhh_vacaciones_solicitudes_check CHECK ((fecha_fin >= fecha_inicio)),
    CONSTRAINT rrhh_vacaciones_solicitudes_dias_check CHECK ((dias > 0)),
    CONSTRAINT rrhh_vacaciones_solicitudes_estado_check CHECK (((estado)::text = ANY ((ARRAY['pendiente_jefe'::character varying, 'pendiente_rrhh'::character varying, 'aprobada'::character varying, 'rechazada'::character varying, 'cancelada'::character varying])::text[])))
);


--
-- Name: rrhh_vacaciones_solicitudes_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rrhh_vacaciones_solicitudes_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'rrhh_vacaciones_solicitudes'::character varying NOT NULL,
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
-- Name: rrhh_vacaciones_solicitudes_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_vacaciones_solicitudes_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_vacaciones_solicitudes_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_vacaciones_solicitudes_auditoria_id_seq OWNED BY public.rrhh_vacaciones_solicitudes_auditoria.id;


--
-- Name: rrhh_vacaciones_solicitudes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rrhh_vacaciones_solicitudes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rrhh_vacaciones_solicitudes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rrhh_vacaciones_solicitudes_id_seq OWNED BY public.rrhh_vacaciones_solicitudes.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    id integer NOT NULL,
    version character varying(20) NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL
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
-- Name: sistema_parametros; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sistema_parametros (
    id bigint NOT NULL,
    clave character varying(80) NOT NULL,
    valor character varying(255) NOT NULL,
    descripcion text,
    updated_by bigint,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: sistema_parametros_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sistema_parametros_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'sistema_parametros'::character varying NOT NULL,
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
-- Name: sistema_parametros_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sistema_parametros_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sistema_parametros_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sistema_parametros_auditoria_id_seq OWNED BY public.sistema_parametros_auditoria.id;


--
-- Name: sistema_parametros_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sistema_parametros_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sistema_parametros_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sistema_parametros_id_seq OWNED BY public.sistema_parametros.id;


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
-- Name: sucursal_bodegas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sucursal_bodegas (
    id bigint DEFAULT nextval('public.sucursal_bodegas_id_seq'::regclass) NOT NULL,
    sucursal_id bigint NOT NULL,
    bodega_id bigint NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: sucursal_bodegas_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sucursal_bodegas_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'sucursal_bodegas'::character varying NOT NULL,
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
-- Name: sucursal_bodegas_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sucursal_bodegas_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sucursal_bodegas_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sucursal_bodegas_auditoria_id_seq OWNED BY public.sucursal_bodegas_auditoria.id;


--
-- Name: sucursal_contacto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sucursal_contacto (
    id bigint NOT NULL,
    sucursal_id bigint NOT NULL,
    empresa_id bigint NOT NULL,
    email character varying(255),
    phone character varying(30),
    province_code character varying(1),
    canton_code character varying(2),
    district_code character varying(2),
    other_signs text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: sucursal_contacto_auditoria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sucursal_contacto_auditoria (
    id bigint NOT NULL,
    tabla character varying(50) DEFAULT 'sucursal_contacto'::character varying NOT NULL,
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
-- Name: sucursal_contacto_auditoria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sucursal_contacto_auditoria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sucursal_contacto_auditoria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sucursal_contacto_auditoria_id_seq OWNED BY public.sucursal_contacto_auditoria.id;


--
-- Name: sucursal_contacto_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sucursal_contacto_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sucursal_contacto_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sucursal_contacto_id_seq OWNED BY public.sucursal_contacto.id;


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
-- Name: agenda_espacios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_espacios ALTER COLUMN id SET DEFAULT nextval('public.agenda_espacios_id_seq'::regclass);


--
-- Name: agenda_espacios_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_espacios_auditoria ALTER COLUMN id SET DEFAULT nextval('public.agenda_espacios_auditoria_id_seq'::regclass);


--
-- Name: agenda_evento_linea_productos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_evento_linea_productos ALTER COLUMN id SET DEFAULT nextval('public.agenda_evento_linea_productos_id_seq'::regclass);


--
-- Name: agenda_evento_lineas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_evento_lineas ALTER COLUMN id SET DEFAULT nextval('public.agenda_evento_lineas_id_seq'::regclass);


--
-- Name: agenda_evento_lineas_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_evento_lineas_auditoria ALTER COLUMN id SET DEFAULT nextval('public.agenda_evento_lineas_auditoria_id_seq'::regclass);


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
-- Name: caja_cierres_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caja_cierres_auditoria ALTER COLUMN id SET DEFAULT nextval('public.caja_cierres_auditoria_id_seq'::regclass);


--
-- Name: categorias_producto id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorias_producto ALTER COLUMN id SET DEFAULT nextval('public.categorias_producto_id_seq'::regclass);


--
-- Name: categorias_producto_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categorias_producto_auditoria ALTER COLUMN id SET DEFAULT nextval('public.categorias_producto_auditoria_id_seq'::regclass);


--
-- Name: cliente_exoneraciones id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cliente_exoneraciones ALTER COLUMN id SET DEFAULT nextval('public.cliente_exoneraciones_id_seq'::regclass);


--
-- Name: cliente_exoneraciones_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cliente_exoneraciones_auditoria ALTER COLUMN id SET DEFAULT nextval('public.cliente_exoneraciones_auditoria_id_seq'::regclass);


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
-- Name: cuentas_por_cobrar_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cuentas_por_cobrar_auditoria ALTER COLUMN id SET DEFAULT nextval('public.cuentas_por_cobrar_auditoria_id_seq'::regclass);


--
-- Name: db_version id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.db_version ALTER COLUMN id SET DEFAULT nextval('public.db_version_id_seq'::regclass);


--
-- Name: documento_consecutivos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_consecutivos ALTER COLUMN id SET DEFAULT nextval('public.documento_consecutivos_id_seq'::regclass);


--
-- Name: documento_cxc_aplicaciones_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_cxc_aplicaciones_auditoria ALTER COLUMN id SET DEFAULT nextval('public.documento_cxc_aplicaciones_auditoria_id_seq'::regclass);


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
-- Name: documentos_adjuntos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documentos_adjuntos ALTER COLUMN id SET DEFAULT nextval('public.documentos_adjuntos_id_seq'::regclass);


--
-- Name: documentos_adjuntos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documentos_adjuntos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.documentos_adjuntos_auditoria_id_seq'::regclass);


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
-- Name: empresa_hacienda_config_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_hacienda_config_auditoria ALTER COLUMN id SET DEFAULT nextval('public.empresa_hacienda_config_auditoria_id_seq'::regclass);


--
-- Name: empresa_hacienda_config_bitacora id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_hacienda_config_bitacora ALTER COLUMN id SET DEFAULT nextval('public.empresa_hacienda_config_bitacora_id_seq'::regclass);


--
-- Name: empresa_medios_pago id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_medios_pago ALTER COLUMN id SET DEFAULT nextval('public.empresa_medios_pago_id_seq'::regclass);


--
-- Name: empresa_medios_pago_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_medios_pago_auditoria ALTER COLUMN id SET DEFAULT nextval('public.empresa_medios_pago_auditoria_id_seq'::regclass);


--
-- Name: empresa_monedas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_monedas ALTER COLUMN id SET DEFAULT nextval('public.empresa_monedas_id_seq'::regclass);


--
-- Name: empresa_monedas_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_monedas_auditoria ALTER COLUMN id SET DEFAULT nextval('public.empresa_monedas_auditoria_id_seq'::regclass);


--
-- Name: empresa_perfil_fiscal id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_perfil_fiscal ALTER COLUMN id SET DEFAULT nextval('public.empresa_perfil_fiscal_id_seq'::regclass);


--
-- Name: empresa_perfil_fiscal_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_perfil_fiscal_auditoria ALTER COLUMN id SET DEFAULT nextval('public.empresa_perfil_fiscal_auditoria_id_seq'::regclass);


--
-- Name: empresa_tarifas_impuesto id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tarifas_impuesto ALTER COLUMN id SET DEFAULT nextval('public.empresa_tarifas_impuesto_id_seq'::regclass);


--
-- Name: empresa_tarifas_impuesto_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tarifas_impuesto_auditoria ALTER COLUMN id SET DEFAULT nextval('public.empresa_tarifas_impuesto_auditoria_id_seq'::regclass);


--
-- Name: empresa_tipo_cambios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipo_cambios ALTER COLUMN id SET DEFAULT nextval('public.empresa_tipo_cambios_id_seq'::regclass);


--
-- Name: empresa_tipos_descuento id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_descuento ALTER COLUMN id SET DEFAULT nextval('public.empresa_tipos_descuento_id_seq'::regclass);


--
-- Name: empresa_tipos_descuento_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_descuento_auditoria ALTER COLUMN id SET DEFAULT nextval('public.empresa_tipos_descuento_auditoria_id_seq'::regclass);


--
-- Name: empresa_tipos_impuesto id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_impuesto ALTER COLUMN id SET DEFAULT nextval('public.empresa_tipos_impuesto_id_seq'::regclass);


--
-- Name: empresa_tipos_impuesto_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_impuesto_auditoria ALTER COLUMN id SET DEFAULT nextval('public.empresa_tipos_impuesto_auditoria_id_seq'::regclass);


--
-- Name: facturas_recibidas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facturas_recibidas ALTER COLUMN id SET DEFAULT nextval('public.facturas_recibidas_id_seq'::regclass);


--
-- Name: facturas_recibidas_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facturas_recibidas_auditoria ALTER COLUMN id SET DEFAULT nextval('public.facturas_recibidas_auditoria_id_seq'::regclass);


--
-- Name: funcionario_sucursales id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionario_sucursales ALTER COLUMN id SET DEFAULT nextval('public.funcionario_sucursales_id_seq'::regclass);


--
-- Name: funcionario_sucursales_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionario_sucursales_auditoria ALTER COLUMN id SET DEFAULT nextval('public.funcionario_sucursales_auditoria_id_seq'::regclass);


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
-- Name: mercadeo_campanas_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_campanas_auditoria ALTER COLUMN id SET DEFAULT nextval('public.mercadeo_campanas_auditoria_id_seq'::regclass);


--
-- Name: mercadeo_imagenes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_imagenes ALTER COLUMN id SET DEFAULT nextval('public.mercadeo_imagenes_id_seq'::regclass);


--
-- Name: mercadeo_imagenes_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_imagenes_auditoria ALTER COLUMN id SET DEFAULT nextval('public.mercadeo_imagenes_auditoria_id_seq'::regclass);


--
-- Name: mercadeo_plantillas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_plantillas ALTER COLUMN id SET DEFAULT nextval('public.mercadeo_plantillas_id_seq'::regclass);


--
-- Name: mercadeo_plantillas_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_plantillas_auditoria ALTER COLUMN id SET DEFAULT nextval('public.mercadeo_plantillas_auditoria_id_seq'::regclass);


--
-- Name: migrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.migrations ALTER COLUMN id SET DEFAULT nextval('public.migrations_id_seq'::regclass);


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
-- Name: producto_proveedor_equivalencias_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.producto_proveedor_equivalencias_auditoria ALTER COLUMN id SET DEFAULT nextval('public.producto_proveedor_equivalencias_auditoria_id_seq'::regclass);


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
-- Name: recibos_adelanto_aplicaciones_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto_aplicaciones_auditoria ALTER COLUMN id SET DEFAULT nextval('public.recibos_adelanto_aplicaciones_auditoria_id_seq'::regclass);


--
-- Name: recibos_adelanto_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto_auditoria ALTER COLUMN id SET DEFAULT nextval('public.recibos_adelanto_auditoria_id_seq'::regclass);


--
-- Name: rrhh_agentes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_agentes ALTER COLUMN id SET DEFAULT nextval('public.rrhh_agentes_id_seq'::regclass);


--
-- Name: rrhh_agentes_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_agentes_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_agentes_auditoria_id_seq'::regclass);


--
-- Name: rrhh_asistencia_ajustes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_asistencia_ajustes ALTER COLUMN id SET DEFAULT nextval('public.rrhh_asistencia_ajustes_id_seq'::regclass);


--
-- Name: rrhh_asistencia_ajustes_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_asistencia_ajustes_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_asistencia_ajustes_auditoria_id_seq'::regclass);


--
-- Name: rrhh_cargas_sociales id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_cargas_sociales ALTER COLUMN id SET DEFAULT nextval('public.rrhh_cargas_sociales_id_seq'::regclass);


--
-- Name: rrhh_cargas_sociales_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_cargas_sociales_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_cargas_sociales_auditoria_id_seq'::regclass);


--
-- Name: rrhh_conceptos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_conceptos ALTER COLUMN id SET DEFAULT nextval('public.rrhh_conceptos_id_seq'::regclass);


--
-- Name: rrhh_conceptos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_conceptos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_conceptos_auditoria_id_seq'::regclass);


--
-- Name: rrhh_departamentos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_departamentos ALTER COLUMN id SET DEFAULT nextval('public.rrhh_departamentos_id_seq'::regclass);


--
-- Name: rrhh_departamentos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_departamentos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_departamentos_auditoria_id_seq'::regclass);


--
-- Name: rrhh_dispositivo_usuarios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivo_usuarios ALTER COLUMN id SET DEFAULT nextval('public.rrhh_dispositivo_usuarios_id_seq'::regclass);


--
-- Name: rrhh_dispositivo_usuarios_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivo_usuarios_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_dispositivo_usuarios_auditoria_id_seq'::regclass);


--
-- Name: rrhh_dispositivos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivos ALTER COLUMN id SET DEFAULT nextval('public.rrhh_dispositivos_id_seq'::regclass);


--
-- Name: rrhh_dispositivos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_dispositivos_auditoria_id_seq'::regclass);


--
-- Name: rrhh_empleado_conceptos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_conceptos ALTER COLUMN id SET DEFAULT nextval('public.rrhh_empleado_conceptos_id_seq'::regclass);


--
-- Name: rrhh_empleado_conceptos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_conceptos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_empleado_conceptos_auditoria_id_seq'::regclass);


--
-- Name: rrhh_empleado_horarios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_horarios ALTER COLUMN id SET DEFAULT nextval('public.rrhh_empleado_horarios_id_seq'::regclass);


--
-- Name: rrhh_empleado_horarios_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_horarios_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_empleado_horarios_auditoria_id_seq'::regclass);


--
-- Name: rrhh_empleado_movimientos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_movimientos ALTER COLUMN id SET DEFAULT nextval('public.rrhh_empleado_movimientos_id_seq'::regclass);


--
-- Name: rrhh_empleado_movimientos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_movimientos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_empleado_movimientos_auditoria_id_seq'::regclass);


--
-- Name: rrhh_empleados id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleados ALTER COLUMN id SET DEFAULT nextval('public.rrhh_empleados_id_seq'::regclass);


--
-- Name: rrhh_empleados_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleados_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_empleados_auditoria_id_seq'::regclass);


--
-- Name: rrhh_feriados id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_feriados ALTER COLUMN id SET DEFAULT nextval('public.rrhh_feriados_id_seq'::regclass);


--
-- Name: rrhh_feriados_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_feriados_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_feriados_auditoria_id_seq'::regclass);


--
-- Name: rrhh_horarios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horarios ALTER COLUMN id SET DEFAULT nextval('public.rrhh_horarios_id_seq'::regclass);


--
-- Name: rrhh_horarios_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horarios_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_horarios_auditoria_id_seq'::regclass);


--
-- Name: rrhh_incapacidades id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_incapacidades ALTER COLUMN id SET DEFAULT nextval('public.rrhh_incapacidades_id_seq'::regclass);


--
-- Name: rrhh_incapacidades_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_incapacidades_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_incapacidades_auditoria_id_seq'::regclass);


--
-- Name: rrhh_marcas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_marcas ALTER COLUMN id SET DEFAULT nextval('public.rrhh_marcas_id_seq'::regclass);


--
-- Name: rrhh_marcas_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_marcas_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_marcas_auditoria_id_seq'::regclass);


--
-- Name: rrhh_permiso_solicitudes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_permiso_solicitudes ALTER COLUMN id SET DEFAULT nextval('public.rrhh_permiso_solicitudes_id_seq'::regclass);


--
-- Name: rrhh_permiso_solicitudes_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_permiso_solicitudes_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_permiso_solicitudes_auditoria_id_seq'::regclass);


--
-- Name: rrhh_permiso_tipos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_permiso_tipos ALTER COLUMN id SET DEFAULT nextval('public.rrhh_permiso_tipos_id_seq'::regclass);


--
-- Name: rrhh_permiso_tipos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_permiso_tipos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_permiso_tipos_auditoria_id_seq'::regclass);


--
-- Name: rrhh_planilla_empleados id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla_empleados ALTER COLUMN id SET DEFAULT nextval('public.rrhh_planilla_empleados_id_seq'::regclass);


--
-- Name: rrhh_planilla_lineas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla_lineas ALTER COLUMN id SET DEFAULT nextval('public.rrhh_planilla_lineas_id_seq'::regclass);


--
-- Name: rrhh_planillas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planillas ALTER COLUMN id SET DEFAULT nextval('public.rrhh_planillas_id_seq'::regclass);


--
-- Name: rrhh_planillas_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planillas_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_planillas_auditoria_id_seq'::regclass);


--
-- Name: rrhh_puestos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_puestos ALTER COLUMN id SET DEFAULT nextval('public.rrhh_puestos_id_seq'::regclass);


--
-- Name: rrhh_puestos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_puestos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_puestos_auditoria_id_seq'::regclass);


--
-- Name: rrhh_renta_tramos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_renta_tramos ALTER COLUMN id SET DEFAULT nextval('public.rrhh_renta_tramos_id_seq'::regclass);


--
-- Name: rrhh_renta_tramos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_renta_tramos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_renta_tramos_auditoria_id_seq'::regclass);


--
-- Name: rrhh_tasas_anio id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_tasas_anio ALTER COLUMN id SET DEFAULT nextval('public.rrhh_tasas_anio_id_seq'::regclass);


--
-- Name: rrhh_tasas_anio_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_tasas_anio_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_tasas_anio_auditoria_id_seq'::regclass);


--
-- Name: rrhh_vacaciones_movimientos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_vacaciones_movimientos ALTER COLUMN id SET DEFAULT nextval('public.rrhh_vacaciones_movimientos_id_seq'::regclass);


--
-- Name: rrhh_vacaciones_movimientos_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_vacaciones_movimientos_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_vacaciones_movimientos_auditoria_id_seq'::regclass);


--
-- Name: rrhh_vacaciones_solicitudes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_vacaciones_solicitudes ALTER COLUMN id SET DEFAULT nextval('public.rrhh_vacaciones_solicitudes_id_seq'::regclass);


--
-- Name: rrhh_vacaciones_solicitudes_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_vacaciones_solicitudes_auditoria ALTER COLUMN id SET DEFAULT nextval('public.rrhh_vacaciones_solicitudes_auditoria_id_seq'::regclass);


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
-- Name: sistema_parametros id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sistema_parametros ALTER COLUMN id SET DEFAULT nextval('public.sistema_parametros_id_seq'::regclass);


--
-- Name: sistema_parametros_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sistema_parametros_auditoria ALTER COLUMN id SET DEFAULT nextval('public.sistema_parametros_auditoria_id_seq'::regclass);


--
-- Name: sucursal_bodegas_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_bodegas_auditoria ALTER COLUMN id SET DEFAULT nextval('public.sucursal_bodegas_auditoria_id_seq'::regclass);


--
-- Name: sucursal_contacto id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_contacto ALTER COLUMN id SET DEFAULT nextval('public.sucursal_contacto_id_seq'::regclass);


--
-- Name: sucursal_contacto_auditoria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_contacto_auditoria ALTER COLUMN id SET DEFAULT nextval('public.sucursal_contacto_auditoria_id_seq'::regclass);


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
-- Name: agenda_espacios_auditoria agenda_espacios_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_espacios_auditoria
    ADD CONSTRAINT agenda_espacios_auditoria_pkey PRIMARY KEY (id);


--
-- Name: agenda_espacios agenda_espacios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_espacios
    ADD CONSTRAINT agenda_espacios_pkey PRIMARY KEY (id);


--
-- Name: agenda_evento_linea_productos agenda_evento_linea_productos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_evento_linea_productos
    ADD CONSTRAINT agenda_evento_linea_productos_pkey PRIMARY KEY (id);


--
-- Name: agenda_evento_lineas_auditoria agenda_evento_lineas_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_evento_lineas_auditoria
    ADD CONSTRAINT agenda_evento_lineas_auditoria_pkey PRIMARY KEY (id);


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
-- Name: caja_cierres_auditoria caja_cierres_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.caja_cierres_auditoria
    ADD CONSTRAINT caja_cierres_auditoria_pkey PRIMARY KEY (id);


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
-- Name: cliente_exoneraciones_auditoria cliente_exoneraciones_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cliente_exoneraciones_auditoria
    ADD CONSTRAINT cliente_exoneraciones_auditoria_pkey PRIMARY KEY (id);


--
-- Name: cliente_exoneraciones cliente_exoneraciones_client_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cliente_exoneraciones
    ADD CONSTRAINT cliente_exoneraciones_client_id_key UNIQUE (client_id);


--
-- Name: cliente_exoneraciones cliente_exoneraciones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cliente_exoneraciones
    ADD CONSTRAINT cliente_exoneraciones_pkey PRIMARY KEY (id);


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
-- Name: cobro_facturas_externas cobro_facturas_externas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cobro_facturas_externas
    ADD CONSTRAINT cobro_facturas_externas_pkey PRIMARY KEY (referencia);


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
-- Name: cuentas_por_cobrar_auditoria cuentas_por_cobrar_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cuentas_por_cobrar_auditoria
    ADD CONSTRAINT cuentas_por_cobrar_auditoria_pkey PRIMARY KEY (id);


--
-- Name: cuentas_por_cobrar cuentas_por_cobrar_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cuentas_por_cobrar
    ADD CONSTRAINT cuentas_por_cobrar_pkey PRIMARY KEY (id);


--
-- Name: db_version db_version_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.db_version
    ADD CONSTRAINT db_version_pkey PRIMARY KEY (id);


--
-- Name: documento_consecutivos documento_consecutivos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_consecutivos
    ADD CONSTRAINT documento_consecutivos_pkey PRIMARY KEY (id);


--
-- Name: documento_cxc_aplicaciones_auditoria documento_cxc_aplicaciones_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documento_cxc_aplicaciones_auditoria
    ADD CONSTRAINT documento_cxc_aplicaciones_auditoria_pkey PRIMARY KEY (id);


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
-- Name: documentos_adjuntos_auditoria documentos_adjuntos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documentos_adjuntos_auditoria
    ADD CONSTRAINT documentos_adjuntos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: documentos_adjuntos documentos_adjuntos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documentos_adjuntos
    ADD CONSTRAINT documentos_adjuntos_pkey PRIMARY KEY (id);


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
-- Name: empresa_hacienda_config_auditoria empresa_hacienda_config_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_hacienda_config_auditoria
    ADD CONSTRAINT empresa_hacienda_config_auditoria_pkey PRIMARY KEY (id);


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
-- Name: empresa_medios_pago_auditoria empresa_medios_pago_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_medios_pago_auditoria
    ADD CONSTRAINT empresa_medios_pago_auditoria_pkey PRIMARY KEY (id);


--
-- Name: empresa_medios_pago empresa_medios_pago_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_medios_pago
    ADD CONSTRAINT empresa_medios_pago_pkey PRIMARY KEY (id);


--
-- Name: empresa_monedas_auditoria empresa_monedas_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_monedas_auditoria
    ADD CONSTRAINT empresa_monedas_auditoria_pkey PRIMARY KEY (id);


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
-- Name: empresa_perfil_fiscal_auditoria empresa_perfil_fiscal_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_perfil_fiscal_auditoria
    ADD CONSTRAINT empresa_perfil_fiscal_auditoria_pkey PRIMARY KEY (id);


--
-- Name: empresa_perfil_fiscal empresa_perfil_fiscal_empresa_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_perfil_fiscal
    ADD CONSTRAINT empresa_perfil_fiscal_empresa_id_key UNIQUE (empresa_id);


--
-- Name: empresa_perfil_fiscal empresa_perfil_fiscal_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_perfil_fiscal
    ADD CONSTRAINT empresa_perfil_fiscal_pkey PRIMARY KEY (id);


--
-- Name: empresa_tarifas_impuesto_auditoria empresa_tarifas_impuesto_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tarifas_impuesto_auditoria
    ADD CONSTRAINT empresa_tarifas_impuesto_auditoria_pkey PRIMARY KEY (id);


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
-- Name: empresa_tipos_descuento_auditoria empresa_tipos_descuento_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_descuento_auditoria
    ADD CONSTRAINT empresa_tipos_descuento_auditoria_pkey PRIMARY KEY (id);


--
-- Name: empresa_tipos_descuento empresa_tipos_descuento_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_descuento
    ADD CONSTRAINT empresa_tipos_descuento_pkey PRIMARY KEY (id);


--
-- Name: empresa_tipos_impuesto_auditoria empresa_tipos_impuesto_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_impuesto_auditoria
    ADD CONSTRAINT empresa_tipos_impuesto_auditoria_pkey PRIMARY KEY (id);


--
-- Name: empresa_tipos_impuesto empresa_tipos_impuesto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.empresa_tipos_impuesto
    ADD CONSTRAINT empresa_tipos_impuesto_pkey PRIMARY KEY (id);


--
-- Name: facturas_recibidas_auditoria facturas_recibidas_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facturas_recibidas_auditoria
    ADD CONSTRAINT facturas_recibidas_auditoria_pkey PRIMARY KEY (id);


--
-- Name: facturas_recibidas facturas_recibidas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facturas_recibidas
    ADD CONSTRAINT facturas_recibidas_pkey PRIMARY KEY (id);


--
-- Name: funcionario_sucursales_auditoria funcionario_sucursales_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.funcionario_sucursales_auditoria
    ADD CONSTRAINT funcionario_sucursales_auditoria_pkey PRIMARY KEY (id);


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
-- Name: mercadeo_campanas_auditoria mercadeo_campanas_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_campanas_auditoria
    ADD CONSTRAINT mercadeo_campanas_auditoria_pkey PRIMARY KEY (id);


--
-- Name: mercadeo_campanas mercadeo_campanas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_campanas
    ADD CONSTRAINT mercadeo_campanas_pkey PRIMARY KEY (id);


--
-- Name: mercadeo_imagenes_auditoria mercadeo_imagenes_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_imagenes_auditoria
    ADD CONSTRAINT mercadeo_imagenes_auditoria_pkey PRIMARY KEY (id);


--
-- Name: mercadeo_imagenes mercadeo_imagenes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_imagenes
    ADD CONSTRAINT mercadeo_imagenes_pkey PRIMARY KEY (id);


--
-- Name: mercadeo_plantillas_auditoria mercadeo_plantillas_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_plantillas_auditoria
    ADD CONSTRAINT mercadeo_plantillas_auditoria_pkey PRIMARY KEY (id);


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
-- Name: producto_proveedor_equivalencias_auditoria producto_proveedor_equivalencias_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.producto_proveedor_equivalencias_auditoria
    ADD CONSTRAINT producto_proveedor_equivalencias_auditoria_pkey PRIMARY KEY (id);


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
-- Name: recibos_adelanto_aplicaciones_auditoria recibos_adelanto_aplicaciones_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto_aplicaciones_auditoria
    ADD CONSTRAINT recibos_adelanto_aplicaciones_auditoria_pkey PRIMARY KEY (id);


--
-- Name: recibos_adelanto_aplicaciones recibos_adelanto_aplicaciones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto_aplicaciones
    ADD CONSTRAINT recibos_adelanto_aplicaciones_pkey PRIMARY KEY (id);


--
-- Name: recibos_adelanto_auditoria recibos_adelanto_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto_auditoria
    ADD CONSTRAINT recibos_adelanto_auditoria_pkey PRIMARY KEY (id);


--
-- Name: recibos_adelanto recibos_adelanto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recibos_adelanto
    ADD CONSTRAINT recibos_adelanto_pkey PRIMARY KEY (id);


--
-- Name: rrhh_agentes_auditoria rrhh_agentes_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_agentes_auditoria
    ADD CONSTRAINT rrhh_agentes_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_agentes rrhh_agentes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_agentes
    ADD CONSTRAINT rrhh_agentes_pkey PRIMARY KEY (id);


--
-- Name: rrhh_asistencia_ajustes_auditoria rrhh_asistencia_ajustes_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_asistencia_ajustes_auditoria
    ADD CONSTRAINT rrhh_asistencia_ajustes_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_asistencia_ajustes rrhh_asistencia_ajustes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_asistencia_ajustes
    ADD CONSTRAINT rrhh_asistencia_ajustes_pkey PRIMARY KEY (id);


--
-- Name: rrhh_cargas_sociales_auditoria rrhh_cargas_sociales_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_cargas_sociales_auditoria
    ADD CONSTRAINT rrhh_cargas_sociales_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_cargas_sociales rrhh_cargas_sociales_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_cargas_sociales
    ADD CONSTRAINT rrhh_cargas_sociales_pkey PRIMARY KEY (id);


--
-- Name: rrhh_conceptos_auditoria rrhh_conceptos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_conceptos_auditoria
    ADD CONSTRAINT rrhh_conceptos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_conceptos rrhh_conceptos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_conceptos
    ADD CONSTRAINT rrhh_conceptos_pkey PRIMARY KEY (id);


--
-- Name: rrhh_departamentos_auditoria rrhh_departamentos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_departamentos_auditoria
    ADD CONSTRAINT rrhh_departamentos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_departamentos rrhh_departamentos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_departamentos
    ADD CONSTRAINT rrhh_departamentos_pkey PRIMARY KEY (id);


--
-- Name: rrhh_dispositivo_usuarios_auditoria rrhh_dispositivo_usuarios_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivo_usuarios_auditoria
    ADD CONSTRAINT rrhh_dispositivo_usuarios_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_dispositivo_usuarios rrhh_dispositivo_usuarios_dispositivo_id_empleado_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivo_usuarios
    ADD CONSTRAINT rrhh_dispositivo_usuarios_dispositivo_id_empleado_id_key UNIQUE (dispositivo_id, empleado_id);


--
-- Name: rrhh_dispositivo_usuarios rrhh_dispositivo_usuarios_dispositivo_id_id_en_dispositivo_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivo_usuarios
    ADD CONSTRAINT rrhh_dispositivo_usuarios_dispositivo_id_id_en_dispositivo_key UNIQUE (dispositivo_id, id_en_dispositivo);


--
-- Name: rrhh_dispositivo_usuarios rrhh_dispositivo_usuarios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivo_usuarios
    ADD CONSTRAINT rrhh_dispositivo_usuarios_pkey PRIMARY KEY (id);


--
-- Name: rrhh_dispositivos_auditoria rrhh_dispositivos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivos_auditoria
    ADD CONSTRAINT rrhh_dispositivos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_dispositivos rrhh_dispositivos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivos
    ADD CONSTRAINT rrhh_dispositivos_pkey PRIMARY KEY (id);


--
-- Name: rrhh_empleado_conceptos_auditoria rrhh_empleado_conceptos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_conceptos_auditoria
    ADD CONSTRAINT rrhh_empleado_conceptos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_empleado_conceptos rrhh_empleado_conceptos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_conceptos
    ADD CONSTRAINT rrhh_empleado_conceptos_pkey PRIMARY KEY (id);


--
-- Name: rrhh_empleado_horarios_auditoria rrhh_empleado_horarios_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_horarios_auditoria
    ADD CONSTRAINT rrhh_empleado_horarios_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_empleado_horarios rrhh_empleado_horarios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_horarios
    ADD CONSTRAINT rrhh_empleado_horarios_pkey PRIMARY KEY (id);


--
-- Name: rrhh_empleado_movimientos_auditoria rrhh_empleado_movimientos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_movimientos_auditoria
    ADD CONSTRAINT rrhh_empleado_movimientos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_empleado_movimientos rrhh_empleado_movimientos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_movimientos
    ADD CONSTRAINT rrhh_empleado_movimientos_pkey PRIMARY KEY (id);


--
-- Name: rrhh_empleado_pin rrhh_empleado_pin_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_pin
    ADD CONSTRAINT rrhh_empleado_pin_pkey PRIMARY KEY (empleado_id);


--
-- Name: rrhh_empleados_auditoria rrhh_empleados_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleados_auditoria
    ADD CONSTRAINT rrhh_empleados_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_empleados rrhh_empleados_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleados
    ADD CONSTRAINT rrhh_empleados_pkey PRIMARY KEY (id);


--
-- Name: rrhh_feriados_auditoria rrhh_feriados_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_feriados_auditoria
    ADD CONSTRAINT rrhh_feriados_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_feriados rrhh_feriados_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_feriados
    ADD CONSTRAINT rrhh_feriados_pkey PRIMARY KEY (id);


--
-- Name: rrhh_horario_dias rrhh_horario_dias_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horario_dias
    ADD CONSTRAINT rrhh_horario_dias_pkey PRIMARY KEY (horario_id, dia_semana);


--
-- Name: rrhh_horarios_auditoria rrhh_horarios_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horarios_auditoria
    ADD CONSTRAINT rrhh_horarios_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_horarios rrhh_horarios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horarios
    ADD CONSTRAINT rrhh_horarios_pkey PRIMARY KEY (id);


--
-- Name: rrhh_incapacidades_auditoria rrhh_incapacidades_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_incapacidades_auditoria
    ADD CONSTRAINT rrhh_incapacidades_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_incapacidades rrhh_incapacidades_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_incapacidades
    ADD CONSTRAINT rrhh_incapacidades_pkey PRIMARY KEY (id);


--
-- Name: rrhh_marcas_auditoria rrhh_marcas_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_marcas_auditoria
    ADD CONSTRAINT rrhh_marcas_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_marcas rrhh_marcas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_marcas
    ADD CONSTRAINT rrhh_marcas_pkey PRIMARY KEY (id);


--
-- Name: rrhh_permiso_solicitudes_auditoria rrhh_permiso_solicitudes_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_permiso_solicitudes_auditoria
    ADD CONSTRAINT rrhh_permiso_solicitudes_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_permiso_solicitudes rrhh_permiso_solicitudes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_permiso_solicitudes
    ADD CONSTRAINT rrhh_permiso_solicitudes_pkey PRIMARY KEY (id);


--
-- Name: rrhh_permiso_tipos_auditoria rrhh_permiso_tipos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_permiso_tipos_auditoria
    ADD CONSTRAINT rrhh_permiso_tipos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_permiso_tipos rrhh_permiso_tipos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_permiso_tipos
    ADD CONSTRAINT rrhh_permiso_tipos_pkey PRIMARY KEY (id);


--
-- Name: rrhh_planilla_empleados rrhh_planilla_empleados_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla_empleados
    ADD CONSTRAINT rrhh_planilla_empleados_pkey PRIMARY KEY (id);


--
-- Name: rrhh_planilla_empleados rrhh_planilla_empleados_planilla_id_empleado_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla_empleados
    ADD CONSTRAINT rrhh_planilla_empleados_planilla_id_empleado_id_key UNIQUE (planilla_id, empleado_id);


--
-- Name: rrhh_planilla_lineas rrhh_planilla_lineas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla_lineas
    ADD CONSTRAINT rrhh_planilla_lineas_pkey PRIMARY KEY (id);


--
-- Name: rrhh_planillas_auditoria rrhh_planillas_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planillas_auditoria
    ADD CONSTRAINT rrhh_planillas_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_planillas rrhh_planillas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planillas
    ADD CONSTRAINT rrhh_planillas_pkey PRIMARY KEY (id);


--
-- Name: rrhh_puestos_auditoria rrhh_puestos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_puestos_auditoria
    ADD CONSTRAINT rrhh_puestos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_puestos rrhh_puestos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_puestos
    ADD CONSTRAINT rrhh_puestos_pkey PRIMARY KEY (id);


--
-- Name: rrhh_renta_tramos_auditoria rrhh_renta_tramos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_renta_tramos_auditoria
    ADD CONSTRAINT rrhh_renta_tramos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_renta_tramos rrhh_renta_tramos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_renta_tramos
    ADD CONSTRAINT rrhh_renta_tramos_pkey PRIMARY KEY (id);


--
-- Name: rrhh_tasas_anio_auditoria rrhh_tasas_anio_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_tasas_anio_auditoria
    ADD CONSTRAINT rrhh_tasas_anio_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_tasas_anio rrhh_tasas_anio_empresa_id_anio_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_tasas_anio
    ADD CONSTRAINT rrhh_tasas_anio_empresa_id_anio_key UNIQUE (empresa_id, anio);


--
-- Name: rrhh_tasas_anio rrhh_tasas_anio_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_tasas_anio
    ADD CONSTRAINT rrhh_tasas_anio_pkey PRIMARY KEY (id);


--
-- Name: rrhh_vacaciones_movimientos_auditoria rrhh_vacaciones_movimientos_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_vacaciones_movimientos_auditoria
    ADD CONSTRAINT rrhh_vacaciones_movimientos_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_vacaciones_movimientos rrhh_vacaciones_movimientos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_vacaciones_movimientos
    ADD CONSTRAINT rrhh_vacaciones_movimientos_pkey PRIMARY KEY (id);


--
-- Name: rrhh_vacaciones_solicitudes_auditoria rrhh_vacaciones_solicitudes_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_vacaciones_solicitudes_auditoria
    ADD CONSTRAINT rrhh_vacaciones_solicitudes_auditoria_pkey PRIMARY KEY (id);


--
-- Name: rrhh_vacaciones_solicitudes rrhh_vacaciones_solicitudes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_vacaciones_solicitudes
    ADD CONSTRAINT rrhh_vacaciones_solicitudes_pkey PRIMARY KEY (id);


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
-- Name: sistema_parametros_auditoria sistema_parametros_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sistema_parametros_auditoria
    ADD CONSTRAINT sistema_parametros_auditoria_pkey PRIMARY KEY (id);


--
-- Name: sistema_parametros sistema_parametros_clave_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sistema_parametros
    ADD CONSTRAINT sistema_parametros_clave_key UNIQUE (clave);


--
-- Name: sistema_parametros sistema_parametros_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sistema_parametros
    ADD CONSTRAINT sistema_parametros_pkey PRIMARY KEY (id);


--
-- Name: sucursal_bodegas_auditoria sucursal_bodegas_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_bodegas_auditoria
    ADD CONSTRAINT sucursal_bodegas_auditoria_pkey PRIMARY KEY (id);


--
-- Name: sucursal_bodegas sucursal_bodegas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_bodegas
    ADD CONSTRAINT sucursal_bodegas_pkey PRIMARY KEY (id);


--
-- Name: sucursal_contacto_auditoria sucursal_contacto_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_contacto_auditoria
    ADD CONSTRAINT sucursal_contacto_auditoria_pkey PRIMARY KEY (id);


--
-- Name: sucursal_contacto sucursal_contacto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_contacto
    ADD CONSTRAINT sucursal_contacto_pkey PRIMARY KEY (id);


--
-- Name: sucursal_contacto sucursal_contacto_sucursal_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_contacto
    ADD CONSTRAINT sucursal_contacto_sucursal_id_key UNIQUE (sucursal_id);


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
-- Name: documentos_adjuntos uq_documentos_adjuntos_clave; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documentos_adjuntos
    ADD CONSTRAINT uq_documentos_adjuntos_clave UNIQUE (clave);


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
-- Name: mercadeo_imagenes uq_mercadeo_imagenes_clave; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mercadeo_imagenes
    ADD CONSTRAINT uq_mercadeo_imagenes_clave UNIQUE (clave);


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
-- Name: idx_agenda_aud_cliente_antes; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_aud_cliente_antes ON public.agenda_eventos_auditoria USING btree ((((datos_antes ->> 'cliente_id'::text))::bigint), created_at DESC) WHERE ((operacion)::text = ANY ((ARRAY['UPDATE'::character varying, 'DELETE'::character varying])::text[]));


--
-- Name: idx_agenda_aud_cliente_despues; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_aud_cliente_despues ON public.agenda_eventos_auditoria USING btree ((((datos_despues ->> 'cliente_id'::text))::bigint), created_at DESC) WHERE ((operacion)::text = ANY ((ARRAY['UPDATE'::character varying, 'DELETE'::character varying])::text[]));


--
-- Name: idx_agenda_avisos_envios_evento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_avisos_envios_evento ON public.agenda_avisos_envios USING btree (evento_id);


--
-- Name: idx_agenda_avisos_tokens_evento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_avisos_tokens_evento ON public.agenda_avisos_tokens USING btree (evento_id);


--
-- Name: idx_agenda_espacios_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_espacios_auditoria_registro ON public.agenda_espacios_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_agenda_espacios_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_espacios_empresa ON public.agenda_espacios USING btree (empresa_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_agenda_evento_linea_productos_linea; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_evento_linea_productos_linea ON public.agenda_evento_linea_productos USING btree (linea_id);


--
-- Name: idx_agenda_evento_lineas_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_evento_lineas_auditoria_registro ON public.agenda_evento_lineas_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_agenda_evento_lineas_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_evento_lineas_documento ON public.agenda_evento_lineas USING btree (documento_id);


--
-- Name: idx_agenda_evento_lineas_espacio; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_evento_lineas_espacio ON public.agenda_evento_lineas USING btree (espacio_id, fecha_inicio, fecha_fin) WHERE (espacio_id IS NOT NULL);


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
-- Name: idx_agenda_eventos_cliente_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_eventos_cliente_fecha ON public.agenda_eventos USING btree (cliente_id, fecha_inicio DESC, id DESC) WHERE (deleted_at IS NULL);


--
-- Name: idx_agenda_eventos_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_eventos_documento ON public.agenda_eventos USING btree (documento_id);


--
-- Name: idx_agenda_eventos_empresa_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_agenda_eventos_empresa_fecha ON public.agenda_eventos USING btree (empresa_id, fecha_inicio);


--
-- Name: idx_bitacora_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bitacora_created_at ON public.bitacora_api USING btree (created_at DESC);


--
-- Name: idx_bitacora_empresa_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bitacora_empresa_id ON public.bitacora_api USING btree (empresa_id);


--
-- Name: idx_bitacora_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bitacora_user_id ON public.bitacora_api USING btree (user_id);


--
-- Name: idx_bodega_productos_producto; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bodega_productos_producto ON public.bodega_productos USING btree (producto_id);


--
-- Name: idx_caja_cierre_medios; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_caja_cierre_medios ON public.caja_cierre_medios_pago USING btree (cierre_id);


--
-- Name: idx_caja_cierres_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_caja_cierres_auditoria_registro ON public.caja_cierres_auditoria USING btree (registro_id, created_at DESC);


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
-- Name: idx_cotizaciones_receptor_aprobado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cotizaciones_receptor_aprobado ON public.cotizaciones USING btree (receptor_cliente_id, aprobado_at DESC, id DESC) WHERE ((deleted_at IS NULL) AND (aprobado_at IS NOT NULL));


--
-- Name: idx_cuentas_por_cobrar_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cuentas_por_cobrar_auditoria_registro ON public.cuentas_por_cobrar_auditoria USING btree (registro_id, created_at DESC);


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
-- Name: idx_doc_desglose_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_doc_desglose_documento ON public.documento_desglose_impuesto USING btree (documento_id);


--
-- Name: idx_doc_linea_desc_linea; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_doc_linea_desc_linea ON public.documento_linea_descuentos USING btree (linea_id);


--
-- Name: idx_doc_linea_imp_linea; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_doc_linea_imp_linea ON public.documento_linea_impuestos USING btree (linea_id);


--
-- Name: idx_doc_linea_surt_linea; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_doc_linea_surt_linea ON public.documento_linea_surtidos USING btree (linea_id);


--
-- Name: idx_doc_medios_pago_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_doc_medios_pago_documento ON public.documento_medios_pago USING btree (documento_id);


--
-- Name: idx_doc_otros_cargos_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_doc_otros_cargos_documento ON public.documento_otros_cargos USING btree (documento_id);


--
-- Name: idx_doc_referencias_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_doc_referencias_documento ON public.documento_referencias USING btree (documento_id);


--
-- Name: idx_docs_empresa_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_docs_empresa_created ON public.documentos_electronicos USING btree (empresa_id, created_at DESC, id DESC) WHERE (deleted_at IS NULL);


--
-- Name: idx_docs_receptor_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_docs_receptor_fecha ON public.documentos_electronicos USING btree (receptor_cliente_id, fecha_emision DESC, id DESC) WHERE (deleted_at IS NULL);


--
-- Name: idx_docs_trgm_clave; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_docs_trgm_clave ON public.documentos_electronicos USING gin (clave public.gin_trgm_ops) WHERE (deleted_at IS NULL);


--
-- Name: idx_docs_trgm_consec; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_docs_trgm_consec ON public.documentos_electronicos USING gin (numero_consecutivo public.gin_trgm_ops) WHERE (deleted_at IS NULL);


--
-- Name: idx_docs_trgm_nombre; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_docs_trgm_nombre ON public.documentos_electronicos USING gin (receptor_nombre public.gin_trgm_ops) WHERE (deleted_at IS NULL);


--
-- Name: idx_docs_trgm_numid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_docs_trgm_numid ON public.documentos_electronicos USING gin (receptor_numero_id public.gin_trgm_ops) WHERE (deleted_at IS NULL);


--
-- Name: idx_documento_cxc_aplicaciones_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documento_cxc_aplicaciones_auditoria_registro ON public.documento_cxc_aplicaciones_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_documentos_adjuntos_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documentos_adjuntos_auditoria_registro ON public.documentos_adjuntos_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_documentos_adjuntos_entidad; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documentos_adjuntos_entidad ON public.documentos_adjuntos USING btree (empresa_id, entidad, entidad_id, id DESC) WHERE (deleted_at IS NULL);


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
-- Name: idx_empresa_hacienda_config_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_empresa_hacienda_config_auditoria_registro ON public.empresa_hacienda_config_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_empresa_medios_pago_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_empresa_medios_pago_auditoria_registro ON public.empresa_medios_pago_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_empresa_monedas_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_empresa_monedas_auditoria_registro ON public.empresa_monedas_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_empresa_perfil_fiscal_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_empresa_perfil_fiscal_auditoria_registro ON public.empresa_perfil_fiscal_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_empresa_tarifas_impuesto_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_empresa_tarifas_impuesto_auditoria_registro ON public.empresa_tarifas_impuesto_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_empresa_tipos_descuento_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_empresa_tipos_descuento_auditoria_registro ON public.empresa_tipos_descuento_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_empresa_tipos_impuesto_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_empresa_tipos_impuesto_auditoria_registro ON public.empresa_tipos_impuesto_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_fact_recibidas_referencia; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fact_recibidas_referencia ON public.facturas_recibidas USING btree (factura_referencia_id);


--
-- Name: idx_facturas_recibidas_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_facturas_recibidas_auditoria_registro ON public.facturas_recibidas_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_fr_emisor_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fr_emisor_fecha ON public.facturas_recibidas USING btree (emisor_numero_id, COALESCE(fecha_emision, created_at) DESC, id DESC);


--
-- Name: idx_fr_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fr_empresa ON public.facturas_recibidas USING btree (empresa_id);


--
-- Name: idx_fr_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fr_estado ON public.facturas_recibidas USING btree (estado_recepcion);


--
-- Name: idx_fr_proveedor_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fr_proveedor_fecha ON public.facturas_recibidas USING btree (proveedor_id, COALESCE(fecha_emision, created_at) DESC, id DESC);


--
-- Name: idx_funcionario_sucursales_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_funcionario_sucursales_auditoria_registro ON public.funcionario_sucursales_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_funcionario_sucursales_funcionario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_funcionario_sucursales_funcionario ON public.funcionario_sucursales USING btree (funcionario_id);


--
-- Name: idx_mercadeo_campana_envios_campana; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mercadeo_campana_envios_campana ON public.mercadeo_campana_envios USING btree (campana_id);


--
-- Name: idx_mercadeo_campanas_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mercadeo_campanas_auditoria_registro ON public.mercadeo_campanas_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_mercadeo_campanas_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mercadeo_campanas_empresa ON public.mercadeo_campanas USING btree (empresa_id);


--
-- Name: idx_mercadeo_campanas_plantilla; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mercadeo_campanas_plantilla ON public.mercadeo_campanas USING btree (plantilla_id);


--
-- Name: idx_mercadeo_imagenes_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mercadeo_imagenes_auditoria_registro ON public.mercadeo_imagenes_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_mercadeo_imagenes_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mercadeo_imagenes_empresa ON public.mercadeo_imagenes USING btree (empresa_id, id DESC) WHERE (deleted_at IS NULL);


--
-- Name: idx_mercadeo_plantillas_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mercadeo_plantillas_auditoria_registro ON public.mercadeo_plantillas_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_mercadeo_plantillas_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mercadeo_plantillas_empresa ON public.mercadeo_plantillas USING btree (empresa_id);


--
-- Name: idx_mov_inv_bodega_destino; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_inv_bodega_destino ON public.movimientos_inventario USING btree (bodega_destino_id);


--
-- Name: idx_mov_inv_bodega_origen; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_inv_bodega_origen ON public.movimientos_inventario USING btree (bodega_origen_id);


--
-- Name: idx_mov_inv_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_inv_created ON public.movimientos_inventario USING btree (created_at DESC);


--
-- Name: idx_mov_inv_documento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_inv_documento ON public.movimientos_inventario USING btree (documento_id);


--
-- Name: idx_mov_inv_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_inv_empresa ON public.movimientos_inventario USING btree (empresa_id);


--
-- Name: idx_mov_inv_empresa_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_inv_empresa_created ON public.movimientos_inventario USING btree (empresa_id, created_at DESC, id DESC);


--
-- Name: idx_mov_inv_producto; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_inv_producto ON public.movimientos_inventario USING btree (producto_id, bodega_origen_id);


--
-- Name: idx_mov_inv_proveedor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_inv_proveedor ON public.movimientos_inventario USING btree (proveedor_id);


--
-- Name: idx_ordenes_pedido_empresa_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ordenes_pedido_empresa_estado ON public.ordenes_pedido USING btree (empresa_id, estado);


--
-- Name: idx_ordenes_pedido_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ordenes_pedido_fecha ON public.ordenes_pedido USING btree (empresa_id, fecha DESC);


--
-- Name: idx_ordenes_pedido_proveedor_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ordenes_pedido_proveedor_fecha ON public.ordenes_pedido USING btree (proveedor_id, fecha DESC, id DESC) WHERE (deleted_at IS NULL);


--
-- Name: idx_producto_proveedor_equivalencias_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_producto_proveedor_equivalencias_auditoria_registro ON public.producto_proveedor_equivalencias_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_productos_categoria; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_productos_categoria ON public.productos USING btree (categoria_id);


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
-- Name: idx_recibos_adelanto_aplicaciones_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recibos_adelanto_aplicaciones_auditoria_registro ON public.recibos_adelanto_aplicaciones_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_recibos_adelanto_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recibos_adelanto_auditoria_registro ON public.recibos_adelanto_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_agentes_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_agentes_auditoria_registro ON public.rrhh_agentes_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_ajustes_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_ajustes_fecha ON public.rrhh_asistencia_ajustes USING btree (empresa_id, fecha) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_asistencia_ajustes_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_asistencia_ajustes_auditoria_registro ON public.rrhh_asistencia_ajustes_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_cargas_anio; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_cargas_anio ON public.rrhh_cargas_sociales USING btree (empresa_id, anio);


--
-- Name: idx_rrhh_cargas_sociales_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_cargas_sociales_auditoria_registro ON public.rrhh_cargas_sociales_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_conceptos_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_conceptos_auditoria_registro ON public.rrhh_conceptos_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_departamentos_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_departamentos_auditoria_registro ON public.rrhh_departamentos_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_departamentos_padre; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_departamentos_padre ON public.rrhh_departamentos USING btree (departamento_padre_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_dispositivo_usuarios_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_dispositivo_usuarios_auditoria_registro ON public.rrhh_dispositivo_usuarios_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_dispositivos_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_dispositivos_auditoria_registro ON public.rrhh_dispositivos_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_emp_conceptos_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_emp_conceptos_empleado ON public.rrhh_empleado_conceptos USING btree (empleado_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_emp_horarios_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_emp_horarios_empleado ON public.rrhh_empleado_horarios USING btree (empleado_id, vigente_desde DESC) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_emp_horarios_horario; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_emp_horarios_horario ON public.rrhh_empleado_horarios USING btree (horario_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_empleado_conceptos_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_empleado_conceptos_auditoria_registro ON public.rrhh_empleado_conceptos_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_empleado_horarios_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_empleado_horarios_auditoria_registro ON public.rrhh_empleado_horarios_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_empleado_movimientos_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_empleado_movimientos_auditoria_registro ON public.rrhh_empleado_movimientos_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_empleados_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_empleados_auditoria_registro ON public.rrhh_empleados_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_empleados_departamento; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_empleados_departamento ON public.rrhh_empleados USING btree (departamento_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_empleados_jefe; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_empleados_jefe ON public.rrhh_empleados USING btree (jefe_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_empleados_puesto; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_empleados_puesto ON public.rrhh_empleados USING btree (puesto_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_feriados_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_feriados_auditoria_registro ON public.rrhh_feriados_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_horarios_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_horarios_auditoria_registro ON public.rrhh_horarios_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_inc_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_inc_empleado ON public.rrhh_incapacidades USING btree (empleado_id, fecha_inicio) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_inc_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_inc_empresa ON public.rrhh_incapacidades USING btree (empresa_id, estado, fecha_inicio) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_incapacidades_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_incapacidades_auditoria_registro ON public.rrhh_incapacidades_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_marcas_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_marcas_auditoria_registro ON public.rrhh_marcas_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_marcas_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_marcas_empleado ON public.rrhh_marcas USING btree (empleado_id, fecha_hora) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_marcas_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_marcas_estado ON public.rrhh_marcas USING btree (empresa_id, estado) WHERE ((deleted_at IS NULL) AND ((estado)::text <> 'valida'::text));


--
-- Name: idx_rrhh_marcas_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_marcas_fecha ON public.rrhh_marcas USING btree (empresa_id, fecha_hora) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_movimientos_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_movimientos_empleado ON public.rrhh_empleado_movimientos USING btree (empleado_id, fecha DESC, id DESC);


--
-- Name: idx_rrhh_perm_sol_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_perm_sol_empleado ON public.rrhh_permiso_solicitudes USING btree (empleado_id, fecha_inicio) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_perm_sol_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_perm_sol_estado ON public.rrhh_permiso_solicitudes USING btree (empresa_id, estado) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_perm_sol_jefe; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_perm_sol_jefe ON public.rrhh_permiso_solicitudes USING btree (jefe_id, estado) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_permiso_solicitudes_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_permiso_solicitudes_auditoria_registro ON public.rrhh_permiso_solicitudes_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_permiso_tipos_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_permiso_tipos_auditoria_registro ON public.rrhh_permiso_tipos_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_planilla_emp_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_planilla_emp_empleado ON public.rrhh_planilla_empleados USING btree (empleado_id);


--
-- Name: idx_rrhh_planilla_lineas; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_planilla_lineas ON public.rrhh_planilla_lineas USING btree (planilla_id, empleado_id);


--
-- Name: idx_rrhh_planillas_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_planillas_auditoria_registro ON public.rrhh_planillas_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_planillas_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_planillas_empresa ON public.rrhh_planillas USING btree (empresa_id, fecha_inicio DESC) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_puestos_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_puestos_auditoria_registro ON public.rrhh_puestos_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_renta_tramos_anio; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_renta_tramos_anio ON public.rrhh_renta_tramos USING btree (empresa_id, anio, orden);


--
-- Name: idx_rrhh_renta_tramos_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_renta_tramos_auditoria_registro ON public.rrhh_renta_tramos_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_tasas_anio_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_tasas_anio_auditoria_registro ON public.rrhh_tasas_anio_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_vac_mov_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_vac_mov_empleado ON public.rrhh_vacaciones_movimientos USING btree (empleado_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_vac_sol_empleado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_vac_sol_empleado ON public.rrhh_vacaciones_solicitudes USING btree (empleado_id, fecha_inicio) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_vac_sol_estado; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_vac_sol_estado ON public.rrhh_vacaciones_solicitudes USING btree (empresa_id, estado) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_vac_sol_jefe; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_vac_sol_jefe ON public.rrhh_vacaciones_solicitudes USING btree (jefe_id, estado) WHERE (deleted_at IS NULL);


--
-- Name: idx_rrhh_vacaciones_movimientos_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_vacaciones_movimientos_auditoria_registro ON public.rrhh_vacaciones_movimientos_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_rrhh_vacaciones_solicitudes_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rrhh_vacaciones_solicitudes_auditoria_registro ON public.rrhh_vacaciones_solicitudes_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_sucursal_bodegas_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sucursal_bodegas_auditoria_registro ON public.sucursal_bodegas_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_sucursal_bodegas_bodega; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sucursal_bodegas_bodega ON public.sucursal_bodegas USING btree (bodega_id);


--
-- Name: idx_sucursal_contacto_auditoria_registro; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sucursal_contacto_auditoria_registro ON public.sucursal_contacto_auditoria USING btree (registro_id, created_at DESC);


--
-- Name: idx_sucursal_contacto_empresa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sucursal_contacto_empresa ON public.sucursal_contacto USING btree (empresa_id);


--
-- Name: uq_agenda_espacios_nombre; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_agenda_espacios_nombre ON public.agenda_espacios USING btree (empresa_id, COALESCE(sucursal_id, (0)::bigint), lower((nombre)::text)) WHERE (deleted_at IS NULL);


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
-- Name: uq_rrhh_agentes_nombre; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_agentes_nombre ON public.rrhh_agentes USING btree (empresa_id, lower((nombre)::text)) WHERE (deleted_at IS NULL);


--
-- Name: uq_rrhh_agentes_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_agentes_token ON public.rrhh_agentes USING btree (token_hash) WHERE (token_hash IS NOT NULL);


--
-- Name: uq_rrhh_ajustes; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_ajustes ON public.rrhh_asistencia_ajustes USING btree (empleado_id, fecha, tipo) WHERE (deleted_at IS NULL);


--
-- Name: uq_rrhh_conceptos_codigo; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_conceptos_codigo ON public.rrhh_conceptos USING btree (empresa_id, lower((codigo)::text)) WHERE (deleted_at IS NULL);


--
-- Name: uq_rrhh_departamentos_nombre; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_departamentos_nombre ON public.rrhh_departamentos USING btree (empresa_id, lower((nombre)::text)) WHERE (deleted_at IS NULL);


--
-- Name: uq_rrhh_dispositivos_nombre; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_dispositivos_nombre ON public.rrhh_dispositivos USING btree (empresa_id, lower((nombre)::text)) WHERE (deleted_at IS NULL);


--
-- Name: uq_rrhh_empleados_codigo; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_empleados_codigo ON public.rrhh_empleados USING btree (empresa_id, lower((codigo)::text)) WHERE (deleted_at IS NULL);


--
-- Name: uq_rrhh_empleados_funcionario; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_empleados_funcionario ON public.rrhh_empleados USING btree (funcionario_id) WHERE ((funcionario_id IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: uq_rrhh_empleados_identificacion; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_empleados_identificacion ON public.rrhh_empleados USING btree (empresa_id, lower((identificacion)::text)) WHERE (deleted_at IS NULL);


--
-- Name: uq_rrhh_feriados_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_feriados_fecha ON public.rrhh_feriados USING btree (empresa_id, fecha) WHERE (deleted_at IS NULL);


--
-- Name: uq_rrhh_horarios_nombre; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_horarios_nombre ON public.rrhh_horarios USING btree (empresa_id, lower((nombre)::text)) WHERE (deleted_at IS NULL);


--
-- Name: uq_rrhh_marcas_referencia; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_marcas_referencia ON public.rrhh_marcas USING btree (dispositivo_id, referencia_externa) WHERE (referencia_externa IS NOT NULL);


--
-- Name: uq_rrhh_permiso_tipos_nombre; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_permiso_tipos_nombre ON public.rrhh_permiso_tipos USING btree (empresa_id, lower((nombre)::text)) WHERE (deleted_at IS NULL);


--
-- Name: uq_rrhh_puestos_nombre; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_puestos_nombre ON public.rrhh_puestos USING btree (empresa_id, lower((nombre)::text)) WHERE (deleted_at IS NULL);


--
-- Name: uq_rrhh_vac_mov_saldo_inicial; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rrhh_vac_mov_saldo_inicial ON public.rrhh_vacaciones_movimientos USING btree (empleado_id) WHERE (((tipo)::text = 'saldo_inicial'::text) AND (deleted_at IS NULL));


--
-- Name: agenda_espacios trg_agenda_espacios_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_agenda_espacios_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.agenda_espacios FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: agenda_evento_lineas trg_agenda_evento_lineas_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_agenda_evento_lineas_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.agenda_evento_lineas FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


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
-- Name: caja_cierres trg_caja_cierres_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_caja_cierres_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.caja_cierres FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: categorias_producto trg_categorias_producto_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_categorias_producto_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.categorias_producto FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: cliente_exoneraciones trg_cliente_exoneraciones_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_cliente_exoneraciones_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.cliente_exoneraciones FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


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
-- Name: cuentas_por_cobrar trg_cuentas_por_cobrar_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_cuentas_por_cobrar_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.cuentas_por_cobrar FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: documento_cxc_aplicaciones trg_documento_cxc_aplicaciones_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_documento_cxc_aplicaciones_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.documento_cxc_aplicaciones FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: documentos_adjuntos trg_documentos_adjuntos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_documentos_adjuntos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.documentos_adjuntos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: documentos_electronicos trg_documentos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_documentos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.documentos_electronicos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica('xml_firmado', 'xml_respuesta');


--
-- Name: empresa_hacienda_config trg_empresa_hacienda_config_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_empresa_hacienda_config_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.empresa_hacienda_config FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica('hacienda_contrasena', 'certificado_p12', 'certificado_pin');


--
-- Name: empresa_medios_pago trg_empresa_medios_pago_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_empresa_medios_pago_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.empresa_medios_pago FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: empresa_monedas trg_empresa_monedas_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_empresa_monedas_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.empresa_monedas FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: empresa_perfil_fiscal trg_empresa_perfil_fiscal_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_empresa_perfil_fiscal_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.empresa_perfil_fiscal FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: empresa_tarifas_impuesto trg_empresa_tarifas_impuesto_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_empresa_tarifas_impuesto_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.empresa_tarifas_impuesto FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: empresa_tipos_descuento trg_empresa_tipos_descuento_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_empresa_tipos_descuento_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.empresa_tipos_descuento FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: empresa_tipos_impuesto trg_empresa_tipos_impuesto_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_empresa_tipos_impuesto_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.empresa_tipos_impuesto FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: facturas_recibidas trg_facturas_recibidas_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_facturas_recibidas_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.facturas_recibidas FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica('xml_recibido', 'xml_mensaje_receptor', 'hacienda_respuesta_mr');


--
-- Name: funcionario_sucursales trg_funcionario_sucursales_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_funcionario_sucursales_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.funcionario_sucursales FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: funcionarios trg_funcionarios_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_funcionarios_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.funcionarios FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: mercadeo_campanas trg_mercadeo_campanas_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_mercadeo_campanas_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.mercadeo_campanas FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: mercadeo_imagenes trg_mercadeo_imagenes_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_mercadeo_imagenes_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.mercadeo_imagenes FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: mercadeo_plantillas trg_mercadeo_plantillas_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_mercadeo_plantillas_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.mercadeo_plantillas FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: ordenes_pedido trg_ordenes_pedido_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ordenes_pedido_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.ordenes_pedido FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: producto_proveedor_equivalencias trg_producto_proveedor_equivalencias_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_producto_proveedor_equivalencias_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.producto_proveedor_equivalencias FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: productos trg_productos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_productos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.productos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: proveedores trg_proveedores_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_proveedores_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.proveedores FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: recibos_adelanto_aplicaciones trg_recibos_adelanto_aplicaciones_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_recibos_adelanto_aplicaciones_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.recibos_adelanto_aplicaciones FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: recibos_adelanto trg_recibos_adelanto_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_recibos_adelanto_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.recibos_adelanto FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_agentes trg_rrhh_agentes_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_agentes_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_agentes FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_asistencia_ajustes trg_rrhh_asistencia_ajustes_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_asistencia_ajustes_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_asistencia_ajustes FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_cargas_sociales trg_rrhh_cargas_sociales_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_cargas_sociales_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_cargas_sociales FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_conceptos trg_rrhh_conceptos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_conceptos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_conceptos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_departamentos trg_rrhh_departamentos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_departamentos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_departamentos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_dispositivo_usuarios trg_rrhh_dispositivo_usuarios_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_dispositivo_usuarios_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_dispositivo_usuarios FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_dispositivos trg_rrhh_dispositivos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_dispositivos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_dispositivos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_empleado_conceptos trg_rrhh_empleado_conceptos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_empleado_conceptos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_empleado_conceptos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_empleado_horarios trg_rrhh_empleado_horarios_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_empleado_horarios_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_empleado_horarios FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_empleado_movimientos trg_rrhh_empleado_movimientos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_empleado_movimientos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_empleado_movimientos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_empleados trg_rrhh_empleados_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_empleados_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_empleados FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_feriados trg_rrhh_feriados_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_feriados_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_feriados FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_horarios trg_rrhh_horarios_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_horarios_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_horarios FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_incapacidades trg_rrhh_incapacidades_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_incapacidades_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_incapacidades FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_marcas trg_rrhh_marcas_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_marcas_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_marcas FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_permiso_solicitudes trg_rrhh_permiso_solicitudes_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_permiso_solicitudes_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_permiso_solicitudes FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_permiso_tipos trg_rrhh_permiso_tipos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_permiso_tipos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_permiso_tipos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_planillas trg_rrhh_planillas_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_planillas_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_planillas FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_puestos trg_rrhh_puestos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_puestos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_puestos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_renta_tramos trg_rrhh_renta_tramos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_renta_tramos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_renta_tramos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_tasas_anio trg_rrhh_tasas_anio_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_tasas_anio_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_tasas_anio FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_vacaciones_movimientos trg_rrhh_vacaciones_movimientos_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_vacaciones_movimientos_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_vacaciones_movimientos FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: rrhh_vacaciones_solicitudes trg_rrhh_vacaciones_solicitudes_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rrhh_vacaciones_solicitudes_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.rrhh_vacaciones_solicitudes FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: servicios trg_servicios_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_servicios_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.servicios FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: sistema_parametros trg_sistema_parametros_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sistema_parametros_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.sistema_parametros FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: sucursal_bodegas trg_sucursal_bodegas_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sucursal_bodegas_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.sucursal_bodegas FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: sucursal_contacto trg_sucursal_contacto_auditoria; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sucursal_contacto_auditoria AFTER INSERT OR DELETE OR UPDATE ON public.sucursal_contacto FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_generica();


--
-- Name: agenda_evento_lineas agenda_evento_lineas_espacio_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agenda_evento_lineas
    ADD CONSTRAINT agenda_evento_lineas_espacio_id_fkey FOREIGN KEY (espacio_id) REFERENCES public.agenda_espacios(id);


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
-- Name: cliente_exoneraciones cliente_exoneraciones_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cliente_exoneraciones
    ADD CONSTRAINT cliente_exoneraciones_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id);


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
-- Name: rrhh_departamentos fk_rrhh_departamentos_jefe; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_departamentos
    ADD CONSTRAINT fk_rrhh_departamentos_jefe FOREIGN KEY (jefe_empleado_id) REFERENCES public.rrhh_empleados(id);


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
-- Name: rrhh_asistencia_ajustes rrhh_asistencia_ajustes_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_asistencia_ajustes
    ADD CONSTRAINT rrhh_asistencia_ajustes_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_departamentos rrhh_departamentos_departamento_padre_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_departamentos
    ADD CONSTRAINT rrhh_departamentos_departamento_padre_id_fkey FOREIGN KEY (departamento_padre_id) REFERENCES public.rrhh_departamentos(id);


--
-- Name: rrhh_dispositivo_usuarios rrhh_dispositivo_usuarios_dispositivo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivo_usuarios
    ADD CONSTRAINT rrhh_dispositivo_usuarios_dispositivo_id_fkey FOREIGN KEY (dispositivo_id) REFERENCES public.rrhh_dispositivos(id);


--
-- Name: rrhh_dispositivo_usuarios rrhh_dispositivo_usuarios_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivo_usuarios
    ADD CONSTRAINT rrhh_dispositivo_usuarios_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_dispositivos rrhh_dispositivos_agente_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_dispositivos
    ADD CONSTRAINT rrhh_dispositivos_agente_id_fkey FOREIGN KEY (agente_id) REFERENCES public.rrhh_agentes(id);


--
-- Name: rrhh_empleado_conceptos rrhh_empleado_conceptos_concepto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_conceptos
    ADD CONSTRAINT rrhh_empleado_conceptos_concepto_id_fkey FOREIGN KEY (concepto_id) REFERENCES public.rrhh_conceptos(id);


--
-- Name: rrhh_empleado_conceptos rrhh_empleado_conceptos_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_conceptos
    ADD CONSTRAINT rrhh_empleado_conceptos_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_empleado_horarios rrhh_empleado_horarios_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_horarios
    ADD CONSTRAINT rrhh_empleado_horarios_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_empleado_horarios rrhh_empleado_horarios_horario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_horarios
    ADD CONSTRAINT rrhh_empleado_horarios_horario_id_fkey FOREIGN KEY (horario_id) REFERENCES public.rrhh_horarios(id);


--
-- Name: rrhh_empleado_movimientos rrhh_empleado_movimientos_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_movimientos
    ADD CONSTRAINT rrhh_empleado_movimientos_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_empleado_pin rrhh_empleado_pin_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleado_pin
    ADD CONSTRAINT rrhh_empleado_pin_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_empleados rrhh_empleados_departamento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleados
    ADD CONSTRAINT rrhh_empleados_departamento_id_fkey FOREIGN KEY (departamento_id) REFERENCES public.rrhh_departamentos(id);


--
-- Name: rrhh_empleados rrhh_empleados_funcionario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleados
    ADD CONSTRAINT rrhh_empleados_funcionario_id_fkey FOREIGN KEY (funcionario_id) REFERENCES public.funcionarios(id);


--
-- Name: rrhh_empleados rrhh_empleados_jefe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleados
    ADD CONSTRAINT rrhh_empleados_jefe_id_fkey FOREIGN KEY (jefe_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_empleados rrhh_empleados_puesto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_empleados
    ADD CONSTRAINT rrhh_empleados_puesto_id_fkey FOREIGN KEY (puesto_id) REFERENCES public.rrhh_puestos(id);


--
-- Name: rrhh_horario_dias rrhh_horario_dias_horario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_horario_dias
    ADD CONSTRAINT rrhh_horario_dias_horario_id_fkey FOREIGN KEY (horario_id) REFERENCES public.rrhh_horarios(id) ON DELETE CASCADE;


--
-- Name: rrhh_incapacidades rrhh_incapacidades_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_incapacidades
    ADD CONSTRAINT rrhh_incapacidades_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_marcas rrhh_marcas_agente_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_marcas
    ADD CONSTRAINT rrhh_marcas_agente_id_fkey FOREIGN KEY (agente_id) REFERENCES public.rrhh_agentes(id);


--
-- Name: rrhh_marcas rrhh_marcas_dispositivo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_marcas
    ADD CONSTRAINT rrhh_marcas_dispositivo_id_fkey FOREIGN KEY (dispositivo_id) REFERENCES public.rrhh_dispositivos(id);


--
-- Name: rrhh_marcas rrhh_marcas_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_marcas
    ADD CONSTRAINT rrhh_marcas_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_permiso_solicitudes rrhh_permiso_solicitudes_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_permiso_solicitudes
    ADD CONSTRAINT rrhh_permiso_solicitudes_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_permiso_solicitudes rrhh_permiso_solicitudes_jefe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_permiso_solicitudes
    ADD CONSTRAINT rrhh_permiso_solicitudes_jefe_id_fkey FOREIGN KEY (jefe_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_permiso_solicitudes rrhh_permiso_solicitudes_tipo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_permiso_solicitudes
    ADD CONSTRAINT rrhh_permiso_solicitudes_tipo_id_fkey FOREIGN KEY (tipo_id) REFERENCES public.rrhh_permiso_tipos(id);


--
-- Name: rrhh_planilla_empleados rrhh_planilla_empleados_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla_empleados
    ADD CONSTRAINT rrhh_planilla_empleados_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_planilla_empleados rrhh_planilla_empleados_planilla_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla_empleados
    ADD CONSTRAINT rrhh_planilla_empleados_planilla_id_fkey FOREIGN KEY (planilla_id) REFERENCES public.rrhh_planillas(id) ON DELETE CASCADE;


--
-- Name: rrhh_planilla_lineas rrhh_planilla_lineas_concepto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla_lineas
    ADD CONSTRAINT rrhh_planilla_lineas_concepto_id_fkey FOREIGN KEY (concepto_id) REFERENCES public.rrhh_conceptos(id);


--
-- Name: rrhh_planilla_lineas rrhh_planilla_lineas_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla_lineas
    ADD CONSTRAINT rrhh_planilla_lineas_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_planilla_lineas rrhh_planilla_lineas_planilla_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_planilla_lineas
    ADD CONSTRAINT rrhh_planilla_lineas_planilla_id_fkey FOREIGN KEY (planilla_id) REFERENCES public.rrhh_planillas(id) ON DELETE CASCADE;


--
-- Name: rrhh_puestos rrhh_puestos_departamento_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_puestos
    ADD CONSTRAINT rrhh_puestos_departamento_id_fkey FOREIGN KEY (departamento_id) REFERENCES public.rrhh_departamentos(id);


--
-- Name: rrhh_vacaciones_movimientos rrhh_vacaciones_movimientos_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_vacaciones_movimientos
    ADD CONSTRAINT rrhh_vacaciones_movimientos_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_vacaciones_solicitudes rrhh_vacaciones_solicitudes_empleado_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_vacaciones_solicitudes
    ADD CONSTRAINT rrhh_vacaciones_solicitudes_empleado_id_fkey FOREIGN KEY (empleado_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: rrhh_vacaciones_solicitudes rrhh_vacaciones_solicitudes_jefe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rrhh_vacaciones_solicitudes
    ADD CONSTRAINT rrhh_vacaciones_solicitudes_jefe_id_fkey FOREIGN KEY (jefe_id) REFERENCES public.rrhh_empleados(id);


--
-- Name: sucursal_bodegas sucursal_bodegas_bodega_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sucursal_bodegas
    ADD CONSTRAINT sucursal_bodegas_bodega_id_fkey FOREIGN KEY (bodega_id) REFERENCES public.bodegas(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict TVrCVA9biMVdIffWRLnMiN4dXxDvkKcU4LAmvSzwb5jYSwYoxnx6X6EJbCBV7D6

