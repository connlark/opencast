// Emit owned RSS, including gzip and a supported 100,000-item catalog.
import { mkdir,writeFile } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { resolve,join } from 'node:path';
import { feedCases,rssChunks,rssStream,catalog } from './fixtures.mjs';
const directory=resolve(process.argv[2]??'/private/tmp/opencast-notifications-phase0/rss');
await mkdir(directory,{recursive:true});
for(const scenario of feedCases) {
 await writeFile(join(directory,`${scenario.id}-baseline.xml`),[...rssChunks(scenario.baseline)].join(''));
 await writeFile(join(directory,`${scenario.id}.xml`),[...rssChunks(scenario.items,{invalidTail:scenario.fault==='invalid_tail'})].join(''));
}
await pipeline(rssStream(catalog(100000)),createWriteStream(join(directory,'100000.xml')));
await pipeline(rssStream(catalog(100000),{gzip:true}),createWriteStream(join(directory,'100000.xml.gz')));
await writeFile(join(directory,'manifest.json'),JSON.stringify(feedCases.map(({id,name,events,pending=[],fault,status=200})=>({id,name,events,pending,fault,status})),null,2));
console.log(directory);
