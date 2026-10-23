#!/usr/bin/env python3
"""Check app-owned UI keys and bilingual resources; preserve explicit source-content exceptions."""
import re,json
from pathlib import Path
HAN=re.compile('[\u3400-\u9fff]')
def string_at(s,start):
 quote='"""' if s.startswith('"""',start) else '"'
 i=start+len(quote); parts=[]; text=''
 while i<len(s):
  if s.startswith(quote,i):
   parts.append(('text',text)); return i+len(quote),parts
  if s.startswith('\\(',i):
   parts.append(('text',text));text='';i+=2;a=i;depth=1
   while depth:
    if s[i]=='"': i,_=string_at(s,i);continue
    if s[i]=='(': depth+=1
    elif s[i]==')': depth-=1
    i+=1
   parts.append(('expr',s[a:i-1]));continue
  if s[i]=='\\':
   text+=s[i:i+2];i+=2;continue
  text+=s[i];i+=1
 raise ValueError(start)
def literals(s):
 i=0
 while i<len(s):
  if s.startswith('//',i):
   e=s.find('\n',i);i=len(s) if e<0 else e+1;continue
  if s[i]=='"':
   end,parts=string_at(s,i);yield i,end,parts;i=end
  else:i+=1
def key(parts):
 n=0;out=''
 for kind,val in parts:
  if kind=='expr':out+='{'+str(n)+'}';n+=1
  else:
   val=re.sub(r'\\u\{([0-9A-Fa-f]+)\}',lambda m:chr(int(m[1],16)),val)
   out+=val.replace('\\n','\n').replace('\\t','\t').replace('\\"','"').replace('\\\\','\\')
 return out

import plistlib,subprocess,hashlib
root=Path(__file__).resolve().parents[1]
catalog=json.loads((root/'Resources/UIStrings.json').read_text())
exemptions=json.loads((root/'Resources/UIStringExemptions.json').read_text())
ui=list(root.glob('Sources/Features/*View*.swift'))+[root/'Sources/Features/NativeConversationComposer.swift',root/'Sources/Voice/VoiceViews.swift',root/'Sources/App/catApp.swift']
def issues(s,name):
 errors=[];lookups=0
 for a,b,parts in literals(s):
  k=key(parts)
  if not HAN.search(k):continue
  if re.search(r'\baccessibilityIdentifier\(\s*$',s[:a]):continue
  if re.search(r'\bui\(\s*$',s[:a]):
   lookups+=1
   if k not in catalog:errors.append('missing resource: '+k)
  elif k not in exemptions.get(name,[]):errors.append('unlocalized UI literal: '+k)
 return errors,lookups
errors=[];lookups=0
for p in ui:
 found,count=issues(p.read_text(),p.name)
 errors.extend(str(p.relative_to(root))+': '+e for e in found);lookups+=count
# Parenting lives in nested Features plus Domain/Persistence. Enum titles and
# LocalizedError values are declared resource keys, consumed by the UI's ui(...).
# Only the intake protocol's prompt and date-matching regex are source content.
def parenting_issues(s,name):
 errors=[];count=0;source_content=0
 for a,b,parts in literals(s):
  k=key(parts)
  if not HAN.search(k):continue
  prefix=s[:a]
  if name=='ParentingIntakeDraft.swift' and (
      re.search(r'\b(?:prompt|originalPrompt)\s*=\s*$',prefix) and s.startswith('"""',a)
      or re.search(r'\bprompt\s*=\s*originalPrompt\s*\+\s*$',prefix) and s.startswith('"""',a)
      or re.search(r'\blet\s+(?:date|clock)\s*=\s*$',prefix)):
   source_content+=1;continue
  # The bounded edit-time verifier's grammar is source data, while its clarification remains UI text.
  # Keep this scoped to exact declarations/tokens; a Text/Button/etc. call is never exempted.
  if name=='ParentingRescheduleTime.swift' and not re.search(r'\b(?:Text|Button|TextField|SecureField|Label|ProgressView|navigationTitle|accessibilityLabel|accessibilityHint)\(\s*$',prefix):
   grammar_tokens={'今天','明天','后天','凌晨','早上','上午','中午','下午','傍晚','晚上','零','〇','一','二','两','三','四','五','六','七','八','九','十'}
   if k in grammar_tokens or re.search(r'\bprivate\s+static\s+let\s+(?:datePattern|clockPattern|absolutePattern|unsupportedPattern)\s*=\s*#$',prefix) or re.search(r'\bmatches\(\s*#$',prefix):
    source_content+=1;continue
  count+=1
  if k not in catalog:errors.append('missing parenting resource: '+k)
  if re.search(r'\b(?:Text|Button|TextField|SecureField|Label|ProgressView|navigationTitle|accessibilityLabel|accessibilityHint)\(\s*$',prefix):
   errors.append('unlocalized parenting UI literal: '+k)
 return errors,count,source_content
