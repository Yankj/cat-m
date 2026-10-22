// Import the real .ts source with Node's built-in transform; replace npm boundaries only.
import {register} from 'node:module';
register(new URL('./source-loader.mjs', import.meta.url));
