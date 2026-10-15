#!/usr/bin/env python3
"""Scan candidate files, without printing suspected secret values. Review hits manually."""
from pathlib import Path
import argparse, hashlib, json, re, struct, subprocess

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--json-output',type=Path)
args=parser.parse_args()
result=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root)
paths=sorted(set(x.decode() for x in result.split(b'\0') if x))
patterns={
    'credential_prefix':r'gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(?:proj-)?[A-Za-z0-9_-]{24,}|sb_secret_[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}',
    'deployment_public_key':r'sb_publishable_[A-Za-z0-9_-]{20,}',
    'private_key':r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
    'credential_url':r'https?://[^\s/@:]+:[^\s/@]+@',
    'personal_absolute_path':r'/(?:Users|home|Volumes)/[A-Za-z0-9_.-]+/',
    'internal_domain':r'(?:[a-zA-Z0-9_-]+\.)*(?:sankuai\.com|meituan\.com|mws\.sankuai\.com)',
    'signed_url':r'[?&](?:X-Amz-Signature|X-Goog-Signature|signature|access_token)=',
    'device_identity':r'(?i)(?:udid|simulator_id|device_id|identifier for vendor)[^\n]{0,60}[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}',
}
hits=[]; review=[]; total=0; images=[]
def finding(path,category,line=None):
    hits.append({'path':path,'category':category,**({'line':line} if line else {})})
for name in paths:
    p=root/name
    if p.is_symlink():finding(name,'symlink');continue
    if not p.is_file():finding(name,'missing_file');continue
    data=p.read_bytes();total+=len(data)
    if len(data)>5*1024*1024:finding(name,'file_over_5_MiB')
    if (p.name.startswith('.env') and p.name!='.env.example') or p.suffix.lower() in ['.pem','.key','.p12','.zip','.ipa','.log']:
        finding(name,'excluded_file_kind')
    if p.name=='.env.example':
        for line in data.decode('utf8').splitlines():
            if not line.strip() or line.lstrip().startswith('#'):continue
            key,separator,value=line.partition('=')
            if not separator or (value.strip() and not (key=='SUPABASE_URL' and value=='http://127.0.0.1:54321')):
                finding(name,'nonempty_configuration_template')
    if any(x in ['DerivedData','node_modules','xcuserdata','.runtime','.aws','.codex'] or x.startswith('.build') for x in Path(name).parts):
        finding(name,'excluded_directory_kind')
    if p.suffix.lower()=='.png':
        assert data[:8]==b'\x89PNG\r\n\x1a\n',name
        cursor=8;metadata=[]
        while cursor+12<=len(data):
            size=struct.unpack('>I',data[cursor:cursor+4])[0];kind=data[cursor+4:cursor+8].decode('ascii')
            if kind in ['tEXt','iTXt','zTXt','eXIf']:metadata.append(kind)
            cursor+=12+size
        if metadata:finding(name,'png_metadata_requires_review')
        images.append({'path':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'metadata_chunks':metadata})
        continue
    try:text=data.decode('utf8')
    except UnicodeDecodeError:finding(name,'unexpected_binary');continue
    for category,pattern in patterns.items():
        for match in re.finditer(pattern,text):
            finding(name,category,text.count('\n',0,match.start())+1)
    # Attribute values only; variable names and blank/obvious synthetic literals do not imply secrets.
    for match in re.finditer(r'(?i)(?:api[_-]?key|access[_-]?token|password|client[_-]?secret)\s*[:=]\s*[\"\']([^\"\'\n]{8,})[\"\']',text):
        value=match.group(1)
        if not re.search(r'synthetic|fixture|example|placeholder|not-configured|your[-_]|process\.env',value,re.I):
            review.append({'path':name,'category':'secret_assignment_review','line':text.count('\n',0,match.start())+1})
    for match in re.finditer(r'[\w.+-]+@([\w.-]+\.[A-Za-z]{2,})',text):
        if match.group(1).lower() not in ['example.invalid','example.com']:
            review.append({'path':name,'category':'email_review','line':text.count('\n',0,match.start())+1})
exceptions=json.loads((root/'scripts/reviewed-findings.json').read_text())['findings']
approved=[]
def unresolved(items):
    remaining=[]
    for item in items:
        actual=hashlib.sha256((root/item['path']).read_bytes()).hexdigest()
        match=next((x for x in exceptions if x['path']==item['path'] and x['category']==item['category']
                    and x.get('line')==item.get('line') and x['sha256']==actual),None)
        if match:approved.append({**item,'sha256':actual,'reason':match['reason']})
        else:remaining.append(item)
    return remaining
raw_count=len(hits)+len(review)
hits=unresolved(hits);review=unresolved(review)
output={'candidate_files':len(paths),'candidate_bytes':total,'blocking_hits':hits,'manual_review_hits':review,
        'raw_hit_count':raw_count,'reviewed_findings':approved,
        'images':images,'file_limit_bytes':5*1024*1024,
        'scope':'Git candidate files only; ignored runtime/cache/credentials are not read. Known-pattern scan is not an exhaustive guarantee.'}
if args.json_output:
    args.json_output.parent.mkdir(parents=True,exist_ok=True)
    args.json_output.write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'candidate_files':len(paths),'candidate_bytes':total,'blocking_hits':hits,'manual_review_hits':review,
                  'reviewed_false_positives':len(approved),'png_files':len(images)},ensure_ascii=False))
raise SystemExit(1 if hits or review else 0)
