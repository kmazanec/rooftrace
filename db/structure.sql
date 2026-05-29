SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: postgis; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;


--
-- Name: EXTENSION postgis; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION postgis IS 'PostGIS geometry and geography spatial types and functions';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: capture_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.capture_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    job_id uuid NOT NULL,
    session_id character varying NOT NULL,
    manifest_version character varying NOT NULL,
    started_at timestamp(6) without time zone,
    ended_at timestamp(6) without time zone,
    gps_seed jsonb,
    device_info jsonb,
    world_mesh_ref character varying,
    world_mesh_vertex_count integer,
    raw_manifest jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: captures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.captures (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    capture_session_id uuid NOT NULL,
    sequence_index integer NOT NULL,
    prompt_label character varying,
    captured_at timestamp(6) without time zone,
    photo_ref character varying,
    depth_ref character varying,
    gps jsonb,
    attitude jsonb,
    camera_intrinsics jsonb,
    camera_extrinsics jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    address character varying DEFAULT ''::character varying NOT NULL,
    capture_token character varying NOT NULL,
    capture_token_expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    polygon_selection integer DEFAULT 0 NOT NULL,
    last_error character varying
);


--
-- Name: measurements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.measurements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    job_id uuid NOT NULL,
    footprint jsonb,
    roof_outline jsonb,
    lidar jsonb,
    facets jsonb DEFAULT '[]'::jsonb NOT NULL,
    features jsonb DEFAULT '[]'::jsonb NOT NULL,
    provenance jsonb DEFAULT '{}'::jsonb NOT NULL,
    total_area_sq_ft numeric,
    predominant_pitch_ratio numeric,
    source character varying NOT NULL,
    confidence numeric NOT NULL,
    warnings jsonb DEFAULT '[]'::jsonb NOT NULL,
    generated_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    total_perimeter_ft numeric,
    geocode jsonb,
    parcel_polygon jsonb,
    source_fingerprint character varying
);


--
-- Name: projected_overlays; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projected_overlays (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    capture_id uuid NOT NULL,
    composite_ref character varying,
    overlay_svg_ref character varying,
    pose_confidence double precision,
    low_pose_confidence boolean DEFAULT false NOT NULL,
    occluded_facet_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    job_id uuid,
    share_token character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: skeleton_pings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.skeleton_pings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    job_id character varying NOT NULL,
    rails_sent_at timestamp(6) without time zone NOT NULL,
    sidecar_received_at timestamp(6) without time zone NOT NULL,
    rails_received_at timestamp(6) without time zone NOT NULL,
    rtt_ms integer NOT NULL,
    sidecar_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: capture_sessions capture_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capture_sessions
    ADD CONSTRAINT capture_sessions_pkey PRIMARY KEY (id);


--
-- Name: captures captures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captures
    ADD CONSTRAINT captures_pkey PRIMARY KEY (id);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: measurements measurements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.measurements
    ADD CONSTRAINT measurements_pkey PRIMARY KEY (id);


--
-- Name: projected_overlays projected_overlays_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projected_overlays
    ADD CONSTRAINT projected_overlays_pkey PRIMARY KEY (id);


--
-- Name: reports reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: skeleton_pings skeleton_pings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.skeleton_pings
    ADD CONSTRAINT skeleton_pings_pkey PRIMARY KEY (id);


--
-- Name: index_capture_sessions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_capture_sessions_on_job_id ON public.capture_sessions USING btree (job_id);


--
-- Name: index_capture_sessions_on_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_capture_sessions_on_session_id ON public.capture_sessions USING btree (session_id);


--
-- Name: index_captures_on_capture_session_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captures_on_capture_session_id ON public.captures USING btree (capture_session_id);


--
-- Name: index_captures_on_session_and_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_captures_on_session_and_sequence ON public.captures USING btree (capture_session_id, sequence_index);


--
-- Name: index_jobs_on_capture_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_jobs_on_capture_token ON public.jobs USING btree (capture_token);


--
-- Name: index_jobs_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_jobs_on_status ON public.jobs USING btree (status);


--
-- Name: index_measurements_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_measurements_on_job_id ON public.measurements USING btree (job_id);


--
-- Name: index_projected_overlays_on_capture_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_projected_overlays_on_capture_id ON public.projected_overlays USING btree (capture_id);


--
-- Name: index_reports_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_reports_on_job_id ON public.reports USING btree (job_id);


--
-- Name: index_reports_on_share_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_reports_on_share_token ON public.reports USING btree (share_token);


--
-- Name: index_skeleton_pings_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_skeleton_pings_on_job_id ON public.skeleton_pings USING btree (job_id);


--
-- Name: captures fk_rails_27305ce86a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captures
    ADD CONSTRAINT fk_rails_27305ce86a FOREIGN KEY (capture_session_id) REFERENCES public.capture_sessions(id);


--
-- Name: measurements fk_rails_8905da8dc1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.measurements
    ADD CONSTRAINT fk_rails_8905da8dc1 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: projected_overlays fk_rails_9db2ea878a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projected_overlays
    ADD CONSTRAINT fk_rails_9db2ea878a FOREIGN KEY (capture_id) REFERENCES public.captures(id);


--
-- Name: capture_sessions fk_rails_bdebe49608; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capture_sessions
    ADD CONSTRAINT fk_rails_bdebe49608 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- Name: reports fk_rails_cd41661fc4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT fk_rails_cd41661fc4 FOREIGN KEY (job_id) REFERENCES public.jobs(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260529170538'),
('20260529053959'),
('20260529032539'),
('20260529032538'),
('20260528230223'),
('20260528193151'),
('20260528183518'),
('20260528183512'),
('20260528141920'),
('20260528141919'),
('20260528021921'),
('20260528021908');

