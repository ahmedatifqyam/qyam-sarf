-- ╔════════════════════════════════════════════════════════════╗
-- ║  ميزان القيم — بناء قاعدة البيانات من الصفر — الجزء ٣ من ٣
-- ║  المشغّلات والحماية والسياسات والصلاحيات والتخزين والمهام والإعدادات
-- ║  مستخرج آلياً من قاعدة التجربة في 16 نوفمبر 2026 — آمن للتكرار
-- ╚════════════════════════════════════════════════════════════╝
set check_function_bodies = off;

-- ═══ المشغّلات ═══
drop trigger if exists qy_bm_guard_trg on public.beneficiaries_master; CREATE TRIGGER qy_bm_guard_trg BEFORE DELETE OR UPDATE ON public.beneficiaries_master FOR EACH ROW EXECUTE FUNCTION qy_bm_guard();
drop trigger if exists trg_protect_budget_item on public.budget_items; CREATE TRIGGER trg_protect_budget_item BEFORE DELETE ON public.budget_items FOR EACH ROW EXECUTE FUNCTION prevent_protected_budget_item_delete();
drop trigger if exists qy_push_overrun_t on public.budget_overrun_log; CREATE TRIGGER qy_push_overrun_t AFTER INSERT ON public.budget_overrun_log FOR EACH ROW EXECUTE FUNCTION qy_push_overrun();
drop trigger if exists qy_ledger_lock_t on public.center_ledger; CREATE TRIGGER qy_ledger_lock_t BEFORE INSERT OR UPDATE OF center_id, entry_date ON public.center_ledger FOR EACH ROW EXECUTE FUNCTION qy_ledger_lock();
drop trigger if exists trg_company_petty_item on public.companies; CREATE TRIGGER trg_company_petty_item AFTER INSERT ON public.companies FOR EACH ROW EXECUTE FUNCTION on_company_created();
drop trigger if exists qy_custody_ins_guard_trg on public.custodies; CREATE TRIGGER qy_custody_ins_guard_trg BEFORE INSERT ON public.custodies FOR EACH ROW EXECUTE FUNCTION qy_custody_ins_guard();
drop trigger if exists qy_push_custody_t on public.custodies; CREATE TRIGGER qy_push_custody_t AFTER INSERT OR UPDATE OF status ON public.custodies FOR EACH ROW EXECUTE FUNCTION qy_push_custody();
drop trigger if exists trg_gateway_agent_guard on public.gateway_agents; CREATE TRIGGER trg_gateway_agent_guard BEFORE INSERT OR UPDATE ON public.gateway_agents FOR EACH ROW EXECUTE FUNCTION qy_gateway_agent_guard();
drop trigger if exists qy_push_pwreset_t on public.password_reset_requests; CREATE TRIGGER qy_push_pwreset_t AFTER INSERT ON public.password_reset_requests FOR EACH ROW EXECUTE FUNCTION qy_push_pwreset();
drop trigger if exists qy_att_limit_trg on public.qy_attachments; CREATE TRIGGER qy_att_limit_trg BEFORE INSERT ON public.qy_attachments FOR EACH ROW EXECUTE FUNCTION qy_att_limit();
drop trigger if exists qy_push_alert_t on public.qy_audit_alerts; CREATE TRIGGER qy_push_alert_t AFTER INSERT ON public.qy_audit_alerts FOR EACH ROW EXECUTE FUNCTION qy_push_alert();
drop trigger if exists qy_push_clientev_t on public.qy_client_events; CREATE TRIGGER qy_push_clientev_t AFTER INSERT ON public.qy_client_events FOR EACH ROW EXECUTE FUNCTION qy_push_clientev();
drop trigger if exists qy_handover_guard_t on public.qy_handovers; CREATE TRIGGER qy_handover_guard_t BEFORE INSERT OR UPDATE ON public.qy_handovers FOR EACH ROW EXECUTE FUNCTION qy_handover_guard();
drop trigger if exists recurring_templates_guard on public.recurring_templates; CREATE TRIGGER recurring_templates_guard BEFORE INSERT OR UPDATE ON public.recurring_templates FOR EACH ROW EXECUTE FUNCTION recurring_templates_guard();
drop trigger if exists qy_push_step_t on public.request_approval_steps; CREATE TRIGGER qy_push_step_t AFTER INSERT OR UPDATE OF status, activated_at ON public.request_approval_steps FOR EACH ROW EXECUTE FUNCTION qy_push_step();
drop trigger if exists qy_steps_ins_del_guard_trg on public.request_approval_steps; CREATE TRIGGER qy_steps_ins_del_guard_trg BEFORE INSERT OR DELETE ON public.request_approval_steps FOR EACH ROW EXECUTE FUNCTION qy_steps_ins_del_guard();
drop trigger if exists qy_steps_watch_trg on public.request_approval_steps; CREATE TRIGGER qy_steps_watch_trg BEFORE UPDATE ON public.request_approval_steps FOR EACH ROW EXECUTE FUNCTION qy_steps_watch();
drop trigger if exists qy_ben_guard_trg on public.request_beneficiaries; CREATE TRIGGER qy_ben_guard_trg BEFORE INSERT OR DELETE OR UPDATE ON public.request_beneficiaries FOR EACH ROW EXECUTE FUNCTION qy_ben_guard();
drop trigger if exists qy_history_stamp_trg on public.request_history; CREATE TRIGGER qy_history_stamp_trg BEFORE INSERT ON public.request_history FOR EACH ROW EXECUTE FUNCTION qy_history_stamp();
drop trigger if exists qy_push_hist_t on public.request_history; CREATE TRIGGER qy_push_hist_t AFTER INSERT ON public.request_history FOR EACH ROW EXECUTE FUNCTION qy_push_hist();
drop trigger if exists qy_center_freeze_t on public.requests; CREATE TRIGGER qy_center_freeze_t BEFORE UPDATE OF status ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_center_freeze();
drop trigger if exists qy_center_guard_t on public.requests; CREATE TRIGGER qy_center_guard_t BEFORE INSERT ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_center_guard();
drop trigger if exists qy_center_staff_guard_t on public.requests; CREATE TRIGGER qy_center_staff_guard_t BEFORE INSERT ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_center_staff_guard();
drop trigger if exists qy_custody_sync_trg on public.requests; CREATE TRIGGER qy_custody_sync_trg AFTER UPDATE OF status, is_cancelled, total_amount, budget_item_id ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_custody_sync();
drop trigger if exists qy_push_new_t on public.requests; CREATE TRIGGER qy_push_new_t AFTER INSERT ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_push_new();
drop trigger if exists qy_push_release_t on public.requests; CREATE TRIGGER qy_push_release_t AFTER UPDATE OF review_until ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_push_release();
drop trigger if exists qy_push_req_t on public.requests; CREATE TRIGGER qy_push_req_t AFTER UPDATE OF status, is_cancelled ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_push_req();
drop trigger if exists qy_push_review_del_t on public.requests; CREATE TRIGGER qy_push_review_del_t AFTER DELETE ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_push_review_del();
drop trigger if exists qy_requests_del_guard_trg on public.requests; CREATE TRIGGER qy_requests_del_guard_trg BEFORE DELETE ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_requests_del_guard();
drop trigger if exists qy_requests_guard_trg on public.requests; CREATE TRIGGER qy_requests_guard_trg BEFORE UPDATE ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_requests_guard();
drop trigger if exists qy_requests_ins_guard_trg on public.requests; CREATE TRIGGER qy_requests_ins_guard_trg BEFORE INSERT ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_requests_ins_guard();
drop trigger if exists qy_requests_type_lock_trg on public.requests; CREATE TRIGGER qy_requests_type_lock_trg BEFORE UPDATE OF request_type ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_requests_type_lock();
drop trigger if exists qy_requests_vcode_trg on public.requests; CREATE TRIGGER qy_requests_vcode_trg BEFORE INSERT OR UPDATE ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_requests_vcode();
drop trigger if exists qy_route_income_t on public.requests; CREATE TRIGGER qy_route_income_t AFTER UPDATE OF status ON public.requests FOR EACH ROW EXECUTE FUNCTION qy_route_income();
drop trigger if exists trg_qy_gl_block on public.transactions; CREATE TRIGGER trg_qy_gl_block BEFORE INSERT ON public.transactions FOR EACH ROW EXECUTE FUNCTION qy_gl_block_guard();
drop trigger if exists trg_transactions_after_reverse on public.transactions; CREATE TRIGGER trg_transactions_after_reverse AFTER INSERT ON public.transactions FOR EACH ROW EXECUTE FUNCTION transactions_after_reverse();
drop trigger if exists trg_transactions_no_delete on public.transactions; CREATE TRIGGER trg_transactions_no_delete BEFORE DELETE ON public.transactions FOR EACH ROW EXECUTE FUNCTION transactions_are_immutable();
drop trigger if exists trg_transactions_no_update on public.transactions; CREATE TRIGGER trg_transactions_no_update BEFORE UPDATE ON public.transactions FOR EACH ROW EXECUTE FUNCTION transactions_are_immutable();
drop trigger if exists trg_transactions_rules on public.transactions; CREATE TRIGGER trg_transactions_rules BEFORE INSERT ON public.transactions FOR EACH ROW EXECUTE FUNCTION transactions_rules();
drop trigger if exists trg_tx_request_guard on public.transactions; CREATE TRIGGER trg_tx_request_guard BEFORE INSERT ON public.transactions FOR EACH ROW EXECUTE FUNCTION qy_tx_request_guard();
drop trigger if exists qy_guard_users_trg on public.users; CREATE TRIGGER qy_guard_users_trg BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION qy_guard_users();
drop trigger if exists qy_owner_guard_t on public.users; CREATE TRIGGER qy_owner_guard_t BEFORE DELETE OR UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION qy_owner_guard();
drop trigger if exists qy_push_userchg_t on public.users; CREATE TRIGGER qy_push_userchg_t AFTER UPDATE OF role, is_suspended ON public.users FOR EACH ROW EXECUTE FUNCTION qy_push_userchg();
drop trigger if exists qy_users_custody_susp_trg on public.users; CREATE TRIGGER qy_users_custody_susp_trg BEFORE UPDATE OF is_suspended ON public.users FOR EACH ROW EXECUTE FUNCTION qy_users_custody_susp_guard();
drop trigger if exists users_keep_one_admin on public.users; CREATE TRIGGER users_keep_one_admin BEFORE DELETE OR UPDATE OF role ON public.users FOR EACH ROW EXECUTE FUNCTION users_keep_one_admin();
drop trigger if exists users_self_update_guard on public.users; CREATE TRIGGER users_self_update_guard BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION users_self_update_guard();

