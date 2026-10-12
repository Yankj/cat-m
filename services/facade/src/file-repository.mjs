// Single-process synthetic loopback persistence. NOT a substitute for SQL CAS across hosts.
import { readFile,mkdir,open,rename } from 'node:fs/promises';
import { dirname } from 'node:path';
import { MemoryRepository } from './memory-repository.mjs';
export class FileRepository extends MemoryRepository {
  static async open(path) {
    let rows=[];
    try { const file=JSON.parse(await readFile(path,'utf8'));if(file.schema_version!==1||!Array.isArray(file.rows))throw new Error('Invalid synthetic repository');rows=file.rows; }
    catch(e){if(e.code!=='ENOENT')throw e;}
    return new FileRepository(path,rows);
  }
  constructor(path,rows) { super(rows);this.path=path;this.layer='single_process_file_synthetic'; }
  async prepareCommit(rows) {
    await mkdir(dirname(this.path),{recursive:true,mode:0o700});
    const temp=this.path+'.pending',file=await open(temp,'w',0o600);
    try { await file.writeFile(JSON.stringify({schema_version:1,rows:[...rows]}));await file.sync(); }finally{await file.close();}
    await rename(temp,this.path);
    const directory=await open(dirname(this.path),'r');try{await directory.sync();}finally{await directory.close();}
  }
}
