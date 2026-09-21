import { generateKeyPairSync, createHash, sign } from 'node:crypto';
const sha=bytes=>createHash('sha256').update(bytes).digest();
const cbor=(major,bytes)=>Buffer.concat([Buffer.from(bytes.length<24?[major+bytes.length]:[major+24,bytes.length]),bytes]);
// Synthetic keys seeded in local D1 exercise the actual assertion verifier;
// there is no auth bypass in the shipped entrypoint.
export async function identity(db,install,appID,time) {
  const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
  const jwk=publicKey.export({format:'jwk'});
  const raw=Buffer.concat([Buffer.from([4]),Buffer.from(jwk.x,'base64url'),Buffer.from(jwk.y,'base64url')]);
  const keyID=sha(raw).toString('base64');let counter=0;
  await db.prepare('INSERT INTO app_attest_keys VALUES(?,?,?,0,?,?,?,?)').bind(install,keyID,raw,appID,'development',time,time).run();
  return async (worker,path,body)=>{
    const payload=JSON.stringify(body),auth=Buffer.alloc(37);sha(appID).copy(auth);auth.writeUInt32BE(++counter,33);
    const nonce=sha(Buffer.concat([auth,sha(`POST\n${path}\n${sha(payload).toString('hex')}`)]));
    const signature=sign('sha256',nonce,privateKey);
    const assertion=Buffer.concat([Buffer.from([0xa2]),cbor(0x60,Buffer.from('signature')),cbor(0x40,signature),cbor(0x60,Buffer.from('authenticatorData')),cbor(0x40,auth)]).toString('base64');
    return worker.fetch(`https://fixture.invalid${path}`,{method:'POST',body:JSON.stringify({install_id:install,key_id:keyID,payload,assertion})});
  };
}
