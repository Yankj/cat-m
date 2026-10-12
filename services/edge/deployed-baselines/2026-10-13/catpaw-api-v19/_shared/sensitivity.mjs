import {check} from './core/facade-r2/src/common.mjs';
// Conservative marker gate, not a guarantee that arbitrary text is non-sensitive. UI separately requests classification.
export function checkTextConsent(text,consent){check(!/(?:\bsk-[A-Za-z0-9_-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|Bearer\s+[A-Za-z0-9_.-]{30,})/.test(text),403,'credential_text_not_allowed');const flagged=/(?:身份证|银行卡|密码|验证码|病历|诊断|住址|手机号|医疗记录|social security|medical record|password)/i.test(text);check(!flagged||consent.sensitive_confirmed===true,403,'sensitive_content_requires_confirmation');}
