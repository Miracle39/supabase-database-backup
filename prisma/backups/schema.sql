


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


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."generate_recurring_transaction"("p_recurring_id" bigint, "p_month" "date") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r public.recurring_transactions%rowtype;
  v_month date;
  v_last_day integer;
  v_day integer;
  v_target_date date;
  v_run_id bigint;
  v_transaction_id bigint;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_month := date_trunc('month', p_month)::date;

  select * into r
  from public.recurring_transactions
  where id = p_recurring_id
    and user_id = auth.uid();

  if not found then
    raise exception 'Recurring transaction not found';
  end if;

  if not r.active then
    return null;
  end if;

  v_last_day := extract(day from (v_month + interval '1 month - 1 day'))::integer;
  v_day := least(r.day_of_month, v_last_day);
  v_target_date := make_date(extract(year from v_month)::integer, extract(month from v_month)::integer, v_day);

  if v_target_date < r.start_date or (r.end_date is not null and v_target_date > r.end_date) then
    return null;
  end if;

  insert into public.recurring_transaction_runs (user_id, recurring_transaction_id, month)
  values (auth.uid(), r.id, v_month)
  on conflict (recurring_transaction_id, month) do nothing
  returning id into v_run_id;

  if v_run_id is null then
    return -1;
  end if;

  insert into public.transactions (
    user_id,
    transaction_date,
    type,
    category,
    amount,
    payment_method,
    note
  )
  values (
    auth.uid(),
    v_target_date,
    r.type,
    r.category,
    r.amount,
    r.payment_method,
    case
      when r.note is null or trim(r.note) = '' then 'Transaksi berulang: ' || r.name
      else r.note || ' • Transaksi berulang: ' || r.name
    end
  )
  returning id into v_transaction_id;

  update public.recurring_transaction_runs
  set transaction_id = v_transaction_id
  where id = v_run_id;

  return v_transaction_id;
end;
$$;