parenting_count=0;parenting_source_content=0
for p in sorted(root.glob('Sources/**/*Parenting*.swift')):
 found,count,source_content=parenting_issues(p.read_text(),p.name)
 errors.extend(str(p.relative_to(root))+': '+e for e in found)
 parenting_count+=count;parenting_source_content+=source_content
# LocalizedError exposes the already-interpolated string, and UICatalog uses an
# exact lookup. Audit each finite domain limit as well as its {0} source template.
parenting_domain=(root/'Sources/Domain/ParentingWorkspace.swift').read_text()
for limit in set(re.findall(r'\blimit:\s*(\d+)',parenting_domain)):
 k='内容不能为空，且不能超过'+limit+'字。'
 if k not in catalog:errors.append('ParentingWorkspace.swift: missing rendered error resource: '+k)
# Non-Chinese identifiers in the onboarding chip declaration still require a resource.
for a,b,parts in literals((root/'Sources/Features/NativeLoginView.swift').read_text()):
 k=key(parts)
 if k.startswith('onboarding.parenting.') and k not in catalog:errors.append('NativeLoginView.swift: missing declared resource: '+k)
# Presentation enum values and voice-state keys must also exist in the central resource.
for p in [root/'Sources/DesignSystem/DisplayNames.swift',root/'Sources/Voice/NativeVoiceController.swift']:
 for a,b,parts in literals(p.read_text()):
  k=key(parts)
  if HAN.search(k) and not k.startswith('本周持续跟进 AI 助理') and k not in catalog:errors.append(p.name+': missing dynamic resource: '+k)
# Audit the shared native widgets with the same strict key rules.
package_root=root.parents[1]/'packages'
widgets=[package_root/'ios-navigation/Sources/catNavigation'/name for name in ['SidebarHost.swift','SidebarPanel.swift','SidebarTheme.swift']]
widgets.append(package_root/'ios-image-composer/Sources/catImageComposer/ImageAttachmentPicker.swift')
for p in widgets:
 found,count=issues(p.read_text().replace('localize(', 'ui('),p.name)
 errors.extend(str(p.relative_to(package_root))+': '+e for e in found);lookups+=count
for a,b,parts in literals((package_root/'ios-image-composer/Sources/catImageComposer/ImageAttachment.swift').read_text()):
 k=key(parts)
 if HAN.search(k) and k not in catalog:errors.append('ImageAttachment.swift: missing dynamic resource: '+k)
