#!/usr/bin/env python3
"""R5 native semantic-role guard. Static source checks, never visual acceptance.

The JSON is the palette authority. Check role definitions and the specific host
seams where reusing a generic accent previously coupled unrelated surfaces.
Typography syntax/legacy boundaries remain owned by check-typography.py.
"""
import argparse
import importlib.util
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOST = "apps/ios-conversation/Sources/"
COMPONENTS = HOST + "DesignSystem/Components.swift"
TYPE = HOST + "DesignSystem/AdaptiveTextLayout.swift"
FIRST = HOST + "Features/ConversationFirstView.swift"
STREAM = HOST + "Features/StreamingConversationText.swift"
READER = HOST + "Features/ConversationArtifactReaderView.swift"
COMPOSER = HOST + "Features/NativeConversationComposer.swift"
CHROME = HOST + "Features/Composer/ComposerChrome.swift"
SIDEBAR = "packages/ios-navigation/Sources/CatpawNavigation/SidebarTheme.swift"
PANEL = "packages/ios-navigation/Sources/CatpawNavigation/SidebarPanel.swift"
POLICY = importlib.util.spec_from_file_location("catpaw_typography_policy", ROOT / "scripts/check-typography.py")
TYPOGRAPHY = importlib.util.module_from_spec(POLICY)
POLICY.loader.exec_module(TYPOGRAPHY)
masked = TYPOGRAPHY.masked

# Native names, not a second palette. Only R5 JSON supplies these color values.
ROLES = {
    "background": "bg", "panel": "panel", "input": "card", "drawer": "drawer",
    "ink": "ink", "onInk": "primary_ink", "secondary": "secondary", "action": "tint",
    "send": "send", "sendIcon": "send_ink", "userMessageBackground": "bubble",
    "userMessageInk": "bubble_ink", "controlEdge": "control_edge", "failure": "error",
}
ROLE_MAP = {"body": "body", "secondary": "subheadline", "caption": "footnote", "table": "callout"}


def body(text, declaration):
    """Read one balanced Swift declaration/branch; ignore comment/string decoys."""
    code = masked(text)
    match = re.search(declaration, code)
    if not match:
        return ""
    opening = code.find("{", match.end())
    if opening < 0:
        return ""
    depth = 0
    for position in range(opening, len(code)):
        if code[position] == "{":
            depth += 1
        elif code[position] == "}":
            depth -= 1
            if depth == 0:
                return code[opening + 1:position]
    return ""


TOKENS_PATH = HOST + "DesignSystem/CatpawBrandTokens.swift"

def load_brand_tokens(sources):
    """Resolve CatpawBrandTokens hex constants so Components can reference them."""
    code = masked(sources.get(TOKENS_PATH, ""))
    found = {
        name: value.upper()
        for name, value in re.findall(
            r"\bstatic\s+let\s+(\w+)\s*:\s*UInt32\s*=\s*0x([0-9a-fA-F]{6})\b",
            code,
        )
    }
    return found

def resolve_hex(token_or_hex, tokens):
    raw = token_or_hex.strip()
    if re.fullmatch(r"0x[0-9a-fA-F]{6}", raw):
        return raw[2:].upper()
    match = re.fullmatch(r"CatpawBrandTokens\.(\w+)", raw)
    if match and match.group(1) in tokens:
        return tokens[match.group(1)]
    return None

def adaptive_values(code, declaration, tokens=None):
    tokens = tokens or {}
    pattern = (
        declaration
        + r"\s*=\s*adaptive\s*\(\s*light\s*:\s*(0x[0-9a-fA-F]{6}|CatpawBrandTokens\.\w+)\s*,\s*dark\s*:\s*(0x[0-9a-fA-F]{6}|CatpawBrandTokens\.\w+)\s*\)"
    )
    out = []
    for light, dark in re.findall(pattern, masked(code)):
        lh, dh = resolve_hex(light, tokens), resolve_hex(dark, tokens)
        if lh and dh:
            out.append(("#" + lh, "#" + dh))
    return out


def luminance(value):
    channels = [int(value[index:index + 2], 16) / 255 for index in (1, 3, 5)]
    linear = [channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4 for channel in channels]
    return sum(channel * weight for channel, weight in zip(linear, (0.2126, 0.7152, 0.0722)))