-- ═══ حماية الصفوف ═══
alter table public.app_settings enable row level security;
alter table public.beneficiaries_master enable row level security;
alter table public.bottom_bar_toggles enable row level security;
alter table public.budget_items enable row level security;
alter table public.budget_overrun_log enable row level security;
alter table public.budget_revenues enable row level security;
alter table public.center_access enable row level security;
alter table public.center_ledger enable row level security;
alter table public.center_ledger_payers enable row level security;
alter table public.centers enable row level security;
alter table public.client_contracts enable row level security;
alter table public.clients enable row level security;
alter table public.companies enable row level security;
alter table public.contract_prices enable row level security;
alter table public.custodies enable row level security;
alter table public.custody_balances enable row level security;
alter table public.custody_lines enable row level security;
alter table public.custom_roles enable row level security;
alter table public.gateway_accounts enable row level security;
alter table public.gateway_agents enable row level security;
alter table public.gateway_import_users enable row level security;
alter table public.gateway_imports enable row level security;
alter table public.gl_accounts enable row level security;
alter table public.gl_custody_accounts enable row level security;
alter table public.gl_exports enable row level security;
alter table public.job_levels enable row level security;
alter table public.login_aliases enable row level security;
alter table public.org_departments enable row level security;
alter table public.organizations enable row level security;
alter table public.page_permissions enable row level security;
alter table public.password_reset_requests enable row level security;
alter table public.prj_collections enable row level security;
alter table public.prj_documents enable row level security;
alter table public.prj_invoices enable row level security;
alter table public.projects enable row level security;
alter table public.push_config enable row level security;
alter table public.push_outbox enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.qy_attachments enable row level security;
alter table public.qy_audit_alerts enable row level security;
alter table public.qy_client_events enable row level security;
alter table public.qy_handovers enable row level security;
alter table public.qy_verify_hits enable row level security;
alter table public.recurring_occurrences enable row level security;
alter table public.recurring_settings enable row level security;
alter table public.recurring_templates enable row level security;
alter table public.request_approval_steps enable row level security;
alter table public.request_beneficiaries enable row level security;
alter table public.request_history enable row level security;
alter table public.request_number_counters enable row level security;
alter table public.requests enable row level security;
alter table public.signature_layout_configs enable row level security;
alter table public.svc_catalog enable row level security;
alter table public.transactions enable row level security;
alter table public.user_companies enable row level security;
alter table public.user_company_managers enable row level security;
alter table public.users enable row level security;
alter table public.worker_contracts enable row level security;

-- ═══ السياسات ═══
drop policy if exists qy_settings_lists_ins on public.app_settings; create policy qy_settings_lists_ins on public.app_settings as PERMISSIVE for INSERT to authenticated with check ((key = ANY (ARRAY['rec_categories'::text, 'unit_types'::text])));
drop policy if exists qy_settings_lists_upd on public.app_settings; create policy qy_settings_lists_upd on public.app_settings as PERMISSIVE for UPDATE to authenticated using ((key = ANY (ARRAY['rec_categories'::text, 'unit_types'::text]))) with check ((key = ANY (ARRAY['rec_categories'::text, 'unit_types'::text])));
drop policy if exists qyam_sel_app_settings on public.app_settings; create policy qyam_sel_app_settings on public.app_settings as PERMISSIVE for SELECT to authenticated using (true);
drop policy if exists qyam_wrt_app_settings on public.app_settings; create policy qyam_wrt_app_settings on public.app_settings as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists qyam_sel_beneficiaries on public.beneficiaries_master; create policy qyam_sel_beneficiaries on public.beneficiaries_master as PERMISSIVE for SELECT to authenticated using (((company_id IS NULL) OR can_see_company(company_id)));
drop policy if exists qyam_wrt_beneficiaries on public.beneficiaries_master; create policy qyam_wrt_beneficiaries on public.beneficiaries_master as PERMISSIVE for ALL to authenticated using (can_see_company(company_id)) with check (can_see_company(company_id));
drop policy if exists qyam_sel_bar on public.bottom_bar_toggles; create policy qyam_sel_bar on public.bottom_bar_toggles as PERMISSIVE for SELECT to authenticated using (true);
drop policy if exists qyam_wrt_bar on public.bottom_bar_toggles; create policy qyam_wrt_bar on public.bottom_bar_toggles as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists qy_budget_items_ins on public.budget_items; create policy qy_budget_items_ins on public.budget_items as PERMISSIVE for INSERT to authenticated with check (can_see_company(company_id));
drop policy if exists qyam_sel_budget_items on public.budget_items; create policy qyam_sel_budget_items on public.budget_items as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists qyam_wrt_budget_items on public.budget_items; create policy qyam_wrt_budget_items on public.budget_items as PERMISSIVE for ALL to authenticated using ((can_see_company(company_id) AND is_finance())) with check ((can_see_company(company_id) AND is_finance()));
drop policy if exists qyam_ins_overrun on public.budget_overrun_log; create policy qyam_ins_overrun on public.budget_overrun_log as PERMISSIVE for INSERT to authenticated with check (can_see_request(request_id));
drop policy if exists qyam_sel_overrun on public.budget_overrun_log; create policy qyam_sel_overrun on public.budget_overrun_log as PERMISSIVE for SELECT to authenticated using (can_see_request(request_id));
drop policy if exists qyam_del_budget_rev on public.budget_revenues; create policy qyam_del_budget_rev on public.budget_revenues as PERMISSIVE for DELETE to authenticated using ((is_finance() AND (EXISTS ( SELECT 1
   FROM budget_items b
  WHERE ((b.id = budget_revenues.budget_item_id) AND can_see_company(b.company_id))))));
