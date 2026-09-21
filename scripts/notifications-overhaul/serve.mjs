// Optional loopback fixture server. No publisher requests or credentials.
import { createServer } from 'node:http';
import { pipeline } from 'node:stream/promises';
import { feedCases,rssStream,catalog } from './fixtures.mjs';
const server=createServer(async(req,res)=>{
 const url=new URL(req.url,'http://localhost');
 const id=url.pathname.slice(1).replace(/\.xml(\.gz)?$/,'');
 const fixture=feedCases.find(x=>x.id===id);
 if(!fixture && id!=='100000') {res.writeHead(404).end();return;}
 const etag=`"${id}-${url.searchParams.get('phase')??'update'}"`;
 if(req.headers['if-none-match']===etag || fixture?.status===304){res.writeHead(304,{etag}).end();return;}
 if(fixture?.fault==='timeout'){res.writeHead(200,{'content-type':'application/rss+xml'});res.write('<rss><channel>');return;}
 const items=id==='100000'?catalog(100000):url.searchParams.get('phase')==='baseline'?fixture.baseline:fixture.items;
 const gzip=url.pathname.endsWith('.gz');res.writeHead(200,{'content-type':'application/rss+xml',etag,...(gzip?{'content-encoding':'gzip'}:{})});
 try {await pipeline(rssStream(items,{gzip,invalidTail:fixture?.fault==='invalid_tail' || fixture?.fault==='cancel'}),res);} catch {res.destroy();}
});
server.listen(Number(process.env.PORT??0),'127.0.0.1',()=>console.log(`Owned fixture server: http://127.0.0.1:${server.address().port}/F02.xml (Ctrl-C to stop)`));
