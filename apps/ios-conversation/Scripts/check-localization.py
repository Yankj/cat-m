#!/usr/bin/env python3
"""Check app-owned UI keys and bilingual resources; preserve explicit source-content exceptions."""
import re,json
from pathlib import Path
HAN=re.compile('[\u3400-\u9fff]')
def string_at(s,start):
 i=start+1; parts=[]; text=''
 while i<len(s):
  if s[i]=='"':
   parts.append(('text',text)); return i+1,parts
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
   out+=val.replace('\\n','\n').replace('\\t','\t').replace('\\"','"').replace('\\\\','\\')
 return out

import plistlib,subprocess,hashlib
root=Path(__file__).resolve().parents[1]
catalog=json.loads((root/'Resources/UIStrings.json').read_text())
exemptions=json.loads((root/'Resources/UIStringExemptions.json').read_text())
ui=list(root.glob('Sources/Features/*View*.swift'))+[root/'Sources/Voice/VoiceViews.swift',root/'Sources/App/CatpawApp.swift']
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
# Presentation enum values and voice-state keys must also exist in the central resource.
for p in [root/'Sources/DesignSystem/DisplayNames.swift',root/'Sources/Voice/NativeVoiceController.swift']:
 for a,b,parts in literals(p.read_text()):
  k=key(parts)
  if HAN.search(k) and not k.startswith('本周持续跟进 AI 助理') and k not in catalog:errors.append(p.name+': missing dynamic resource: '+k)
assert not errors,'\n'.join(errors)
print('PASS L10 UI literal scan: %d locale-bound lookups; 0 missing resources; 0 unlocalized owned literals' % lookups)
assert issues('Text("遗漏文案")','Probe.swift')[0]
assert issues('Text(ui("未登记的资源"))','Probe.swift')[0]
assert not issues('Text(ui("设置"))','Probe.swift')[0]
assert not issues('Text(ui("设置")).accessibilityIdentifier("固定验收标识")','Probe.swift')[0]
assert issues('Text("固定验收标识").accessibilityIdentifier("固定验收标识")','Probe.swift')[0]
assert not issues('Text("帮我整理这份文档的要点")','LibraryViews.swift')[0]
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
print('PASS L10 four unchanged permission keys have English and Chinese InfoPlist resources')
protected={
 'Sources/Features/LibraryViews.swift':['帮我整理这份文档的要点'],
 'Sources/Features/DocumentView.swift':['素材采集','重点筛选','感想共创','内容检查','成果审阅'],
 'Sources/Features/SchedulesView.swift':['整理工作日志，生成日报摘要','整理会议要点','生成周报','整理邮件摘要','整理待办','清理文档','整理日程','代码审查'],
 'Sources/Voice/NativeVoiceController.swift':['本周持续跟进 AI 助理的工作机制，先整理一份私有短稿。','本周持续跟进 AI 助理的工作机制。']}
for name,content in protected.items():
 actual={key(parts) for a,b,parts in literals((root/name).read_text())}
 assert set(content)<=actual,name
print('PASS L10 original prompt, diagram and transcript content preserved')
assert hashlib.sha256((root/'Sources/Providers/FixtureProvider.swift').read_bytes()).hexdigest()=='cde6bc09ea560c9a16cd8a7e70fe55209d8e826f451fc3d420b4ac43235bd39d'
print('PASS L10 FixtureProvider source unchanged from 169-check snapshot')
