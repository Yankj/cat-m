import {readFile,stat,readdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.dirname(fileURLToPath(import.meta.url)),dist=path.join(root,'dist');
const files=(await readdir(dist)).filter(n=>n.endsWith('.html'));
let count=0;const failures=[];
for(const file of files){const text=await readFile(path.join(dist,file),'utf8');if(text.includes('{{'))failures.push(`${file}: unresolved token`);if((text.match(/<h1\b/g)||[]).length!==1)failures.push(`${file}: h1 count`);if(!text.includes('lang="zh-CN"'))failures.push(`${file}: language`);for(const match of text.matchAll(/(?:src|href)="([^"#]+)(?:#[^"]*)?"/g)){const link=match[1].split('#')[0];if(/^(https?:|data:|mailto:)/.test(link))continue;count++;try{await stat(path.join(dist,link));}catch{failures.push(`${file}: missing ${link}`);}}for(const match of text.matchAll(/href="#([^"]+)"/g))if(!text.includes(`id="${match[1]}"`))failures.push(`${file}: missing anchor ${match[1]}`);}
const video=await stat(path.join(dist,'assets/launch-final-v2.mp4'));const pdf=await stat(path.join(dist,'assets/catpaw-product-deck.pdf'));
if(video.size!==21393661)failures.push('Video differs from provided file size');if(pdf.size!==4125274)failures.push('PDF differs from provided file size');
console.log(JSON.stringify({pages:files.length,localLinksChecked:count,videoBytes:video.size,pdfBytes:pdf.size,failures},null,2));if(failures.length)process.exit(1);