ALTER FUNCTION "public"."generate_recurring_transaction"("p_recurring_id" bigint, "p_month" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.profiles (id, username)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;

  perform public.seed_default_categories(new.id);
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."lookup_login_email"("p_username" "text") RETURNS "text"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select au.email
  from auth.users au
  join public.profiles p on p.id = au.id
  where lower(trim(p.username)) = lower(trim(p_username))
  limit 1;
$$;


ALTER FUNCTION "public"."lookup_login_email"("p_username" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."seed_default_categories"("target_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.categories (user_id, name) values
    (target_user_id, 'Gaji'),
    (target_user_id, 'Bonus'),
    (target_user_id, 'Makanan'),
    (target_user_id, 'Transportasi'),
    (target_user_id, 'Tagihan'),
    (target_user_id, 'Belanja'),
    (target_user_id, 'Hiburan'),
    (target_user_id, 'Kesehatan'),
    (target_user_id, 'Pendidikan'),
    (target_user_id, 'Investasi'),
    (target_user_id, 'Lainnya')
  on conflict (user_id, name) do nothing;
end;
$$;


ALTER FUNCTION "public"."seed_default_categories"("target_user_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."budgets" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "month" "date" NOT NULL,
    "category" "text" NOT NULL,
    "amount" numeric(14,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "budgets_amount_check" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "budgets_month_first_day" CHECK (("month" = ("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date"))
);


ALTER TABLE "public"."budgets" OWNER TO "postgres";


ALTER TABLE "public"."budgets" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."budgets_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."categories" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."categories" OWNER TO "postgres";


ALTER TABLE "public"."categories" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."categories_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."financial_goals" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "target_amount" numeric(14,2) NOT NULL,
    "saved_amount" numeric(14,2) DEFAULT 0 NOT NULL,
    "target_date" "date" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "financial_goals_name_not_blank" CHECK (("length"(TRIM(BOTH FROM "name")) >= 2)),
    CONSTRAINT "financial_goals_saved_amount_check" CHECK (("saved_amount" >= (0)::numeric)),
    CONSTRAINT "financial_goals_target_amount_check" CHECK (("target_amount" > (0)::numeric))
);


ALTER TABLE "public"."financial_goals" OWNER TO "postgres";


ALTER TABLE "public"."financial_goals" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."financial_goals_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "username" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recurring_transaction_runs" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "recurring_transaction_id" bigint NOT NULL,
    "month" "date" NOT NULL,
    "transaction_id" bigint,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "recurring_run_month_first_day" CHECK (("month" = ("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date"))
);


ALTER TABLE "public"."recurring_transaction_runs" OWNER TO "postgres";


ALTER TABLE "public"."recurring_transaction_runs" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."recurring_transaction_runs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."recurring_transactions" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "type" "text" NOT NULL,
    "category" "text" NOT NULL,
    "amount" numeric(14,2) NOT NULL,
    "payment_method" "text",
    "note" "text",
    "day_of_month" integer NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date",
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "recurring_date_range" CHECK ((("end_date" IS NULL) OR ("end_date" >= "start_date"))),
    CONSTRAINT "recurring_name_not_blank" CHECK (("length"(TRIM(BOTH FROM "name")) >= 2)),
    CONSTRAINT "recurring_transactions_amount_check" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "recurring_transactions_day_of_month_check" CHECK ((("day_of_month" >= 1) AND ("day_of_month" <= 31))),
    CONSTRAINT "recurring_transactions_type_check" CHECK (("type" = ANY (ARRAY['income'::"text", 'expense'::"text"])))
);


ALTER TABLE "public"."recurring_transactions" OWNER TO "postgres";


ALTER TABLE "public"."recurring_transactions" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."recurring_transactions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."transactions" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "transaction_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "type" "text" NOT NULL,
    "category" "text" NOT NULL,
    "amount" numeric(14,2) NOT NULL,
    "payment_method" "text",
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "transactions_amount_check" CHECK (("amount" > (0)::numeric)),
    CONSTRAINT "transactions_type_check" CHECK (("type" = ANY (ARRAY['income'::"text", 'expense'::"text"])))
);


ALTER TABLE "public"."transactions" OWNER TO "postgres";


ALTER TABLE "public"."transactions" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."transactions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."budgets"
    ADD CONSTRAINT "budgets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."budgets"
    ADD CONSTRAINT "budgets_user_month_category_unique" UNIQUE ("user_id", "month", "category");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_user_name_unique" UNIQUE ("user_id", "name");



ALTER TABLE ONLY "public"."financial_goals"
    ADD CONSTRAINT "financial_goals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."recurring_transaction_runs"
    ADD CONSTRAINT "recurring_run_unique" UNIQUE ("recurring_transaction_id", "month");



ALTER TABLE ONLY "public"."recurring_transaction_runs"
    ADD CONSTRAINT "recurring_transaction_runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recurring_transactions"
    ADD CONSTRAINT "recurring_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_pkey" PRIMARY KEY ("id");



CREATE INDEX "budgets_user_month_idx" ON "public"."budgets" USING "btree" ("user_id", "month");



CREATE INDEX "categories_user_name_idx" ON "public"."categories" USING "btree" ("user_id", "name");



CREATE INDEX "financial_goals_user_idx" ON "public"."financial_goals" USING "btree" ("user_id", "target_date");



CREATE INDEX "recurring_runs_user_month_idx" ON "public"."recurring_transaction_runs" USING "btree" ("user_id", "month");



CREATE INDEX "recurring_transactions_user_active_idx" ON "public"."recurring_transactions" USING "btree" ("user_id", "active", "day_of_month");



CREATE INDEX "transactions_user_date_idx" ON "public"."transactions" USING "btree" ("user_id", "transaction_date" DESC);



ALTER TABLE ONLY "public"."budgets"
    ADD CONSTRAINT "budgets_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."financial_goals"
    ADD CONSTRAINT "financial_goals_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."recurring_transaction_runs"
    ADD CONSTRAINT "recurring_transaction_runs_recurring_transaction_id_fkey" FOREIGN KEY ("recurring_transaction_id") REFERENCES "public"."recurring_transactions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."recurring_transaction_runs"
    ADD CONSTRAINT "recurring_transaction_runs_transaction_id_fkey" FOREIGN KEY ("transaction_id") REFERENCES "public"."transactions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."recurring_transaction_runs"
    ADD CONSTRAINT "recurring_transaction_runs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."recurring_transactions"
    ADD CONSTRAINT "recurring_transactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Users can delete their own budgets" ON "public"."budgets" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own categories" ON "public"."categories" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own financial goals" ON "public"."financial_goals" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own recurring transactions" ON "public"."recurring_transactions" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own transactions" ON "public"."transactions" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own budgets" ON "public"."budgets" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own categories" ON "public"."categories" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own financial goals" ON "public"."financial_goals" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own profile" ON "public"."profiles" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can insert their own recurring transactions" ON "public"."recurring_transactions" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own transactions" ON "public"."transactions" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own budgets" ON "public"."budgets" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own categories" ON "public"."categories" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own financial goals" ON "public"."financial_goals" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own profile" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "id")) WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can update their own recurring transactions" ON "public"."recurring_transactions" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own transactions" ON "public"."transactions" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own budgets" ON "public"."budgets" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own categories" ON "public"."categories" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own financial goals" ON "public"."financial_goals" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own profile" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view their own recurring runs" ON "public"."recurring_transaction_runs" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own recurring transactions" ON "public"."recurring_transactions" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own transactions" ON "public"."transactions" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."budgets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."financial_goals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recurring_transaction_runs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recurring_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transactions" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."generate_recurring_transaction"("p_recurring_id" bigint, "p_month" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_recurring_transaction"("p_recurring_id" bigint, "p_month" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_recurring_transaction"("p_recurring_id" bigint, "p_month" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."lookup_login_email"("p_username" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."lookup_login_email"("p_username" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."lookup_login_email"("p_username" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."lookup_login_email"("p_username" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."seed_default_categories"("target_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."seed_default_categories"("target_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."seed_default_categories"("target_user_id" "uuid") TO "service_role";


















GRANT ALL ON TABLE "public"."budgets" TO "anon";
GRANT ALL ON TABLE "public"."budgets" TO "authenticated";
GRANT ALL ON TABLE "public"."budgets" TO "service_role";



GRANT ALL ON SEQUENCE "public"."budgets_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."budgets_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."budgets_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."categories" TO "anon";
GRANT ALL ON TABLE "public"."categories" TO "authenticated";
GRANT ALL ON TABLE "public"."categories" TO "service_role";



GRANT ALL ON SEQUENCE "public"."categories_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."categories_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."categories_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."financial_goals" TO "anon";
GRANT ALL ON TABLE "public"."financial_goals" TO "authenticated";
GRANT ALL ON TABLE "public"."financial_goals" TO "service_role";



GRANT ALL ON SEQUENCE "public"."financial_goals_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."financial_goals_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."financial_goals_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."recurring_transaction_runs" TO "anon";
GRANT ALL ON TABLE "public"."recurring_transaction_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."recurring_transaction_runs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."recurring_transaction_runs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."recurring_transaction_runs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."recurring_transaction_runs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."recurring_transactions" TO "anon";
GRANT ALL ON TABLE "public"."recurring_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."recurring_transactions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."recurring_transactions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."recurring_transactions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."recurring_transactions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."transactions" TO "anon";
GRANT ALL ON TABLE "public"."transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."transactions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."transactions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."transactions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."transactions_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