drop policy if exists qyam_ins_budget_rev on public.budget_revenues; create policy qyam_ins_budget_rev on public.budget_revenues as PERMISSIVE for INSERT to authenticated with check ((is_finance() AND (EXISTS ( SELECT 1
   FROM budget_items b
  WHERE ((b.id = budget_revenues.budget_item_id) AND can_see_company(b.company_id))))));
drop policy if exists qyam_sel_budget_rev on public.budget_revenues; create policy qyam_sel_budget_rev on public.budget_revenues as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM budget_items b
  WHERE ((b.id = budget_revenues.budget_item_id) AND can_see_company(b.company_id)))));
drop policy if exists qyam_upd_budget_rev on public.budget_revenues; create policy qyam_upd_budget_rev on public.budget_revenues as PERMISSIVE for UPDATE to authenticated using ((is_finance() AND (EXISTS ( SELECT 1
   FROM budget_items b
  WHERE ((b.id = budget_revenues.budget_item_id) AND can_see_company(b.company_id)))))) with check ((is_finance() AND (EXISTS ( SELECT 1
   FROM budget_items b
  WHERE ((b.id = budget_revenues.budget_item_id) AND can_see_company(b.company_id))))));
drop policy if exists center_access_sel on public.center_access; create policy center_access_sel on public.center_access as PERMISSIVE for SELECT to authenticated using ((is_admin() OR (user_id = qy_me())));
drop policy if exists center_access_wrt on public.center_access; create policy center_access_wrt on public.center_access as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists cl_sel on public.center_ledger; create policy cl_sel on public.center_ledger as PERMISSIVE for SELECT to authenticated using (
CASE
    WHEN (center_id IS NULL) THEN qy_can_import(company_id)
    ELSE qy_center_can_see(center_id)
END);
drop policy if exists clp_sel on public.center_ledger_payers; create policy clp_sel on public.center_ledger_payers as PERMISSIVE for SELECT to authenticated using (qy_can_import(company_id));
drop policy if exists qy_centers_add_visible on public.centers; create policy qy_centers_add_visible on public.centers as PERMISSIVE for INSERT to authenticated with check (can_see_company(company_id));
drop policy if exists qyam_sel_centers on public.centers; create policy qyam_sel_centers on public.centers as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists qyam_wrt_centers on public.centers; create policy qyam_wrt_centers on public.centers as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists client_contracts_sel on public.client_contracts; create policy client_contracts_sel on public.client_contracts as PERMISSIVE for SELECT to authenticated using (qy_prj_can_read(company_id));
drop policy if exists client_contracts_wrt on public.client_contracts; create policy client_contracts_wrt on public.client_contracts as PERMISSIVE for ALL to authenticated using (qy_prj_can_write(company_id)) with check (qy_prj_can_write(company_id));
drop policy if exists clients_all on public.clients; create policy clients_all on public.clients as PERMISSIVE for ALL to authenticated using ((is_finance() AND can_see_company(company_id))) with check ((is_finance() AND can_see_company(company_id)));
drop policy if exists clients_sel on public.clients; create policy clients_sel on public.clients as PERMISSIVE for SELECT to authenticated using (((party <> 'client'::text) AND can_see_company(company_id) AND qy_page_level_ok(company_id, 'suppliers'::text, ARRAY['read'::text, 'edit'::text, 'full'::text])));
drop policy if exists clients_sup_del on public.clients; create policy clients_sup_del on public.clients as PERMISSIVE for DELETE to authenticated using (((party = 'supplier'::text) AND can_see_company(company_id) AND qy_page_level_ok(company_id, 'suppliers'::text, ARRAY['full'::text])));
drop policy if exists clients_sup_ins on public.clients; create policy clients_sup_ins on public.clients as PERMISSIVE for INSERT to authenticated with check (((party = 'supplier'::text) AND can_see_company(company_id) AND qy_page_level_ok(company_id, 'suppliers'::text, ARRAY['edit'::text, 'full'::text])));
drop policy if exists clients_sup_upd on public.clients; create policy clients_sup_upd on public.clients as PERMISSIVE for UPDATE to authenticated using (((party = 'supplier'::text) AND can_see_company(company_id) AND qy_page_level_ok(company_id, 'suppliers'::text, ARRAY['edit'::text, 'full'::text]))) with check (((party = 'supplier'::text) AND can_see_company(company_id) AND qy_page_level_ok(company_id, 'suppliers'::text, ARRAY['edit'::text, 'full'::text])));
drop policy if exists qyam_sel_companies on public.companies; create policy qyam_sel_companies on public.companies as PERMISSIVE for SELECT to authenticated using (can_see_company(id));
drop policy if exists qyam_wrt_companies on public.companies; create policy qyam_wrt_companies on public.companies as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists contract_prices_sel on public.contract_prices; create policy contract_prices_sel on public.contract_prices as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM client_contracts c
  WHERE ((c.id = contract_prices.contract_id) AND qy_prj_can_read(c.company_id)))));
drop policy if exists contract_prices_wrt on public.contract_prices; create policy contract_prices_wrt on public.contract_prices as PERMISSIVE for ALL to authenticated using ((EXISTS ( SELECT 1
   FROM client_contracts c
  WHERE ((c.id = contract_prices.contract_id) AND qy_prj_can_write(c.company_id))))) with check ((EXISTS ( SELECT 1
   FROM client_contracts c
  WHERE ((c.id = contract_prices.contract_id) AND qy_prj_can_write(c.company_id)))));
drop policy if exists qy_cust_ins on public.custodies; create policy qy_cust_ins on public.custodies as PERMISSIVE for INSERT to authenticated with check ((EXISTS ( SELECT 1
   FROM requests r
  WHERE ((r.id = custodies.request_id) AND (r.request_type = 'custody'::text) AND ((r.created_by_id = qy_me()) OR is_admin())))));
drop policy if exists qy_cust_sel on public.custodies; create policy qy_cust_sel on public.custodies as PERMISSIVE for SELECT to authenticated using (((holder_id = qy_me()) OR (created_by_id = qy_me()) OR (reviewer_id = qy_me()) OR is_admin() OR (is_finance() AND can_see_company(company_id)) OR can_see_request(request_id)));
drop policy if exists qy_cbal_sel on public.custody_balances; create policy qy_cbal_sel on public.custody_balances as PERMISSIVE for SELECT to authenticated using (((holder_id = qy_me()) OR is_admin() OR (is_finance() AND can_see_company(company_id))));
drop policy if exists qy_cline_sel on public.custody_lines; create policy qy_cline_sel on public.custody_lines as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM custodies k
  WHERE ((k.id = custody_lines.custody_id) AND ((k.holder_id = qy_me()) OR (k.created_by_id = qy_me()) OR (k.reviewer_id = qy_me()) OR is_admin() OR (is_finance() AND can_see_company(k.company_id)) OR can_see_request(k.request_id))))));
