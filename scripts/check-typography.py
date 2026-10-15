#!/usr/bin/env python3
"""Read-only native semantic-font guard. No SDK, runtime or acceptance claim.

The default scope is every current/new source in the declared host and packages.
Only reviewed, non-production presenter files are excluded. Icons and QA are
specific expressions, never whole files or all DEBUG code.
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOST = 'apps/ios-conversation/'
LEGACY = {
    HOST+'Sources/Features/'+name for name in (
        'RootView.swift', 'ConversationView.swift', 'DocumentView.swift',
        'AssistantViews.swift', 'LibraryViews.swift', 'SettingsView.swift',
        'SchedulesView.swift', 'LocalGatewayViews.swift', 'OpenMuseDemoView.swift')
} | {HOST+'Sources/Voice/VoiceViews.swift'}
# Exact constructors + font expressions identify SF glyphs. A Text/Label using
# the same font cannot inherit an icon exception.
ICONS = {
    'body-symbol': (HOST+'Sources/DesignSystem/Components.swift', 'Image(systemName: name).font(.system(size: size, weight: .medium))'),
    'status-symbol': (HOST+'Sources/DesignSystem/Components.swift', 'Image(systemName: symbol).font(symbol == "circle.fill" ? .system(size: dotSize, weight: .semibold) : .caption.weight(.semibold))'),
    'action-chevron': (HOST+'Sources/DesignSystem/Components.swift', 'Image(systemName: "chevron.right").font(.caption.weight(.semibold))'),
    'input-details-symbol': (HOST+'Sources/Features/ConversationFirstView.swift', 'Image(systemName:"info.circle").font(.system(size:22))'),
    'send-symbol': (HOST+'Sources/Features/ConversationFirstView.swift', 'Image(systemName:model.sending ? "clock.badge.checkmark" : "arrow.up").font(.system(size:min(sendSymbolSize,24),weight:.semibold))'),
    'connection-chevron': (HOST+'Sources/Features/ConversationFirstView.swift', 'Image(systemName: "chevron.right").font(.caption2)'),
    'sidebar-menu-symbol': ('packages/ios-navigation/Sources/CatpawNavigation/SidebarTheme.swift', 'Image(systemName: "line.3.horizontal").font(.system(size:20))'),
    'sidebar-close-symbol': ('packages/ios-navigation/Sources/CatpawNavigation/SidebarPanel.swift', 'Image(systemName: "xmark").font(.system(size:20))'),
}
QA_IDS = {
    HOST+'Sources/Features/ConversationFirstView.swift': {'qa.p0Fixture', 'qa.p0Probe', 'qa.p0Export', 'fixture.evidence'},
    HOST+'Sources/App/CatpawApp.swift': {'fixture.identity'},
}

def normalized(value):
    return re.sub(r'\s+', '', value)

def masked(text):
    """Keep offsets/newlines while hiding comments and Swift string literals."""
    result=list(text);i=0
    while i<len(text):
        start=i
        if text.startswith('//',i):
            end=text.find('\n',i);end=len(text) if end<0 else end
        elif text.startswith('/*',i):
            depth=1;end=i+2
            while end<len(text) and depth:
                if text.startswith('/*',end):depth+=1;end+=2
                elif text.startswith('*/',end):depth-=1;end+=2
                else:end+=1
        else:
            literal=re.match(r'(#+)?("""|")',text[i:])
            if not literal:i+=1;continue
            hashes=literal.group(1) or '';quote=literal.group(2);end=i+len(literal.group(0));terminator=quote+hashes
            while end<len(text):
                if not hashes and text[end]=='\\':end+=2;continue
                if text.startswith(terminator,end):end+=len(terminator);break
                end+=1
        for k in range(start,min(end,len(text))):
            if text[k]!='\n':result[k]=' '
        i=end
    return ''.join(result)

def close_paren(code,opening):
    depth=0
    for pos in range(opening,len(code)):
        if code[pos]=='(':depth+=1
        elif code[pos]==')':
            depth-=1
            if depth==0:return pos+1
    raise ValueError('Unbalanced source expression')

def requires_positive_debug(condition):
    # Deliberately conservative: accept a positive DEBUG conjunct, not an OR,
    # negated token or substring. More complicated equivalent formulas need a
    # reviewed rewrite, rather than silently granting a release-visible bypass.
    condition=normalized(condition)
    if '||' in condition or re.search(r'!\(*DEBUG\b',condition):return False
    return any(term.strip('()')=='DEBUG' for term in condition.split('&&'))

def in_debug(text,position):
    stack=[]
    for line in masked(text[:position]).splitlines():
        directive=re.match(r'\s*#(if|elseif|else|endif)\b(.*)',line)
        if not directive:continue
        kind,condition=directive.groups()
        if kind=='if':stack.append(requires_positive_debug(condition))
        elif kind=='endif':
            if stack:stack.pop()
        elif stack:stack[-1]=kind=='elseif' and requires_positive_debug(condition)
    return any(stack)

def raw_caption(value):
    value=re.sub(r'CatpawTypography\s*\.\s*Role\s*\.\s*caption\b','policy_caption',value)
    return bool(re.search(r'\.\s*caption2?\b',value))

