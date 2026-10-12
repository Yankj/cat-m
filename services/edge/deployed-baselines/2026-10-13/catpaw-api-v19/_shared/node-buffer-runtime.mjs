import {Buffer} from 'node:buffer';
// Explicit eager dependency for npm:postgres and legacy runtime modules using the Node global.
// This module must evaluate before those dependencies, not in bootstrap's later body.
globalThis.Buffer??=Buffer;