drop policy if exists qyam_sel_custom_roles on public.custom_roles; create policy qyam_sel_custom_roles on public.custom_roles as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists qyam_wrt_custom_roles on public.custom_roles; create policy qyam_wrt_custom_roles on public.custom_roles as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists gwa_all on public.gateway_accounts; create policy gwa_all on public.gateway_accounts as PERMISSIVE for ALL to authenticated using (qy_can_import(company_id)) with check ((is_admin() OR is_finance()));
drop policy if exists gwg_all on public.gateway_agents; create policy gwg_all on public.gateway_agents as PERMISSIVE for ALL to authenticated using (qy_can_import(company_id)) with check (qy_can_import(company_id));
drop policy if exists giu_sel on public.gateway_import_users; create policy giu_sel on public.gateway_import_users as PERMISSIVE for SELECT to authenticated using ((is_admin() OR is_finance() OR (user_id = qy_me())));
drop policy if exists giu_wrt on public.gateway_import_users; create policy giu_wrt on public.gateway_import_users as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists gwi_sel on public.gateway_imports; create policy gwi_sel on public.gateway_imports as PERMISSIVE for SELECT to authenticated using (qy_can_import(company_id));
drop policy if exists gl_acc_sel on public.gl_accounts; create policy gl_acc_sel on public.gl_accounts as PERMISSIVE for SELECT to authenticated using ((is_admin() OR (is_finance() AND can_see_company(company_id))));
drop policy if exists gl_cust_sel on public.gl_custody_accounts; create policy gl_cust_sel on public.gl_custody_accounts as PERMISSIVE for SELECT to authenticated using ((is_admin() OR (is_finance() AND can_see_company(company_id))));
drop policy if exists gl_exp_sel on public.gl_exports; create policy gl_exp_sel on public.gl_exports as PERMISSIVE for SELECT to authenticated using ((is_admin() OR (is_finance() AND can_see_company(company_id))));
drop policy if exists qyam_sel_job_levels on public.job_levels; create policy qyam_sel_job_levels on public.job_levels as PERMISSIVE for SELECT to authenticated using (((company_id IS NULL) OR can_see_company(company_id)));
drop policy if exists qyam_wrt_job_levels on public.job_levels; create policy qyam_wrt_job_levels on public.job_levels as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists login_aliases_admin_read on public.login_aliases; create policy login_aliases_admin_read on public.login_aliases as PERMISSIVE for SELECT to authenticated using (is_admin());
drop policy if exists org_departments_sel on public.org_departments; create policy org_departments_sel on public.org_departments as PERMISSIVE for SELECT to authenticated using (true);
drop policy if exists org_departments_wrt on public.org_departments; create policy org_departments_wrt on public.org_departments as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists qyam_sel_orgs on public.organizations; create policy qyam_sel_orgs on public.organizations as PERMISSIVE for SELECT to authenticated using (true);
drop policy if exists qyam_wrt_orgs on public.organizations; create policy qyam_wrt_orgs on public.organizations as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists pp_del on public.page_permissions; create policy pp_del on public.page_permissions as PERMISSIVE for DELETE to authenticated using ((is_admin() AND can_see_company(company_id)));
drop policy if exists pp_ins on public.page_permissions; create policy pp_ins on public.page_permissions as PERMISSIVE for INSERT to authenticated with check ((is_admin() AND can_see_company(company_id)));
drop policy if exists pp_sel on public.page_permissions; create policy pp_sel on public.page_permissions as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists pp_upd on public.page_permissions; create policy pp_upd on public.page_permissions as PERMISSIVE for UPDATE to authenticated using ((is_admin() AND can_see_company(company_id))) with check ((is_admin() AND can_see_company(company_id)));
drop policy if exists qyam_sel_prr on public.password_reset_requests; create policy qyam_sel_prr on public.password_reset_requests as PERMISSIVE for SELECT to authenticated using (is_admin());
drop policy if exists qyam_upd_prr on public.password_reset_requests; create policy qyam_upd_prr on public.password_reset_requests as PERMISSIVE for UPDATE to authenticated using (is_admin()) with check (is_admin());
drop policy if exists prj_collections_sel on public.prj_collections; create policy prj_collections_sel on public.prj_collections as PERMISSIVE for SELECT to authenticated using (qy_prj_can_read(company_id));
drop policy if exists prj_collections_wrt on public.prj_collections; create policy prj_collections_wrt on public.prj_collections as PERMISSIVE for ALL to authenticated using ((is_finance() AND can_see_company(company_id))) with check ((is_finance() AND can_see_company(company_id)));
drop policy if exists prj_documents_sel on public.prj_documents; create policy prj_documents_sel on public.prj_documents as PERMISSIVE for SELECT to authenticated using (qy_prj_can_read(company_id));
drop policy if exists prj_documents_wrt on public.prj_documents; create policy prj_documents_wrt on public.prj_documents as PERMISSIVE for ALL to authenticated using (qy_prj_can_write(company_id)) with check (qy_prj_can_write(company_id));
drop policy if exists prj_invoices_sel on public.prj_invoices; create policy prj_invoices_sel on public.prj_invoices as PERMISSIVE for SELECT to authenticated using (qy_prj_can_read(company_id));
drop policy if exists prj_invoices_wrt on public.prj_invoices; create policy prj_invoices_wrt on public.prj_invoices as PERMISSIVE for ALL to authenticated using (qy_prj_can_write(company_id)) with check (qy_prj_can_write(company_id));
drop policy if exists projects_sel on public.projects; create policy projects_sel on public.projects as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists projects_wrt on public.projects; create policy projects_wrt on public.projects as PERMISSIVE for ALL to authenticated using (qy_prj_can_write(company_id)) with check (qy_prj_can_write(company_id));
drop policy if exists push_subs_select on public.push_subscriptions; create policy push_subs_select on public.push_subscriptions as PERMISSIVE for SELECT to authenticated using ((user_id = qy_me()));
drop policy if exists qy_att_del on public.qy_attachments; create policy qy_att_del on public.qy_attachments as PERMISSIVE for DELETE to authenticated using ((can_see_company(company_id) AND ((created_by = auth.uid()) OR is_finance())));
drop policy if exists qy_att_ins on public.qy_attachments; create policy qy_att_ins on public.qy_attachments as PERMISSIVE for INSERT to authenticated with check ((can_see_company(company_id) AND (EXISTS ( SELECT 1
   FROM beneficiaries_master m
  WHERE ((m.id = qy_attachments.master_id) AND (m.company_id = qy_attachments.company_id)))) AND (path ~~ (((company_id || '/'::text) || (master_id)::text) || '/%'::text))));
drop policy if exists qy_att_sel on public.qy_attachments; create policy qy_att_sel on public.qy_attachments as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists qy_audit_alerts_admin_del on public.qy_audit_alerts; create policy qy_audit_alerts_admin_del on public.qy_audit_alerts as PERMISSIVE for DELETE to authenticated using (is_admin());
drop policy if exists qy_audit_alerts_admin_sel on public.qy_audit_alerts; create policy qy_audit_alerts_admin_sel on public.qy_audit_alerts as PERMISSIVE for SELECT to authenticated using (is_admin());
drop policy if exists qy_audit_alerts_admin_upd on public.qy_audit_alerts; create policy qy_audit_alerts_admin_upd on public.qy_audit_alerts as PERMISSIVE for UPDATE to authenticated using (is_admin()) with check (is_admin());
drop policy if exists qy_client_events_admin_del on public.qy_client_events; create policy qy_client_events_admin_del on public.qy_client_events as PERMISSIVE for DELETE to authenticated using (is_admin());
drop policy if exists qy_client_events_admin_sel on public.qy_client_events; create policy qy_client_events_admin_sel on public.qy_client_events as PERMISSIVE for SELECT to authenticated using (is_admin());
drop policy if exists qy_client_events_admin_upd on public.qy_client_events; create policy qy_client_events_admin_upd on public.qy_client_events as PERMISSIVE for UPDATE to authenticated using (is_admin()) with check (is_admin());
drop policy if exists qy_ho_ins on public.qy_handovers; create policy qy_ho_ins on public.qy_handovers as PERMISSIVE for INSERT to authenticated with check (can_see_company(company_id));
drop policy if exists qy_ho_sel on public.qy_handovers; create policy qy_ho_sel on public.qy_handovers as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists qy_ho_upd on public.qy_handovers; create policy qy_ho_upd on public.qy_handovers as PERMISSIVE for UPDATE to authenticated using (can_see_company(company_id)) with check (can_see_company(company_id));
drop policy if exists ro_sel on public.recurring_occurrences; create policy ro_sel on public.recurring_occurrences as PERMISSIVE for SELECT to authenticated using ((EXISTS ( SELECT 1
   FROM recurring_templates t
  WHERE (t.id = recurring_occurrences.template_id))));