# r9 (design-owner approved 2026-10-15): r9 palette replaces r5 values for these roles.
# Brand sheet 2026-10 (Primary/Deep/Background/Ink/Grey). Hex authority: CatpawBrandTokens.
R9_OVERRIDES = {
    # first-run-polish 2026-10-17 (user steering 12:33): one dark canvas #0E0C0A for launch screen, splash and chat.
    "bg": ("#FFFCF8", "#0E0C0A"),
    "bubble": ("#F2EFEB", "#262422"),
    "bubble_ink": ("#292622", "#F2F0ED"),
    "ink": ("#292622", "#F2F0ED"),
    "secondary": ("#6E6A66", "#A39E98"),
    "tint": ("#C64A0B", "#FF8A5C"),
}

def contrast(a, b):
    light, dark = sorted((luminance(a), luminance(b)), reverse=True)
    return (light + 0.05) / (dark + 0.05)


def check(sources, spec):
    issues = []
    def issue(path, message):
        issues.append((path, message))
    def require(path, code, pattern, message):
        if not re.search(pattern, code):
            issue(path, message)

    palette = sources[COMPONENTS]
    tokens = load_brand_tokens(sources)
    if not tokens.get("primary"):
        issue(TOKENS_PATH, "CatpawBrandTokens must define brand sheet hex (primary/deep/background/ink/grey)")
    values = {}
    for role, key in ROLES.items():
        actual = adaptive_values(palette, r"\bstatic\s+let\s+" + role + r"\b", tokens)
        expected = R9_OVERRIDES.get(key) or tuple(spec["colors"][mode][key].upper() for mode in ("light", "dark"))
        if actual != [expected]:
            issue(COMPONENTS, f"R5 role {role} must map once to {key}: {expected}; found {actual}")
        elif actual:
            values[key] = actual[0]
    require(COMPONENTS, masked(palette), r"\bstatic\s+let\s+accent\s*=\s*action\b", "accent is a compatibility alias to action, not an independent palette")

    # Recompute from source values, rather than trusting documented contrast ratios.
    values["primary"] = values.get("ink", ())
    for pair in spec["contrast"]["pairs"]:
        mode = pair["mode"]
        if mode not in ("light", "dark"):
            continue
        foreground, background = pair["role"].split("/")
        if not values.get(foreground) or not values.get(background):
            continue
        index = ("light", "dark").index(mode)
        actual = contrast(values[foreground][index], values[background][index])
        # r9 decision (2026-10-16): paw orange is for fills/icons/non-text only → WCAG 1.4.11 non-text 3:1.
        # Orange text must use ink, or CatpawColors.actionText (#C4511F) where unavoidable (checked below).
        minimum = 3.0 if foreground == "tint" else pair["minimum"]
        if actual < minimum:
            issue(COMPONENTS, f"{mode} {pair['role']} contrast {actual:.3f} is below {pair['minimum']}")

    require(COMPONENTS, masked(palette), r"\bstatic\s+let\s+actionText\s*=\s*adaptive\(\s*light:\s*(?:0xC64A0B|CatpawBrandTokens\.deep)\b", "orange text token actionText must be Deep #C64A0B in light mode")
    for path, code in sources.items():
        for number, line in enumerate(code.splitlines(), 1):
            if "Text(" in line and re.search(r"\.foregroundStyle\(\s*CatpawColors\.(action|accent)\s*\)", line):
                issue(path, f"line {number}: orange text must use CatpawColors.ink or CatpawColors.actionText, not action/accent")

    primary = body(palette, r"\bstruct\s+CatpawPrimaryButtonStyle\s*:")
    require(COMPONENTS, primary, r"\.foregroundStyle\(\s*isEnabled\s*\?\s*CatpawColors\.onInk\b", "primary action foreground must use onInk")
    require(COMPONENTS, primary, r"\.background\(\s*isEnabled\s*\?\s*CatpawColors\.ink\b", "primary approval/action background must use ink")

    # r8 composer (design-owner approved): one ComposerTrailingControls view owns send/stop/voice.
    # Send = paw brand token + sendIcon glyph; stop and voice = ink circle; queue badge ink on background.
    # No controlEdge separator requirement (single pill with hairline).
    trailing = body(sources[CHROME], r"\bstruct\s+ComposerTrailingControls\b")
    require(CHROME, trailing, r"\.foregroundStyle\(\s*CatpawColors\.sendIcon\s*\)\s*\n\s*\.frame\(width:\s*size,\s*height:\s*size\)\s*\n?\s*\.background\(\s*canSend", "enabled send glyph must use sendIcon")
    require(CHROME, trailing, r"\.background\(\s*canSend\s*\?\s*CatpawBrand\.paw\b", "enabled send background must use the paw brand token")
    require(CHROME, trailing, r"RoundedRectangle\([^\n]*\n[^\n]*\.background\(\s*CatpawColors\.ink\s*,\s*in:\s*Circle\(\)\)", "stop background must be ink")
    require(CHROME, trailing, r"\.foregroundStyle\(\s*CatpawColors\.ink\s*\)\s*\n\s*\.padding\(2\)\.background\(\s*CatpawColors\.background", "composer queue badge must be ink on background")
    message = body(sources[FIRST], r"\bfunc\s+messageView\s*\(")
    user = body(message, r"\bif\s+message\.role\s*==\s*\.user\b")
    require(FIRST, user, r"\.foregroundStyle\(\s*CatpawColors\.userMessageInk\s*\)", "user text must use its paired userMessageInk")
    require(FIRST, user, r"\.background\(\s*CatpawColors\.userMessageBackground\b", "user bubble must use userMessageBackground, independently of inputs")

    # SF semantic styles are the native mapping, not browser px copied as points.
    typography = sources[TYPE]
    for declaration in (r"\bvar\s+font\s*:", r"\bvar\s+textStyle\s*:"):
        switch = body(typography, declaration)
        for role, semantic in ROLE_MAP.items():
            require(TYPE, switch, r"case\s+\." + role + r"\s*:\s*\." + semantic + r"\b", f"{role} must map to semantic {semantic} in SwiftUI and UIKit")
    require(TYPE, masked(typography), r"\bfunc\s+readingLineSpacing\s*\(", "reading line spacing must have one shared semantic-font owner")
    require(STREAM, masked(sources[STREAM]), r"paragraph\.lineSpacing\s*=\s*CatpawTypography\.readingLineSpacing\(for\s*:\s*newFont\)", "streaming TextKit must use shared spacing with its rendered UIFont")
    require(READER, masked(sources[READER]), r"\.lineSpacing\(\s*CatpawTypography\.readingLineSpacing\(", "artifact reading must use the same shared spacing")
    require(COMPOSER, masked(sources[COMPOSER]), r"CatpawTypography\.font\(\s*(?:\.body\s*,\s*)?size\s*:\s*size\)", "UIKit composer/stream font bridge must use the semantic body owner")

    sidebar = body(sources[SIDEBAR], r"\bstatic\s+var\s+catpaw\s*:")
    for role, key in {"panel": "drawer", "input": "panel", "ink": "ink", "secondary": "secondary"}.items():
        found = re.findall(r"\b" + role + r"\s*:\s*adaptive\(\s*light\s*:\s*0x([0-9a-fA-F]{6})\s*,\s*dark\s*:\s*0x([0-9a-fA-F]{6})\s*\)", sidebar)
        expected = tuple(spec["colors"][mode][key][1:].upper() for mode in ("light", "dark"))
        if [(a.upper(), b.upper()) for a, b in found] != [expected]:
            issue(SIDEBAR, f"default SidebarTheme.{role} must match R5 {key}")
    require(SIDEBAR, sidebar, r"selection\s*:\s*adaptive\(\s*light\s*:\s*0xE8E8E8\s*,\s*dark\s*:\s*0x202020\s*\)", "selected sidebar row must retain its reviewed neutral selection role")
    require(PANEL, masked(sources[PANEL]), r"selected\s*\?\s*theme\.selection\s*:\s*Color\.clear", "sidebar selection must not inherit the search input surface")
    require(FIRST, masked(sources[FIRST]), r"SidebarTheme\.catpaw\.typography\(", "host must use the shared sidebar default plus semantic typography")

    # New host code cannot quietly introduce an unreviewed parallel RGB palette.
    # Transparent clears, semantic system labels, images and package defaults remain valid.
    for path, text in sources.items():
        if not path.startswith(HOST) or path == COMPONENTS or path in TYPOGRAPHY.LEGACY:
            continue
        code = masked(text)
        if re.search(r"\b(?:Color|UIColor|NSColor)\s*\(\s*(?:red|white|hue|srgbRed)\s*:|\b(?:Color|UIColor|NSColor)\.(?:blue|black|white|gray|cyan|indigo|teal|pink|purple|brown|yellow|mint|orange)\b|\.(?:foregroundStyle|foregroundColor|background|tint)\s*\(\s*\.(?:blue|black|white|gray|cyan|indigo|teal|pink|purple|brown|yellow|mint|orange)\b", code):
            issue(path, "host palette literals belong in shared semantic roles, not local RGB/named colors")
    return issues


