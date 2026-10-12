import {check,shape,hash,UUID} from '../facade-r2/src/common.mjs';
export function validateReportPolicy(policy){
 if(policy===null||policy===undefined)return null;
 shape(policy,['schema_version','kind','stop_condition','required_sections','required_context_ids','min_content_chars']);
 check(policy.schema_version===1&&policy.kind==='single_local_report'&&typeof policy.stop_condition==='string'&&policy.stop_condition.length>0&&policy.stop_condition.length<=300&&Array.isArray(policy.required_sections)&&policy.required_sections.length>0&&policy.required_sections.length<=8&&policy.required_sections.every(s=>typeof s==='string'&&s.trim()&&s.length<=80)&&Array.isArray(policy.required_context_ids)&&policy.required_context_ids.every(s=>typeof s==='string'&&s.length<=80)&&Number.isInteger(policy.min_content_chars)&&policy.min_content_chars>=1&&policy.min_content_chars<=16000,422,'invalid_completion_policy');
 return structuredClone(policy);
}
// Trusted admission port only. This selection is never read from model arguments, context or message text.
export function freezeCompletionIntent(policy,selection,binding){
 shape(selection,['schema_version','source','source_reference','source_version','policy_version','mode']);
 check(selection.schema_version===1&&['fixture_case_selection','authenticated_structured_user_choice'].includes(selection.source)&&typeof selection.source_reference==='string'&&selection.source_reference.length>0&&selection.source_reference.length<=160&&selection.source_version===1&&selection.policy_version===1&&selection.mode==='single_local_report',422,'invalid_completion_intent');
 return {...structuredClone(selection),policy_hash:hash(policy),...structuredClone(binding)};
}
export function completionAuthorityValid(frozen){
 const a=frozen.completion_authority,p=frozen.completion_policy,c=frozen.completion_contract,b=frozen.run_binding;
 if(!a||!p||c?.schema_version!==1||c.version!==1||c.mode!=='single_local_report'||!b)return false;
 return a.schema_version===1&&a.mode===c.mode&&a.source_version===1&&a.policy_version===c.version&&['fixture_case_selection','authenticated_structured_user_choice'].includes(a.source)&&typeof a.source_reference==='string'&&a.source_reference.length>0&&a.policy_hash===hash(p)&&a.subject_id===frozen.subject_id&&a.scope_id===frozen.scope?.scope_id&&a.conversation_id===frozen.conversation_id&&a.turn_id===frozen.turn_id&&a.user_message_id===frozen.user_message_id&&a.input_hash===frozen.current_input_hash&&a.conversation_epoch===frozen.conversation_epoch&&['run_id','operation_id','delegation_id','task_id'].every(k=>a[k]===b[k])&&['run_id','operation_id','delegation_id'].every(k=>UUID.test(b[k]))&&typeof b.task_id==='string'&&b.task_id.length>0;
}
export function evaluateReport(frozen,report){
 const policy=frozen.completion_policy;if(!policy)return {valid:false,authorized_stop:false,code:'completion_policy_missing'};
 const content=typeof report.content==='string'?report.content:'';
 const authorized=completionAuthorityValid(frozen);
 // This is compatibility with the frozen task contract, not proof of user authorization.
 const contractConsistent=Array.isArray(frozen.args.stop_conditions)&&frozen.args.stop_conditions.length===1&&frozen.args.stop_conditions[0]===policy.stop_condition;
 const missing_sections=policy.required_sections.filter(s=>!content.includes(s)),contextPresent=policy.required_context_ids.every(id=>frozen.context.some(c=>c.id===id)),minLength=content.trim().length>=policy.min_content_chars;
 const valid=authorized&&contractConsistent&&contextPresent&&minLength&&!missing_sections.length;
 return {valid,authorized_stop:authorized,contract_consistent:contractConsistent,context_present:contextPresent,missing_sections,min_length_met:minLength,policy_hash:hash(policy),authority_hash:frozen.completion_authority?hash(frozen.completion_authority):null,report_hash:hash(report),code:!authorized?'structured_completion_intent_required':valid?'complete_report':'report_incomplete'};
}