drop policy if exists rs_ins on public.recurring_settings; create policy rs_ins on public.recurring_settings as PERMISSIVE for INSERT to authenticated with check ((is_admin() AND can_see_company(company_id)));
drop policy if exists rs_sel on public.recurring_settings; create policy rs_sel on public.recurring_settings as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists rs_upd on public.recurring_settings; create policy rs_upd on public.recurring_settings as PERMISSIVE for UPDATE to authenticated using ((is_admin() AND can_see_company(company_id))) with check ((is_admin() AND can_see_company(company_id)));
drop policy if exists rt_del on public.recurring_templates; create policy rt_del on public.recurring_templates as PERMISSIVE for DELETE to authenticated using (((status = 'pending_approval'::text) AND can_manage_recurring() AND can_see_company(company_id) AND ((created_by_id = my_user_id()) OR is_admin())));
drop policy if exists rt_ins on public.recurring_templates; create policy rt_ins on public.recurring_templates as PERMISSIVE for INSERT to authenticated with check ((can_manage_recurring() AND can_see_company(company_id)));
drop policy if exists rt_sel on public.recurring_templates; create policy rt_sel on public.recurring_templates as PERMISSIVE for SELECT to authenticated using (((is_finance() AND can_see_company(company_id)) OR (created_by_id = my_user_id()) OR (my_user_id() = ANY (notify_user_ids)) OR (my_user_id() = ANY (COALESCE(approval_notify_user_ids, '{}'::text[])))));
drop policy if exists rt_upd on public.recurring_templates; create policy rt_upd on public.recurring_templates as PERMISSIVE for UPDATE to authenticated using ((can_manage_recurring() AND can_see_company(company_id) AND ((created_by_id = my_user_id()) OR is_finance()))) with check ((can_manage_recurring() AND can_see_company(company_id)));
drop policy if exists qyam_sel_req_steps on public.request_approval_steps; create policy qyam_sel_req_steps on public.request_approval_steps as PERMISSIVE for SELECT to authenticated using (can_see_request(request_id));
drop policy if exists qyam_wrt_req_steps on public.request_approval_steps; create policy qyam_wrt_req_steps on public.request_approval_steps as PERMISSIVE for ALL to authenticated using (can_see_request(request_id)) with check (can_see_request(request_id));
drop policy if exists qyam_sel_req_ben on public.request_beneficiaries; create policy qyam_sel_req_ben on public.request_beneficiaries as PERMISSIVE for SELECT to authenticated using (can_see_request(request_id));
drop policy if exists qyam_wrt_req_ben on public.request_beneficiaries; create policy qyam_wrt_req_ben on public.request_beneficiaries as PERMISSIVE for ALL to authenticated using (can_see_request(request_id)) with check (can_see_request(request_id));
drop policy if exists qyam_ins_req_hist on public.request_history; create policy qyam_ins_req_hist on public.request_history as PERMISSIVE for INSERT to authenticated with check (can_see_request(request_id));
drop policy if exists qyam_sel_req_hist on public.request_history; create policy qyam_sel_req_hist on public.request_history as PERMISSIVE for SELECT to authenticated using (can_see_request(request_id));
drop policy if exists qy_sel_requests_own on public.requests; create policy qy_sel_requests_own on public.requests as PERMISSIVE for SELECT to authenticated using ((created_by_id = qy_me()));
drop policy if exists qy_upd_requests_own on public.requests; create policy qy_upd_requests_own on public.requests as PERMISSIVE for UPDATE to authenticated using ((created_by_id = qy_me())) with check ((created_by_id = qy_me()));
drop policy if exists qyam_sel_requests on public.requests; create policy qyam_sel_requests on public.requests as PERMISSIVE for SELECT to authenticated using (can_see_request(id));
drop policy if exists qyam_wrt_requests on public.requests; create policy qyam_wrt_requests on public.requests as PERMISSIVE for ALL to authenticated using (can_see_request(id)) with check (can_see_company(company_id));
drop policy if exists qyam_sel_siglayout on public.signature_layout_configs; create policy qyam_sel_siglayout on public.signature_layout_configs as PERMISSIVE for SELECT to authenticated using (true);
drop policy if exists qyam_wrt_siglayout on public.signature_layout_configs; create policy qyam_wrt_siglayout on public.signature_layout_configs as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists svc_catalog_sel on public.svc_catalog; create policy svc_catalog_sel on public.svc_catalog as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists svc_catalog_wrt on public.svc_catalog; create policy svc_catalog_wrt on public.svc_catalog as PERMISSIVE for ALL to authenticated using ((is_finance() AND can_see_company(company_id))) with check ((is_finance() AND can_see_company(company_id)));
drop policy if exists qyam_ins_transactions on public.transactions; create policy qyam_ins_transactions on public.transactions as PERMISSIVE for INSERT to authenticated with check ((is_finance() AND can_see_company(company_id)));
drop policy if exists qyam_sel_transactions on public.transactions; create policy qyam_sel_transactions on public.transactions as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists qyam_sel_user_companies on public.user_companies; create policy qyam_sel_user_companies on public.user_companies as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists qyam_wrt_user_companies on public.user_companies; create policy qyam_wrt_user_companies on public.user_companies as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists qyam_sel_ucm on public.user_company_managers; create policy qyam_sel_ucm on public.user_company_managers as PERMISSIVE for SELECT to authenticated using (can_see_company(company_id));
drop policy if exists qyam_wrt_ucm on public.user_company_managers; create policy qyam_wrt_ucm on public.user_company_managers as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists qyam_sel_users on public.users; create policy qyam_sel_users on public.users as PERMISSIVE for SELECT to authenticated using ((can_see_company(company_id) OR (auth_id = auth.uid()) OR (is_general = true)));
drop policy if exists qyam_upd_self on public.users; create policy qyam_upd_self on public.users as PERMISSIVE for UPDATE to authenticated using ((auth_id = auth.uid())) with check ((auth_id = auth.uid()));
drop policy if exists qyam_wrt_users on public.users; create policy qyam_wrt_users on public.users as PERMISSIVE for ALL to authenticated using (is_admin()) with check (is_admin());
drop policy if exists worker_contracts_sel on public.worker_contracts; create policy worker_contracts_sel on public.worker_contracts as PERMISSIVE for SELECT to authenticated using ((can_see_company(company_id) AND (is_finance() OR qy_page_level_ok(company_id, 'contracts'::text, ARRAY['read'::text, 'edit'::text, 'full'::text]))));
drop policy if exists worker_contracts_sel_center on public.worker_contracts; create policy worker_contracts_sel_center on public.worker_contracts as PERMISSIVE for SELECT to authenticated using (((status = 'active'::text) AND (unit_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM (users u
     LEFT JOIN centers cu ON ((cu.id = u.center_id)))
  WHERE ((u.id = qy_me()) AND ((u.center_id = worker_contracts.unit_id) OR (cu.parent_id = worker_contracts.unit_id)))))));
