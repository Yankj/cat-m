const frame = value => `data: ${JSON.stringify(value)}\n\n`;
export class SyntheticTransport {
  async open(request,_credential,signal) {
    if(request.real) throw Object.assign(new Error('mock cannot attest a real call'),{code:'mock_real_mismatch'});
    const prompt=JSON.parse(request.payloadJSON).messages.at(-1).content;
    const body=`【模拟 · 本地合约验证】\n\n${typeof prompt==='string'?prompt:'Synthetic inline image accepted.'}\n\n未读取外部来源，未执行外部动作。`;
    const id=`mock-${request.payloadHash.slice(0,12)}`;
    return {status:200,headers:{'x-generation-id':id},body:(async function*(){
      for(const content of [body.slice(0,20),body.slice(20)]) {
        if(signal.aborted) throw Object.assign(new Error('cancelled'),{code:'cancelled'});
        yield Buffer.from(frame({id,choices:[{index:0,delta:{content},finish_reason:null}]}));
      }
      yield Buffer.from(frame({id,choices:[{index:0,delta:{},finish_reason:'stop'}]})+'data: [DONE]\n\n');
    })()};
  }
}