assert not errors,'\n'.join(errors)
print('PASS L10 UI literal scan: %d locale-bound lookups; 0 missing resources; 0 unlocalized owned literals' % lookups)
print('PASS L10 parenting audit: %d declared/UI/error keys; %d explicit intake protocol source literals excluded' % (parenting_count,parenting_source_content))
assert parenting_issues('enum Tab { var title:String { "未登记的育儿标题" } }','ParentingProbe.swift')[0]
assert parenting_issues('Text("设置")','ParentingProbe.swift')[0]
assert not parenting_issues('enum Tab { var title:String { "设置" } }','ParentingProbe.swift')[0]
assert parenting_issues('throw catError.invalid("未登记的育儿错误")','ParentingProbe.swift')[0]
assert not parenting_issues('private static let datePattern = #"今天|明天"#','ParentingRescheduleTime.swift')[0]
assert parenting_issues('Text("明天")','ParentingRescheduleTime.swift')[0]
assert parenting_issues('private static let clarification = "未登记的时间澄清"','ParentingRescheduleTime.swift')[0]
assert not parenting_issues('prompt = """协议内容"""','ParentingIntakeDraft.swift')[0]
assert parenting_issues('let title = "协议内容"','ParentingIntakeDraft.swift')[0]
assert key(next(literals('"""inner "quote" and \\(value)"""'))[2])=='inner "quote" and {0}'
assert issues('Text("遗漏文案")','Probe.swift')[0]
assert issues('Text(ui("未登记的资源"))','Probe.swift')[0]
assert not issues('Text(ui("设置"))','Probe.swift')[0]
assert not issues('Text(ui("设置")).accessibilityIdentifier("固定验收标识")','Probe.swift')[0]
assert issues('Text("固定验收标识").accessibilityIdentifier("固定验收标识")','Probe.swift')[0]
assert not issues('Text("帮我整理这份文档的要点")','LibraryViews.swift')[0]
assert issues(r'Text("\u{9057}\u{6F0F}")','Probe.swift')[0]
assert not issues(r'Text(ui("\u{8BBE}\u{7F6E}"))','Probe.swift')[0]
print('PASS L10 audit detects missing key and unlocalized literal while preserving declared source content')
for k,values in catalog.items():
 assert set(values)=={'zh-Hans','en'} and all(values.values()),k
 assert not HAN.search(values['en']),k
 assert sorted(re.findall(r'\{[0-9]+\}',values['zh-Hans']))==sorted(re.findall(r'\{[0-9]+\}',values['en'])),k
print('PASS L10 %d bilingual entries and interpolation parity' % len(catalog))
info=plistlib.loads((root/'Resources/Info.plist').read_bytes())
for language in ['en','zh-Hans']:
 p=root/('Resources/'+language+'.lproj/InfoPlist.strings')
 values=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(p)]))
 assert set(values)=={k for k in info if k.endswith('UsageDescription')}
 assert all(values.values())
 if language=='en':assert all(not HAN.search(v) for v in values.values())
trial_info=plistlib.loads((root/'Configuration/DeviceTrial.Info.plist').read_bytes())
assert {k for k in trial_info if k.endswith('UsageDescription')}=={k for k in info if k.endswith('UsageDescription')}
print('PASS L10 %d permission keys have English and Chinese resources in both App configurations' % len([k for k in info if k.endswith('UsageDescription')]))
protected={
 'Sources/Features/LibraryViews.swift':['帮我整理这份文档的要点'],
 'Sources/Features/DocumentView.swift':['素材采集','重点筛选','感想共创','内容检查','成果审阅'],
 'Sources/Features/SchedulesView.swift':['整理工作日志，生成日报摘要','整理会议要点','生成周报','整理邮件摘要','整理待办','清理文档','整理日程','代码审查']}  # NativeVoiceController sample transcript removed on purpose in 26bbd5f0 (fake 示例转写)
for name,content in protected.items():
 actual={key(parts) for a,b,parts in literals((root/name).read_text())}
 assert set(content)<=actual,name
print('PASS L10 original prompt, diagram and transcript content preserved')
assert hashlib.sha256((root/'Sources/Providers/FixtureProvider.swift').read_bytes()).hexdigest()=='ab1cf40e25058de754963874c43fe6d86f207c669ac73ff05ec46ed25a554680'
print('PASS L10 FixtureProvider matches reviewed cat brand snapshot (reply semantics preserved)')

for table,keys in {
 'Localizable':['Open cat Conversation','Open conversation','Open cat to continue a conversation or edit a message. Opening does not send messages.'],
 'AppShortcuts':['Open a conversation in ${applicationName}','Open ${applicationName}']}.items():
 values_by_locale={}
 for language in ['en','zh-Hans']:
  p=root/('Resources/'+language+'.lproj/'+table+'.strings')
  values=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(p)]))
  assert set(values)==set(keys) and all(values.values()),str(p)
  if language=='en':assert all(not HAN.search(v) for v in values.values()),str(p)
  for k,v in values.items():assert k.count('${applicationName}')==v.count('${applicationName}'),k
  values_by_locale[language]=values
 assert all(values_by_locale['zh-Hans'][k]!=values_by_locale['en'][k] for k in keys),table
print('PASS L10 native AppIntent and shortcut bilingual tables and applicationName parity')