def legacy_activations(code,names):
    return [(match.start(),name) for name in names for match in re.finditer(r'\b'+re.escape(name)+r'(?:\s*\.\s*init)?\s*\(',code)]

def violations(path,text):
    code=masked(text);issues=[]
    def report(position,message):issues.append((text.count('\n',0,position)+1,message))
    for match in re.finditer(r'\b(?:let|var)\s+\w+\s*:\s*(?:SwiftUI\s*\.\s*)?Font\s*[?!]?\s*=',code):
        start=match.end()
        while start<len(code) and code[start].isspace():start+=1
        end=re.search(r'[;\n]',code[start:]);end=start+end.start() if end else len(code)
        if raw_caption(code[start:end]):report(match.start(),'Typed Font aliases cannot bypass the policy with raw caption/caption2')
    for match in re.finditer(r'\btypography\s*\(',code):
        end=close_paren(code,code.index('(',match.start()))
        if raw_caption(code[match.start():end]):report(match.start(),'Host typography injection must use semantic roles, not raw caption/caption2')
    for match in re.finditer(r'\.font\s*\(',code):
        end=close_paren(code,code.index('(',match.start()));argument=code[code.index('(',match.start())+1:end-1]
        argument=re.sub(r'CatpawTypography\s*\.\s*Role\s*\.\s*caption\b','policy_caption',argument)
        forbidden=bool(re.search(r'\.\s*caption2?\b|\.\s*(system|custom)\s*\([^)]*\b(?:size|fixedSize)\s*:',argument))
        if not forbidden:continue
        icon=False
        for _,(owner,expression) in ICONS.items():
            if path!=owner:continue
            # Locate an actual Image constructor immediately before this modifier.
            for image in re.finditer(r'\bImage\s*\(',code[:match.start()]):
                finish=close_paren(code,image.end()-1)
                if not code[finish:match.start()].strip() and normalized(text[image.start():end])==normalized(expression):icon=True
        suffix=text[end:end+180]
        identifier=re.match(r'\s*\.accessibilityIdentifier\("([^"]+)"\)',suffix)
        qa=in_debug(text,match.start()) and identifier and identifier.group(1) in QA_IDS.get(path,set())
        if not icon and not qa:report(match.start(),'User text must use semantic roles; caption/caption2 and sized fonts are forbidden')
    for match in re.finditer(r'\bUIFontMetrics\b|\.minimumScaleFactor\s*\(|\b(?:UI)?Font\s*\.\s*(?:systemFont|boldSystemFont|monospacedSystemFont|custom)\s*\(',code):
        report(match.start(),'No text shrinking, raw font-size factories or second Dynamic Type scaling')
    for match in re.finditer(r'\bFont\s*\.\s*system\s*\(|\bUIFont\s*\(',code):
        end=close_paren(code,code.index('(',match.start()))
        if re.search(r'\b(?:size|ofSize|fixedSize)\s*:',code[match.start():end]):report(match.start(),'A font variable cannot bypass the semantic policy with a sized factory')
    for match in re.finditer(r'\bUIFont\s*\.\s*preferredFont\s*\(',code):
        if path!=HOST+'Sources/DesignSystem/AdaptiveTextLayout.swift':report(match.start(),'UIKit text fonts must use the single explicit category bridge')
    for match in re.finditer(r'\.dynamicTypeSize\s*\(',code):
        end=close_paren(code,code.index('(',match.start()))
        tail=normalized(text[match.start():end+250])
        qa_tail=normalized('.dynamicTypeSize(.large).padding(4).background(CatpawColors.panel).opacity(sidebarPresented ? 0 : 1).allowsHitTesting(!sidebarPresented).accessibilityHidden(sidebarPresented)')
        qa=(path==HOST+'Sources/Features/ConversationFirstView.swift' and in_debug(text,match.start()) and tail.startswith(qa_tail) and 'qa.p0Probe' in text[max(0,match.start()-2400):match.start()])
        if not qa:report(match.start(),'Whole-page Dynamic Type clamps are forbidden; inherit the system category')
    for match in re.finditer(r'\.environment\s*\(\s*\\\s*\.dynamicTypeSize\s*,\s*\.',code):
        report(match.start(),'A literal Dynamic Type override cannot replace the system category')
    for match in re.finditer(r'\.environment\s*\(\s*\\\s*\.dynamicTypeSize\s*,',code):
        end=close_paren(code,code.index('(',match.start()));expression=normalized(text[match.start():end])
        forwarded={
            HOST+'Sources/DesignSystem/AdaptiveTextLayout.swift':'.environment(\\.dynamicTypeSize,textSize)',
            HOST+'Sources/Features/ConversationFirstView.swift':'.environment(\\.dynamicTypeSize,textSize)',
            'packages/ios-image-composer/Sources/CatpawImageComposer/ImageAttachmentPicker.swift':'.environment(\\.dynamicTypeSize,textSize)',
        }
        fixture=(path==HOST+'Sources/App/CatpawApp.swift' and in_debug(text,match.start()) and expression=='.environment(\\.dynamicTypeSize,size)' and re.search(r'if\s+let\s+size\s*=\s*P0ExperienceFixture.textSizeOverride\s*\{',text[max(0,match.start()-250):match.start()]))
        if expression!=forwarded.get(path) and not fixture:report(match.start(),'Dynamic Type forwarding belongs to the shared modal bridge or explicit optional fixture axis')
    return sorted(set(issues))

