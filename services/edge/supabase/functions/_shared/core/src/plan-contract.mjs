import {check,shape,UUID,hash,clone} from '../facade-r2/src/common.mjs';

export const PLAN_CONTRACT='catpaw.task-plan.v1';
export const PLAN_STEPS=['compose','save','verify'];
export const PLAN_RECEIPT_KINDS={compose:'model_response',save:'artifact_saved',verify:'completion_validated'};
const text=(value,max,empty=false)=>check(typeof value==='string'&&value.length<=max&&(empty||value.trim().length>0),422,'schema_invalid');
export function validatePlanContent(content){
 shape(content,['title','goal','requirements','stop_conditions','steps']);
 text(content.title,160);text(content.goal,4000);text(content.requirements,4000,true);
 check(Array.isArray(content.stop_conditions)&&content.stop_conditions.length>0&&content.stop_conditions.length<=10,422,'schema_invalid');
 for(const condition of content.stop_conditions)text(condition,300);
 check(Array.isArray(content.steps)&&content.steps.length===PLAN_STEPS.length,422,'schema_invalid');
 content.steps.forEach((step,index)=>{shape(step,['id','title','detail']);check(step.id===PLAN_STEPS[index],422,'schema_invalid');text(step.title,200);text(step.detail,4000,true);});
 return clone(content);
}
export function initialPlanContent(args){
 return validatePlanContent({...clone(args),steps:args.steps??[
  {id:'compose',title:'整理已授权内容',detail:args.requirements},
  {id:'save',title:'保存本地报告',detail:'保存有内容哈希和任务来源的成果。'},
  {id:'verify',title:'核对完成条件',detail:'验证当前计划的成果后结束任务。'}
 ]});
}
export function validatePlanAmendment(input){
 shape(input,['operation_id','expected_revision','expected_plan_hash','expected_grant_epoch','content']);
 check(UUID.test(input.operation_id)&&Number.isSafeInteger(input.expected_revision)&&input.expected_revision>0&&/^[a-f0-9]{64}$/.test(input.expected_plan_hash)&&Number.isSafeInteger(input.expected_grant_epoch)&&input.expected_grant_epoch>0,422,'schema_invalid');
 validatePlanContent(input.content);return clone(input);
}
export const planBinding=head=>({revision:head.applied_revision,plan_hash:head.applied_plan_hash});
export const samePlan=(a,b)=>Boolean(a&&b&&a.revision===b.revision&&a.plan_hash===b.plan_hash);
export function planTaskSteps(content){return content.steps.map(step=>({...clone(step),status:'pending'}));}
export const planContentHash=content=>hash(validatePlanContent(content));