def self_test(sources, spec):
    # Mutate the actual source seams: changing a single unrelated color role must fail.
    # These are guard regressions, not product/visual tests.
    sources = {path: sources[path] for path in (COMPONENTS, TYPE, FIRST, STREAM, READER, COMPOSER, CHROME, SIDEBAR, PANEL)}
    tests = [
        (COMPONENTS, "light: CatpawBrandTokens.background, dark: CatpawBrandTokens.canvasDark", "light: 0xF7F8FA, dark: 0x111214", "R5 role background"),
        (COMPONENTS, "static let accent = action", "static let accent = ink", "compatibility alias"),
        (CHROME, ".foregroundStyle(CatpawColors.sendIcon)\n                            .frame", ".foregroundStyle(CatpawColors.onInk)\n                            .frame", "enabled send glyph"),
        (CHROME, "canSend ? CatpawBrand.paw", "canSend ? CatpawColors.action", "enabled send background"),
        (CHROME, "frame(width: 12, height: 12)\n                        .frame(width: size, height: size).background(CatpawColors.ink", "frame(width: 12, height: 12)\n                        .frame(width: size, height: size).background(CatpawBrand.paw", "stop background"),
        (CHROME, ".foregroundStyle(CatpawColors.ink)\n                                .padding(2)", ".foregroundStyle(CatpawBrand.paw)\n                                .padding(2)", "queue badge"),
        (FIRST, "CatpawColors.userMessageInk", "CatpawColors.ink", "user text"),
        (FIRST, "CatpawColors.userMessageBackground", "CatpawColors.input", "user bubble"),
        (STREAM, "CatpawTypography.readingLineSpacing(for:newFont)", "6", "streaming TextKit"),
        (SIDEBAR, "light: 0xF5F5F5, dark: 0x141414", "light: 0xFFFFFF, dark: 0x1B1D21", "SidebarTheme.panel"),
        (PANEL, "selected ? theme.selection", "selected ? theme.input", "sidebar selection"),
    ]
    for path, original, replacement, expected in tests:
        assert original in sources[path], f"Guard mutation seam changed; review {path}: {original}"
        changed = dict(sources)
        changed[path] = sources[path].replace(original, replacement)
        assert any(expected in message for _, message in check(changed, spec)), (path, expected)
    # A comment/string mentioning the right role cannot satisfy a missing binding.
    changed = dict(sources)
    changed[CHROME] = sources[CHROME].replace("canSend ? CatpawBrand.paw", "canSend ? CatpawColors.action") + '\n// .background(canSend ? CatpawBrand.paw\nlet decoy = ".background(canSend ? CatpawBrand.paw"\n'
    assert any("enabled send background" in message for _, message in check(changed, spec))
    changed = dict(sources)
    changed[STREAM] += "\nlet rogue = Color(red: 0.1, green: 0.2, blue: 0.3)\n"
    assert any("host palette literals" in message for _, message in check(changed, spec))
    changed[STREAM] = sources[STREAM] + '\n// Color(red: 0.1, green: 0.2, blue: 0.3)\nlet decoy = "Color.blue"\n'
    assert not any("host palette literals" in message for _, message in check(changed, spec))
    print(f"PASS native design guard: {len(tests) + 3} role/usage drift and comment/string mutation cases")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    spec = json.loads((ROOT / "docs/design/mobile-conversation-reference-r5.json").read_text())
    layout = json.loads((ROOT / "docs/development/repository-layout.json").read_text())
    assert str(layout["native_host"]) == "apps/ios-conversation"
    paths = list((ROOT / layout["native_host"] / "Sources").rglob("*.swift"))
    paths += [ROOT / SIDEBAR, ROOT / PANEL]
    sources = {str(path.relative_to(ROOT)): path.read_text() for path in paths}
    issues = check(sources, spec)
    if issues:
        for path, message in issues:
            print(f"{path}: {message}")
        raise SystemExit(1)
    if args.self_test:
        self_test(sources, spec)
    print(f"PASS R5 native semantic palette, opaque contrast, paired controls, sidebar and shared reading seams ({len(sources)} sources)")
    print("LIMIT static source only; native pixels/materials, Dynamic Type layout, keyboard, VoiceOver and interruptible motion require actual App verification")


if __name__ == "__main__":
    main()