def self_test():
    path=HOST+'Sources/Features/ConversationFirstView.swift'
    for source in ['Text("state").font(.caption)','Text("state").font(.system(size:13))','Text("state").minimumScaleFactor(0.5)','Text("state").dynamicTypeSize(.large)','Text("state").environment(\\.dynamicTypeSize,.large)','Text("state").environment(\\.dynamicTypeSize,arbitrary)','let font=UIFontMetrics.default.scaledFont(for:base)','let f=Font.system(size:13);Text("user").font(f)','let f=UIFont(name:"Face",size:13)','// comment\nText("user").font(.custom("Face",fixedSize:17))']:
        assert violations(path,source),source
    for source in ['Text(".font(.caption)").font(CatpawTypography.Role.caption.font)','// .font(.caption)\nText("user").font(.body)','/* nested /* .font(.caption) */ comment */ Text("user").font(.footnote)','#if DEBUG\nText("P0 probe").font(.caption2).accessibilityIdentifier("qa.p0Probe")\n#endif']:
        assert not violations(path,source),source
    assert violations(path,'#if DEBUG\nText("Actual user state").font(.caption)\n#endif')
    assert violations(path,'Text("P0 probe").font(.caption2).accessibilityIdentifier("qa.p0Probe")')
    for source in ['let style: Font = .caption; Text("user state").font(style)','var style: SwiftUI.Font =\n .caption2.weight(.medium)\nText("user state").font(style)','SidebarTheme.catpaw.typography(title:.title2,heading:.headline,body:.body,secondary:.subheadline,caption:.caption)']:
        assert violations(path,source),source
    assert not violations(path,'let style: Font = CatpawTypography.Role.caption.font; Text("user").font(style)')
    qa='Text("P0 probe").font(.caption2).accessibilityIdentifier("qa.p0Probe")'
    for condition in ['! DEBUG','DEBUG || SOME_RELEASE_FLAG','!(DEBUG)','DEBUGGING','DEBUG && ! DEBUG']:
        assert violations(path,'#if '+condition+'\n'+qa+'\n#endif'),condition
    for condition in ['DEBUG','(DEBUG)','DEBUG && os(iOS)','os(iOS) && DEBUG']:
        assert not violations(path,'#if '+condition+'\n'+qa+'\n#endif'),condition
    assert violations(path,'#if DEBUG\nText("ordinary").font(.body)\n#else\n'+qa+'\n#endif')
    assert violations(path,'#if os(iOS)\nText("ordinary").font(.body)\n#elseif ! DEBUG\n'+qa+'\n#endif')
    assert legacy_activations(masked('RootView(model:m);RootView.init(model:m);RootView . init(model:m)'),{'RootView'})==[(0,'RootView'),(18,'RootView'),(41,'RootView')]
    assert not legacy_activations(masked('Text("RootView.init(model:m)") // RootView(model:m)'),{'RootView'})
    for _,(owner,expression) in ICONS.items():
        assert not violations(owner,expression),expression
        assert violations(owner,expression.replace('Image(systemName:','Text(')),expression
    print('PASS typography guard negative cases, comments/strings, exact icon and DEBUG probe boundaries')

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--self-test',action='store_true');args=parser.parse_args()
    if args.self_test:self_test()
    layout=json.loads((ROOT/'docs/development/repository-layout.json').read_text())
    r5=json.loads((ROOT/'docs/design/mobile-conversation-reference-r5.json').read_text())
    assert r5['typography']['system_font'] and r5['typography']['caption_minimum']==13
    sources=list((ROOT/layout['native_host']/'Sources').rglob('*.swift'))
    for package in layout['swift_packages']:sources.extend((ROOT/package/'Sources').rglob('*.swift'))
    issues=[];count=0
    legacy_views=set()
    for legacy in LEGACY:
        legacy_views.update(re.findall(r'\bstruct\s+(\w+)\s*:\s*View\b',(ROOT/legacy).read_text()))
    for source in sorted(sources):
        relative=str(source.relative_to(ROOT))
        if relative in LEGACY:continue
        count+=1;text=source.read_text();issues.extend((relative,line,message) for line,message in violations(relative,text))
        code=masked(text)
        for position,name in legacy_activations(code,legacy_views):issues.append((relative,text.count('\n',0,position)+1,'Production source activates excluded legacy presenter '+name))
    if issues:
        for path,line,message in issues:print(f'{path}:{line}: {message}')
        raise SystemExit(1)
    print(f'PASS semantic typography: {count} active/default source files; {len(LEGACY)} separately classified legacy presenters; exact SF/DEBUG expression exceptions')
    print('LIMIT static guard only; runtime font, layout, locale, gestures and device acceptance remain separate')

if __name__=='__main__':main()