drop policy if exists worker_contracts_wrt on public.worker_contracts; create policy worker_contracts_wrt on public.worker_contracts as PERMISSIVE for ALL to authenticated using ((can_see_company(company_id) AND (is_finance() OR qy_page_level_ok(company_id, 'contracts'::text, ARRAY['edit'::text, 'full'::text])))) with check ((can_see_company(company_id) AND (is_finance() OR qy_page_level_ok(company_id, 'contracts'::text, ARRAY['edit'::text, 'full'::text]))));
drop policy if exists qy_att_obj_del on storage.objects; create policy qy_att_obj_del on storage.objects as PERMISSIVE for DELETE to authenticated using (((bucket_id = 'attachments'::text) AND can_see_company((storage.foldername(name))[1]) AND ((owner_id = (auth.uid())::text) OR is_finance())));
drop policy if exists qy_att_obj_ins on storage.objects; create policy qy_att_obj_ins on storage.objects as PERMISSIVE for INSERT to authenticated with check (((bucket_id = 'attachments'::text) AND can_see_company((storage.foldername(name))[1])));
drop policy if exists qy_att_obj_sel on storage.objects; create policy qy_att_obj_sel on storage.objects as PERMISSIVE for SELECT to authenticated using (((bucket_id = 'attachments'::text) AND can_see_company((storage.foldername(name))[1])));

