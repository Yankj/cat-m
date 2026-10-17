import {Buffer} from 'node:buffer';
import {createHash} from 'node:crypto';
import {inflateSync} from 'node:zlib';
import {VISION_ROUTE_HASHES} from './live-vision-route.mjs';
import {ApiError,check,shape,UUID,hash,clone} from '../facade-r2/src/common.mjs';
// Server constants. No caller-supplied URLs, dimensions, limits or route selection.
export const VISION_LIMITS=Object.freeze({max_count:1,max_image_bytes:5*1024*1024,max_total_image_bytes:5*1024*1024,max_side:2048,max_pixels:2048*2048,max_request_bytes:7100000,mime_types:Object.freeze(['image/png','image/jpeg'])});
const pngSignature=Buffer.from([137,80,78,71,13,10,26,10]),validated=new WeakSet();
const sha=data=>createHash('sha256').update(data).digest('hex');
const dimensions=(width,height)=>{check(width>0&&height>0&&width<=VISION_LIMITS.max_side&&height<=VISION_LIMITS.max_side&&width*height<=VISION_LIMITS.max_pixels,422,'image_dimensions_exceeded');return {width,height};};
export function crc32(bytes){let crc=0xffffffff;for(const byte of bytes){crc^=byte;for(let j=0;j<8;j++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}return (crc^0xffffffff)>>>0;}
function pngSize(bytes){
  check(bytes.length>=45&&bytes.subarray(0,8).equals(pngSignature),422,'image_signature_mismatch');
  let offset=8,size=null,color=null,ended=false;const idats=[];
  while(offset<bytes.length){
    check(offset+12<=bytes.length,422,'image_malformed');const length=bytes.readUInt32BE(offset),end=offset+12+length;
    check(end<=bytes.length,422,'image_malformed');const type=bytes.toString('ascii',offset+4,offset+8),data=bytes.subarray(offset+8,end-4);
    check(crc32(bytes.subarray(offset+4,end-4))===bytes.readUInt32BE(end-4),422,'image_checksum_invalid');
    if(type==='IHDR'){
      check(offset===8&&length===13&&!size,422,'image_malformed');size=dimensions(data.readUInt32BE(0),data.readUInt32BE(4));color=data[9];
      check(data[8]===8&&[2,6].includes(color)&&data[10]===0&&data[11]===0&&data[12]===0,422,'image_encoding_unsupported');
    }else if(type==='IDAT'){check(size&&!ended&&length>0,422,'image_malformed');idats.push(data);}
    else if(type==='IEND'){check(size&&idats.length&&length===0&&end===bytes.length,422,'image_malformed');ended=true;}
    else throw new ApiError(422,'image_metadata_or_animation_unsupported');
    offset=end;
  }
  check(ended,422,'image_malformed');const rowBytes=1+size.width*(color===2?3:4),expected=rowBytes*size.height;let pixels;
  try{pixels=inflateSync(Buffer.concat(idats),{maxOutputLength:expected});}catch{throw new ApiError(422,'image_decompression_invalid');}
  check(pixels.length===expected,422,'image_decompression_invalid');for(let row=0;row<size.height;row++)check(pixels[row*rowBytes]<=4,422,'image_filter_invalid');return size;
}
function jpegSize(bytes){
  check(bytes.length>=4&&bytes[0]===255&&bytes[1]===216,422,'image_signature_mismatch');let offset=2,size=null,sawScan=false,sawQuant=false,sawHuffman=false;
  while(offset<bytes.length){
    check(bytes[offset++]===255,422,'image_malformed');while(bytes[offset]===255)offset++;const marker=bytes[offset++];
    if(marker===217){check(offset===bytes.length&&size&&sawScan&&sawQuant&&sawHuffman,422,'image_malformed');return size;}
    check(marker!==undefined&&marker!==0&&marker!==216&&!(marker>=208&&marker<=215)&&offset+2<=bytes.length,422,'image_malformed');
    const length=bytes.readUInt16BE(offset),end=offset+length;check(length>=2&&end<=bytes.length,422,'image_malformed');const data=bytes.subarray(offset+2,end);
    if(marker===192||marker===194){check(!size&&data.length>=6&&data[0]===8&&[1,3].includes(data[5])&&length===8+3*data[5],422,'image_encoding_unsupported');size=dimensions(data.readUInt16BE(3),data.readUInt16BE(1));}
    else if(marker===224){check(data.length===14&&data.subarray(0,5).equals(Buffer.from('JFIF\0'))&&data[12]===0&&data[13]===0,422,'image_metadata_or_animation_unsupported');}
    else if(marker>=225&&marker<=239||marker===254)throw new ApiError(422,'image_metadata_or_animation_unsupported');
    else if(marker===219){check(data.length>0,422,'image_malformed');sawQuant=true;}
    else if(marker===196){check(data.length>=17,422,'image_malformed');sawHuffman=true;}
    else if(marker===221)check(length===4,422,'image_malformed');
    else if(marker===218){
      check(size&&sawQuant&&sawHuffman&&data.length>=4&&data[0]>0&&length===6+2*data[0],422,'image_malformed');sawScan=true;offset=end;
      while(offset<bytes.length){if(bytes[offset]!==255){offset++;continue;}const next=bytes[offset+1];if(next===0||next>=208&&next<=215){offset+=2;continue;}break;}continue;
    }else throw new ApiError(422,'image_encoding_unsupported');
    offset=end;
  }
  throw new ApiError(422,'image_malformed');
}
// Structural PNG/JPEG validation shared by uploaded attachments (same rules as inline base64).
export function validateImageBytes(bytes,mime){check(VISION_LIMITS.mime_types.includes(mime),422,'image_mime_unsupported');check(bytes.length>0&&bytes.length<=VISION_LIMITS.max_image_bytes,413,'image_too_large');return mime==='image/png'?pngSize(bytes):jpegSize(bytes);}
export function validateVisionTurn(input,{enabled=false}={}){
  check(enabled===true,503,'image_input_unavailable');shape(input,['schema_version','turn_id','expected_revision','expected_grant_epoch','message','context']);check(input.schema_version===2,422,'schema_invalid');shape(input.message,['id','text','attachments']);
  check(Array.isArray(input.message.attachments)&&input.message.attachments.length>0&&input.message.attachments.length<=VISION_LIMITS.max_count,422,'image_count_exceeded');
  check(Buffer.byteLength(JSON.stringify(input))<=VISION_LIMITS.max_request_bytes,413,'request_too_large');const ids=new Set();let total=0;const attachments=[];
  for(const a of input.message.attachments){
    shape(a,['id','mime_type','sha256','base64']);check(UUID.test(a.id)&&!ids.has(a.id)&&a.id!==input.message.id,422,'image_id_invalid');ids.add(a.id);
    check(VISION_LIMITS.mime_types.includes(a.mime_type),422,'image_mime_unsupported');check(typeof a.sha256==='string'&&/^[a-f0-9]{64}$/.test(a.sha256),422,'image_hash_invalid');
    check(typeof a.base64==='string'&&a.base64.length>0&&a.base64.length<=4*Math.ceil(VISION_LIMITS.max_image_bytes/3),413,'image_too_large');
    check(a.base64.length%4===0&&/^[A-Za-z0-9+/]*={0,2}$/.test(a.base64),422,'image_base64_invalid');
    const bytes=Buffer.from(a.base64,'base64');check(bytes.toString('base64')===a.base64,422,'image_base64_invalid');check(bytes.length<=VISION_LIMITS.max_image_bytes,413,'image_too_large');total+=bytes.length;check(total<=VISION_LIMITS.max_total_image_bytes,413,'image_total_too_large');
    check(sha(bytes)===a.sha256,422,'image_hash_mismatch');const size=a.mime_type==='image/png'?pngSize(bytes):jpegSize(bytes);
    const attachment=Object.freeze({bytes,receipt:Object.freeze({id:a.id,mime_type:a.mime_type,sha256:a.sha256,size_bytes:bytes.length,...size})});validated.add(attachment);attachments.push(attachment);
  }
  const {attachments:_,...message}=input.message,{schema_version:__,...plain}=input;return {input:{...plain,message},attachments,receipts:attachments.map(a=>clone(a.receipt))};
}
// Pure mapping at the current user message; network authorization belongs to the live adapter.
export function mapVisionMessages(messages,attachments,userIndex){
  check(Array.isArray(messages)&&Number.isInteger(userIndex)&&messages[userIndex]?.role==='user'&&typeof messages[userIndex].content==='string',422,'vision_message_invalid');
  check(Array.isArray(attachments)&&attachments.length>0&&attachments.length<=VISION_LIMITS.max_count&&attachments.every(a=>validated.has(a)&&a.bytes.length===a.receipt.size_bytes&&sha(a.bytes)===a.receipt.sha256),422,'vision_attachment_unvalidated');
  const mapped=clone(messages);mapped[userIndex].content=[{type:'text',text:messages[userIndex].content},...attachments.map(a=>({type:'image_url',image_url:{url:`data:${a.receipt.mime_type};base64,${a.bytes.toString('base64')}`}}))];return mapped;
}
export function createVisionContract(config,provider){
  const live=config.visionLiveEnabled===true&&provider?.visionContract?.execution_layer==='live_image_adapter'&&provider.liveNetworkEnabled===true&&VISION_ROUTE_HASHES.includes(hash(provider.visionContract.route));
  const mock=!live&&config.visionContractEnabled===true&&provider?.visionContract?.execution_layer==='synthetic_mock'&&provider.liveNetworkEnabled===false;
  const route=live||mock?clone(provider.visionContract.route):null;
  if(mock)check(route&&typeof route.id==='string'&&typeof route.provider==='string'&&typeof route.downstream_provider==='string'&&typeof route.model==='string'&&route.model.endsWith(':free')&&route.free===true&&route.data_fields?.includes('user_selected_image_bytes')&&route.purposes?.includes('chat_reply')&&route.retention&&route.zero_retention_claim===false,503,'vision_mock_route_invalid');
  return {enabled:live||mock,isLive:live,route,routeHash:route?hash(route):null,capability:{schema_version:2,available:false,state:live?'live_catalog_pending':mock?'mock_only':config.visionContractEnabled||config.visionLiveEnabled?'production_route_unvalidated':'disabled',request_scoped:true,persistent_image_history:false,requires_text_caption:true,limits:clone(VISION_LIMITS)}};
}
export async function boundedJsonBody(request,maxBytes){
  const header=request.headers.get('content-length');if(header!==null)check(/^\d+$/.test(header)&&Number(header)<=maxBytes,413,'request_too_large');
  const reader=request.body?.getReader(),chunks=[];let size=0;
  if(reader)try{while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>maxBytes){await reader.cancel();throw new ApiError(413,'request_too_large');}chunks.push(Buffer.from(value));}}finally{reader.releaseLock();}
  try{return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(Buffer.concat(chunks)));}catch{throw new ApiError(422,'schema_invalid');}
}
