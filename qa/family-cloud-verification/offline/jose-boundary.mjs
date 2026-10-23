// Bootstrap health checks must never authenticate or sign; reaching any export fails.
const denied = () => { throw Error('family_qa_jose_forbidden'); };
export const createRemoteJWKSet = denied, createLocalJWKSet = denied, jwtVerify = denied, decodeProtectedHeader = denied, decodeJwt = denied, importPKCS8 = denied;
export class SignJWT { constructor() { denied(); } }