-- ═══ صلاحيات الجداول ═══
revoke all on public.app_settings from anon, authenticated;
revoke all on public.beneficiaries_master from anon, authenticated;
revoke all on public.beneficiaries_master_id_seq from anon, authenticated;
revoke all on public.bottom_bar_toggles from anon, authenticated;
revoke all on public.budget_items from anon, authenticated;
revoke all on public.budget_overrun_log from anon, authenticated;
revoke all on public.budget_revenues from anon, authenticated;
revoke all on public.center_access from anon, authenticated;
revoke all on public.center_ledger from anon, authenticated;
revoke all on public.center_ledger_id_seq from anon, authenticated;
revoke all on public.center_ledger_payers from anon, authenticated;
revoke all on public.centers from anon, authenticated;
revoke all on public.client_contracts from anon, authenticated;
revoke all on public.clients from anon, authenticated;
revoke all on public.companies from anon, authenticated;
revoke all on public.contract_prices from anon, authenticated;
revoke all on public.custodies from anon, authenticated;
revoke all on public.custodies_id_seq from anon, authenticated;
revoke all on public.custody_balances from anon, authenticated;
revoke all on public.custody_balances_id_seq from anon, authenticated;
revoke all on public.custody_lines from anon, authenticated;
revoke all on public.custody_lines_id_seq from anon, authenticated;
revoke all on public.custom_roles from anon, authenticated;
revoke all on public.gateway_accounts from anon, authenticated;
revoke all on public.gateway_agents from anon, authenticated;
revoke all on public.gateway_agents_id_seq from anon, authenticated;
revoke all on public.gateway_import_users from anon, authenticated;
revoke all on public.gateway_imports from anon, authenticated;
revoke all on public.gateway_imports_id_seq from anon, authenticated;
revoke all on public.gl_accounts from anon, authenticated;
revoke all on public.gl_custody_accounts from anon, authenticated;
revoke all on public.gl_exports from anon, authenticated;
revoke all on public.gl_exports_id_seq from anon, authenticated;
revoke all on public.job_levels from anon, authenticated;
revoke all on public.login_aliases from anon, authenticated;
revoke all on public.org_departments from anon, authenticated;
revoke all on public.organizations from anon, authenticated;
revoke all on public.page_permissions from anon, authenticated;
revoke all on public.password_reset_requests from anon, authenticated;
revoke all on public.prj_collections from anon, authenticated;
revoke all on public.prj_documents from anon, authenticated;
revoke all on public.prj_invoices from anon, authenticated;
revoke all on public.projects from anon, authenticated;
revoke all on public.push_config from anon, authenticated;
revoke all on public.push_outbox from anon, authenticated;
revoke all on public.push_outbox_id_seq from anon, authenticated;
revoke all on public.push_subscriptions from anon, authenticated;
revoke all on public.qy_attachments from anon, authenticated;
revoke all on public.qy_audit_alerts from anon, authenticated;
revoke all on public.qy_audit_alerts_id_seq from anon, authenticated;
revoke all on public.qy_client_events from anon, authenticated;
revoke all on public.qy_client_events_id_seq from anon, authenticated;
revoke all on public.qy_handovers from anon, authenticated;
revoke all on public.qy_verify_hits from anon, authenticated;
revoke all on public.recurring_occurrences from anon, authenticated;
revoke all on public.recurring_settings from anon, authenticated;
revoke all on public.recurring_templates from anon, authenticated;
revoke all on public.request_approval_steps from anon, authenticated;
revoke all on public.request_beneficiaries from anon, authenticated;
revoke all on public.request_beneficiaries_id_seq from anon, authenticated;
revoke all on public.request_history from anon, authenticated;
revoke all on public.request_history_id_seq from anon, authenticated;
revoke all on public.request_number_counters from anon, authenticated;
revoke all on public.requests from anon, authenticated;
revoke all on public.signature_layout_configs from anon, authenticated;
revoke all on public.svc_catalog from anon, authenticated;
revoke all on public.transactions from anon, authenticated;
revoke all on public.user_companies from anon, authenticated;
revoke all on public.user_company_managers from anon, authenticated;
revoke all on public.users from anon, authenticated;
revoke all on public.worker_contracts from anon, authenticated;
grant TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT, INSERT on public.app_settings to anon;
grant INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER on public.app_settings to authenticated;
grant TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT, INSERT on public.beneficiaries_master to anon;
grant SELECT, INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE on public.beneficiaries_master to authenticated;
grant SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, INSERT on public.bottom_bar_toggles to anon;
grant SELECT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, INSERT on public.bottom_bar_toggles to authenticated;
grant INSERT, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT, TRIGGER on public.budget_items to anon;
grant TRIGGER, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, INSERT on public.budget_items to authenticated;
grant SELECT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, INSERT on public.budget_overrun_log to anon;
grant SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, INSERT on public.budget_overrun_log to authenticated;
grant INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER on public.budget_revenues to anon;
grant SELECT, UPDATE, DELETE, TRUNCATE, INSERT, REFERENCES, TRIGGER on public.budget_revenues to authenticated;
grant INSERT, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT, TRIGGER on public.center_access to anon;
grant INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER on public.center_access to authenticated;
grant INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER on public.center_ledger to anon;
grant UPDATE, TRIGGER, REFERENCES, TRUNCATE, DELETE, SELECT, INSERT on public.center_ledger to authenticated;
grant INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT on public.center_ledger_payers to anon;
grant TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT, INSERT on public.center_ledger_payers to authenticated;
grant SELECT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, INSERT on public.centers to anon;
grant TRUNCATE, INSERT, SELECT, UPDATE, DELETE, REFERENCES, TRIGGER on public.centers to authenticated;
grant INSERT, TRIGGER, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES on public.client_contracts to anon;
grant TRUNCATE, TRIGGER, INSERT, SELECT, UPDATE, DELETE, REFERENCES on public.client_contracts to authenticated;
grant UPDATE, SELECT, DELETE, TRUNCATE, REFERENCES, TRIGGER, INSERT on public.clients to anon;
grant INSERT, SELECT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE on public.clients to authenticated;
grant SELECT, INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE on public.companies to anon;
grant UPDATE, INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, SELECT on public.companies to authenticated;
grant REFERENCES, TRIGGER, SELECT, UPDATE, DELETE, TRUNCATE, INSERT on public.contract_prices to anon;
grant INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT on public.contract_prices to authenticated;
grant INSERT, SELECT on public.custodies to authenticated;
grant SELECT on public.custody_balances to authenticated;
grant SELECT on public.custody_lines to authenticated;
grant TRUNCATE, REFERENCES, SELECT, TRIGGER, UPDATE, DELETE, INSERT on public.custom_roles to anon;
grant SELECT, UPDATE, DELETE, INSERT, REFERENCES, TRIGGER, TRUNCATE on public.custom_roles to authenticated;
grant UPDATE, TRIGGER, REFERENCES, TRUNCATE, DELETE, SELECT, INSERT on public.gateway_accounts to anon;
grant TRIGGER, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES on public.gateway_accounts to authenticated;
grant TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT, INSERT on public.gateway_agents to anon;
grant SELECT, TRIGGER, REFERENCES, TRUNCATE, DELETE, INSERT, UPDATE on public.gateway_agents to authenticated;
grant INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT on public.gateway_import_users to anon;
grant INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT on public.gateway_import_users to authenticated;
grant SELECT, INSERT, REFERENCES, TRUNCATE, DELETE, UPDATE, TRIGGER on public.gateway_imports to anon;
grant REFERENCES, SELECT, UPDATE, DELETE, TRUNCATE, TRIGGER, INSERT on public.gateway_imports to authenticated;
grant TRIGGER, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES on public.gl_accounts to anon;
grant REFERENCES, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, TRIGGER on public.gl_accounts to authenticated;
grant REFERENCES, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, TRIGGER on public.gl_custody_accounts to anon;
grant TRUNCATE, TRIGGER, REFERENCES, DELETE, UPDATE, SELECT, INSERT on public.gl_custody_accounts to authenticated;
grant INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT on public.gl_exports to anon;
grant REFERENCES, TRIGGER, SELECT, UPDATE, DELETE, TRUNCATE, INSERT on public.gl_exports to authenticated;
grant TRIGGER, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES on public.job_levels to anon;
grant TRIGGER, UPDATE, REFERENCES, DELETE, TRUNCATE, SELECT, INSERT on public.job_levels to authenticated;
grant SELECT on public.login_aliases to authenticated;
grant INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, SELECT on public.org_departments to anon;
grant TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, INSERT, SELECT on public.org_departments to authenticated;
grant SELECT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, INSERT on public.organizations to anon;
grant SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER on public.organizations to authenticated;
grant SELECT, INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE on public.page_permissions to authenticated;
grant REFERENCES, TRIGGER, INSERT, SELECT, UPDATE, DELETE, TRUNCATE on public.password_reset_requests to authenticated;
grant DELETE, INSERT, SELECT, UPDATE, TRUNCATE, REFERENCES, TRIGGER on public.prj_collections to anon;
grant TRUNCATE, DELETE, UPDATE, SELECT, INSERT, TRIGGER, REFERENCES on public.prj_collections to authenticated;
grant UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, INSERT, SELECT on public.prj_documents to anon;
grant TRUNCATE, INSERT, DELETE, UPDATE, SELECT, TRIGGER, REFERENCES on public.prj_documents to authenticated;
grant REFERENCES, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, TRIGGER on public.prj_invoices to anon;
grant TRUNCATE, INSERT, SELECT, UPDATE, DELETE, TRIGGER, REFERENCES on public.prj_invoices to authenticated;
grant REFERENCES, TRIGGER, TRUNCATE, DELETE, UPDATE, SELECT, INSERT on public.projects to anon;
grant TRIGGER, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES on public.projects to authenticated;
grant TRIGGER, SELECT, TRUNCATE, REFERENCES on public.push_subscriptions to authenticated;
grant DELETE, UPDATE, SELECT, INSERT, TRIGGER, REFERENCES, TRUNCATE on public.qy_attachments to anon;
grant DELETE, UPDATE, INSERT, TRUNCATE, SELECT, REFERENCES, TRIGGER on public.qy_attachments to authenticated;
grant INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, SELECT on public.qy_audit_alerts to anon;
grant SELECT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, INSERT on public.qy_audit_alerts to authenticated;
grant DELETE, REFERENCES, TRIGGER, UPDATE, SELECT, INSERT, TRUNCATE on public.qy_client_events to anon;
grant DELETE, TRIGGER, REFERENCES, INSERT, SELECT, UPDATE, TRUNCATE on public.qy_client_events to authenticated;
grant UPDATE, INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, SELECT on public.qy_handovers to anon;
grant INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER on public.qy_handovers to authenticated;
grant UPDATE, SELECT, INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE on public.qy_verify_hits to anon;
grant TRIGGER, INSERT, SELECT, REFERENCES, TRUNCATE, UPDATE, DELETE on public.qy_verify_hits to authenticated;
grant TRIGGER, TRUNCATE, REFERENCES, SELECT on public.recurring_occurrences to authenticated;
grant TRIGGER, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, INSERT on public.recurring_settings to authenticated;
grant DELETE, TRIGGER, REFERENCES, TRUNCATE, UPDATE, SELECT, INSERT on public.recurring_templates to authenticated;
grant INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT on public.request_approval_steps to anon;
grant TRIGGER, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES on public.request_approval_steps to authenticated;
grant INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT on public.request_beneficiaries to anon;
grant REFERENCES, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, TRIGGER on public.request_beneficiaries to authenticated;
grant TRIGGER, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES on public.request_history to anon;
grant TRIGGER, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES on public.request_history to authenticated;
grant INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT on public.requests to anon;
grant REFERENCES, INSERT, SELECT, UPDATE, DELETE, TRUNCATE, TRIGGER on public.requests to authenticated;
grant INSERT, TRIGGER, UPDATE, DELETE, TRUNCATE, REFERENCES, SELECT on public.signature_layout_configs to anon;
grant SELECT, UPDATE, DELETE, INSERT, TRUNCATE, REFERENCES, TRIGGER on public.signature_layout_configs to authenticated;
grant UPDATE, TRUNCATE, REFERENCES, DELETE, TRIGGER, SELECT, INSERT on public.svc_catalog to anon;
grant SELECT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, INSERT on public.svc_catalog to authenticated;
grant INSERT, TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT on public.transactions to authenticated;
grant TRUNCATE, TRIGGER, REFERENCES, DELETE, UPDATE, SELECT, INSERT on public.user_companies to anon;
grant TRUNCATE, DELETE, INSERT, SELECT, UPDATE, TRIGGER, REFERENCES on public.user_companies to authenticated;
grant TRIGGER, REFERENCES, INSERT, SELECT, UPDATE, DELETE, TRUNCATE on public.user_company_managers to anon;
grant REFERENCES, SELECT, UPDATE, DELETE, TRUNCATE, TRIGGER, INSERT on public.user_company_managers to authenticated;
grant INSERT, TRIGGER, UPDATE, DELETE, TRUNCATE, REFERENCES on public.users to anon;
grant REFERENCES, TRIGGER, INSERT, UPDATE, DELETE, TRUNCATE on public.users to authenticated;
grant REFERENCES, TRIGGER, INSERT, SELECT, UPDATE, DELETE, TRUNCATE on public.worker_contracts to anon;
grant TRIGGER, REFERENCES, TRUNCATE, DELETE, UPDATE, SELECT, INSERT on public.worker_contracts to authenticated;
grant SELECT (approval_deadline_days, auth_id, avatar_data, can_manage_recurring, center_id, company_id, direct_to_transfer, email, escalate_mode, escalate_user_id, exec_substitute_id, id, idle_minutes, is_general, is_suspended, job_title, level_id, manager_id, name, name_en, next_approver_id, no_next_approver, no_request_approver, notif_seen_at, org_dept_id, paper_approval, paper_proxy_ids, phone, request_approver_id, role, signature_color, signature_data, signature_mode, signature_width, skip_review, stamp_data, stamp_data_2, suspended_at, suspended_note) on public.users to authenticated;
grant usage, select on sequence public.gl_exports_id_seq to anon;
grant usage, select on sequence public.qy_client_events_id_seq to anon;
grant usage, select on sequence public.beneficiaries_master_id_seq to anon;
grant usage, select on sequence public.request_beneficiaries_id_seq to anon;
grant usage, select on sequence public.request_history_id_seq to anon;
grant usage, select on sequence public.gateway_agents_id_seq to anon;
grant usage, select on sequence public.gateway_imports_id_seq to anon;
grant usage, select on sequence public.qy_audit_alerts_id_seq to anon;
grant usage, select on sequence public.center_ledger_id_seq to anon;
grant usage, select on sequence public.push_outbox_id_seq to anon;
grant usage, select on sequence public.gl_exports_id_seq to authenticated;
grant usage, select on sequence public.qy_client_events_id_seq to authenticated;
grant usage, select on sequence public.beneficiaries_master_id_seq to authenticated;
grant usage, select on sequence public.request_beneficiaries_id_seq to authenticated;
grant usage, select on sequence public.request_history_id_seq to authenticated;
grant usage, select on sequence public.gateway_agents_id_seq to authenticated;
grant usage, select on sequence public.gateway_imports_id_seq to authenticated;
grant usage, select on sequence public.qy_audit_alerts_id_seq to authenticated;
grant usage, select on sequence public.custodies_id_seq to authenticated;
grant usage, select on sequence public.custody_balances_id_seq to authenticated;
grant usage, select on sequence public.custody_lines_id_seq to authenticated;
grant usage, select on sequence public.center_ledger_id_seq to authenticated;
grant usage, select on sequence public.push_outbox_id_seq to authenticated;

