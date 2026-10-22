// Proposed acceptance policy only. This is not a production authorization implementation.
export const metadata = Object.freeze({version:'family-security-fixture-v1',synthetic:true,layer:'fixture-only',source_sha:'789ad4feceb0680b8e2e5913083c5b834dc63db1',contract_sha:'2419db9b98e2e3bc0e8c850da62418d216fd3bb8'});
const baseline = {authenticated:true,serverActor:'synthetic-adult-a',requestedActor:'synthetic-adult-a',household:'synthetic-home-a',objectHousehold:'synthetic-home-a',parentHousehold:'synthetic-home-a',owner:'synthetic-adult-a',visibility:'shared',membership:'active',role:'owner',grant:true,membershipRevision:4,expectedMembershipRevision:4,phase:'admission',sharingEnabled:true,operation:'read',objectKind:'item',consent:true,sourceCurrent:true,generation:2,expectedGeneration:2,archived:false,bodyRole:null,serviceRole:false};
const c = (id,name,patch,allow,reason) => ({id,name,input:{...baseline,...patch},expected:{allow,reason}});
export const cases = [
 c('FP-01','同家庭owner读取共享事项',{},true,'authorized'),
 c('FP-02','同家庭viewer读取共享事项',{role:'viewer'},true,'authorized'),
 c('FP-03','同家庭viewer不得修改事项',{role:'viewer',operation:'write'},false,'read_only'),
 c('FP-04','caregiver显式授权修改事项',{role:'caregiver',operation:'write'},true,'authorized'),
 c('FP-05','caregiver无对象授权不得读取',{role:'caregiver',grant:false},false,'object_grant_required'),
 c('FP-06','跨家庭对象ID不得读取',{objectHousehold:'synthetic-home-b'},false,'tenant_mismatch'),
 c('FP-07','跨家庭对象ID不得修改',{objectHousehold:'synthetic-home-b',operation:'write'},false,'tenant_mismatch'),
 c('FP-08','跨家庭父对象不得关联',{parentHousehold:'synthetic-home-b',operation:'write'},false,'tenant_mismatch'),
 c('FP-09','另一成人私人观察owner也不可读',{visibility:'private',owner:'synthetic-adult-b'},false,'private_owner_required'),
 c('FP-10','另一成人私人聊天admin也不可读',{role:'admin',objectKind:'conversation',owner:'synthetic-adult-b'},false,'private_owner_required'),
 c('FP-11','自己的私人记录可读',{visibility:'private'},true,'authorized'),
 c('FP-12','会话绑定家庭不改变聊天所有权',{objectKind:'conversation',owner:'synthetic-adult-b',visibility:'shared'},false,'private_owner_required'),
 c('FP-13','invited成员未激活不得读取',{membership:'invited'},false,'membership_inactive'),
 c('FP-14','撤权成员不得读取投影',{membership:'revoked'},false,'membership_inactive'),
 c('FP-15','撤权发生后worker不得dispatch',{membership:'revoked',phase:'dispatch',operation:'dispatch'},false,'membership_inactive'),
 c('FP-16','旧权限revision命令需重审',{expectedMembershipRevision:3,operation:'write'},false,'membership_revision_conflict'),
 c('FP-17','伪造body actor不得成为身份',{requestedActor:'synthetic-adult-b'},false,'actor_mismatch'),
 c('FP-18','未认证不得bootstrap读取',{authenticated:false},false,'authentication_required'),
 c('FP-19','service-role仍须家庭授权',{serviceRole:true,membership:'revoked'},false,'membership_inactive'),
 c('FP-20','用户metadata管理员字段无效',{role:'viewer',bodyRole:'admin',operation:'write'},false,'read_only'),
 c('FP-21','儿童member不等于Auth账号',{membership:'none',role:'child'},false,'membership_inactive'),
 c('FP-22','关闭共享时第二成人不得读取',{sharingEnabled:false,owner:'synthetic-adult-b'},false,'single_adult_boundary'),
 c('FP-23','关闭共享时主要成人仍可读取',{sharingEnabled:false},true,'authorized'),
 c('FP-24','隐私范围改变必须独立确认',{operation:'share',consent:false},false,'specific_consent_required'),
 c('FP-25','有确认仍不得分享另一成人私聊',{operation:'share',objectKind:'conversation',owner:'synthetic-adult-b'},false,'private_owner_required'),
 c('FP-26','来源撤回后冻结记忆不可dispatch',{operation:'dispatch',phase:'dispatch',sourceCurrent:false},false,'source_not_current'),
 c('FP-27','删除generation使迟到job失效',{operation:'dispatch',phase:'dispatch',expectedGeneration:1},false,'generation_superseded'),
 c('FP-28','撤权后command receipt不可泄漏标题',{membership:'revoked',objectKind:'receipt'},false,'membership_inactive'),
 c('FP-29','跨家庭cursor增量不得读取',{objectKind:'changes',objectHousehold:'synthetic-home-b'},false,'tenant_mismatch'),
 c('FP-30','归档家庭不得创建新事项',{archived:true,operation:'write'},false,'household_archived'),
 c('FP-31','viewer不得导出另一成人私有材料',{role:'viewer',operation:'export',visibility:'private',owner:'synthetic-adult-b'},false,'private_owner_required'),
 c('FP-32','未知角色默认拒绝',{role:'unrecognized'},false,'role_unknown'),
];
// Deliberately small review oracle: validates fixture consistency, never used by the app.
export function proposedPolicy(x) {
 const deny=reason=>({allow:false,reason});
 if(!x.authenticated)return deny('authentication_required');
 if(x.serverActor!==x.requestedActor)return deny('actor_mismatch');
 if(x.membership!=='active')return deny('membership_inactive');
 if(x.household!==x.objectHousehold||x.household!==x.parentHousehold)return deny('tenant_mismatch');
 if(x.expectedMembershipRevision!==x.membershipRevision)return deny('membership_revision_conflict');
 if((x.visibility==='private'||x.objectKind==='conversation')&&x.owner!==x.serverActor)return deny('private_owner_required');
 if(!x.sharingEnabled&&x.owner!==x.serverActor)return deny('single_adult_boundary');
 if(!['owner','admin','caregiver','viewer'].includes(x.role))return deny('role_unknown');
 if(x.role==='viewer'&&x.operation!=='read')return deny('read_only');
 if(x.role==='caregiver'&&!x.grant)return deny('object_grant_required');
 if(x.operation==='share'&&!x.consent)return deny('specific_consent_required');
 if(x.phase==='dispatch'&&!x.sourceCurrent)return deny('source_not_current');
 if(x.expectedGeneration!==x.generation)return deny('generation_superseded');
 if(x.archived&&x.operation!=='read')return deny('household_archived');
 return {allow:true,reason:'authorized'};
}