-- ═══ مجلد المرفقات الخاص ═══
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types) values ('attachments','attachments',false,10485760,'{image/jpeg,image/png,image/webp,application/pdf}'::text[]) on conflict (id) do update set public=excluded.public, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;

-- ═══ المهام المجدولة (بتوقيت UTC) ═══
do $cr$ begin
  perform cron.unschedule('assign-request-numbers') where exists (select 1 from cron.job where jobname='assign-request-numbers');
  perform cron.schedule('assign-request-numbers', '* * * * *', 'select public.assign_due_request_numbers()');
  perform cron.unschedule('auto-escalate-overdue-approvals') where exists (select 1 from cron.job where jobname='auto-escalate-overdue-approvals');
  perform cron.schedule('auto-escalate-overdue-approvals', '0 * * * *', 'SELECT auto_escalate_overdue_approvals()');
  perform cron.unschedule('generate_recurring_occurrences') where exists (select 1 from cron.job where jobname='generate_recurring_occurrences');
  perform cron.schedule('generate_recurring_occurrences', '5 0 * * *', 'select public.generate_recurring_occurrences()');
  perform cron.unschedule('qy_gateway_stale') where exists (select 1 from cron.job where jobname='qy_gateway_stale');
  perform cron.schedule('qy_gateway_stale', '0 6 * * *', 'select public.qy_gateway_stale()');
  perform cron.unschedule('qy_purge_logs') where exists (select 1 from cron.job where jobname='qy_purge_logs');
  perform cron.schedule('qy_purge_logs', '15 0 * * *', 'select public.qy_purge_logs()');
  perform cron.unschedule('qy-push-flush') where exists (select 1 from cron.job where jobname='qy-push-flush');
  perform cron.schedule('qy-push-flush', '* * * * *', 'select public.qy_push_flush()');
exception when others then raise notice 'تعذرت جدولة المهام (فعّل pg_cron ثم أعد تشغيل هذا القسم): %', sqlerrm; end $cr$;

-- ═══ الإعدادات الافتراضية ═══
insert into public.app_settings(key, value) values
  ('system_name', 'ميزان القيم'),
  ('unit_types', '[{"id":"center","name":"مركز","icon":"🏫"},{"id":"department","name":"إدارة","icon":"🗂"},{"id":"section","name":"قسم","icon":"📂"},{"id":"branch","name":"فرع","icon":"🏢"}]'),
  ('rec_categories', '{"out":[],"in":[]}'),
  ('server_rules', 'on'),
  ('verify_level', '4'),
  ('migr_gm', '1')
on conflict (key) do nothing;
insert into public.bottom_bar_toggles(button_key, visible) values ('rebuild_path', true) on conflict (button_key) do nothing;

-- ═════════════ ١٢) (اختياري) أول مدير نظام وأول شركة ═════════════
-- لا تفعل هذه الكتلة شيئاً ما لم تغيّر v_run إلى true وتعدّل القيم. شغّلها مرة واحدة فقط.
do $qy$
declare
  v_run      boolean := false;                 -- ← غيّرها إلى true
  v_company  text    := 'co_main';             -- معرّف الشركة (حروف إنجليزية بلا مسافات)
  v_co_ar    text    := 'اسم الشركة بالعربية'; -- ← عدّل
  v_co_code  text    := 'MAIN';                -- رمز الشركة القصير
  v_user_id  text    := 'u_admin';             -- معرّف مدير النظام
  v_phone    text    := '55000000';            -- ← رقم دخول المدير
  v_name     text    := 'مدير النظام';         -- ← اسمه
  v_pass     text    := 'غيّر-كلمة-المرور-هذه'; -- ← ٦ خانات فأكثر (غيّرها من الحساب بعد أول دخول)
  v_uid      uuid    := gen_random_uuid();
  v_email    text;
begin
  if not v_run then
    raise notice 'قسم أول مدير لم يُنفَّذ (v_run = false). هذا طبيعي إن كنت ستنشئ المدير بطريقة أخرى.';
    return;
  end if;
  if exists (select 1 from public.users where role = 'admin') then
    raise notice 'يوجد مدير نظام بالفعل؛ لم يُنشأ شيء.';
    return;
  end if;
  if length(v_pass) < 6 then raise exception 'كلمة المرور قصيرة'; end if;
  v_email := lower(v_phone) || '@qyam.local';

  insert into public.companies(id, name_ar, code) values (v_company, v_co_ar, v_co_code)
  on conflict (id) do nothing;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change, is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
    v_email, extensions.crypt(v_pass, extensions.gen_salt('bf')), now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true, 'phone_verified', false),
    '', '', '', '', false, false);

  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (v_uid::text, v_uid,
    jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true, 'phone_verified', false),
    'email', now(), now());

  insert into public.users (id, phone, name, role, company_id, is_general, auth_id)
  values (v_user_id, v_phone, v_name, 'admin', v_company, true, v_uid);

  raise notice 'تم إنشاء مدير النظام. ادخل برقم % وكلمة المرور التي وضعتها.', v_phone;
end $qy$;



-- ═══ تحقق نهائي ═══
-- المتوقع (كقاعدة التجربة في 16 نوفمبر): tables=58 ، tables_without_rls=0 ، functions=187 ، triggers=46 ، policies=120 ، cron_jobs=6
select
  (select count(*) from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='r') as tables,
  (select count(*) from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='r' and not c.relrowsecurity) as tables_without_rls,
  (select count(*) from pg_proc p where p.pronamespace='public'::regnamespace and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')) as functions,
  (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid where c.relnamespace='public'::regnamespace and not t.tgisinternal) as triggers,
  (select count(*) from pg_policies where schemaname in ('public','storage')) as policies;
