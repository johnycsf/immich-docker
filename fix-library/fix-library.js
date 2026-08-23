#!/usr/bin/env node
/**
 * Immich library repair helper — scans for broken assets and optionally fixes them.
 *
 * Run inside the immich-server container (has pg, bullmq, ffprobe, vips):
 *   node fix-library.js scan
 *   node fix-library.js fix --apply
 *
 * Immich v3 job names (do not use legacy AssetMetadataExtraction):
 *   metadataExtraction  -> AssetExtractMetadata
 *   thumbnailGeneration -> AssetGenerateThumbnails
 */
'use strict';

const { Client } = require('pg');
const fs = require('fs');
const { execSync } = require('child_process');
const { Queue } = require('bullmq');

const REDIS = { host: process.env.REDIS_HOSTNAME || 'redis', port: Number(process.env.REDIS_PORT || 6379) };
const BULL_PREFIX = 'immich_bull';
const JOB_EXTRACT_METADATA = 'AssetExtractMetadata';
const JOB_GENERATE_THUMBNAILS = 'AssetGenerateThumbnails';

function parseArgs(argv) {
  const opts = {
    command: 'scan',
    apply: false,
    waitMetadata: false,
    emptyTrashedBroken: true,
    restoreTrashedGood: true,
    json: false,
    thumbnailsOnly: false,
  };
  const positional = [];
  for (const arg of argv) {
    if (arg === '--apply') opts.apply = true;
    else if (arg === '--dry-run') opts.apply = false;
    else if (arg === '--wait-metadata') opts.waitMetadata = true;
    else if (arg === '--skip-trash') {
      opts.emptyTrashedBroken = false;
      opts.restoreTrashedGood = false;
    } else if (arg === '--thumbnails-only') opts.thumbnailsOnly = true;
    else if (arg === '--json') opts.json = true;
    else if (arg.startsWith('-')) throw new Error(`Unknown option: ${arg}`);
    else positional.push(arg);
  }
  if (positional[0]) opts.command = positional[0];
  return opts;
}

function vipsOk(path) {
  try {
    execSync(`vipsheader ${JSON.stringify(path)}`, { stdio: 'pipe' });
    return true;
  } catch {
    return false;
  }
}

function ffprobeOk(path) {
  try {
    execSync(`ffprobe -v error ${JSON.stringify(path)}`, { stdio: 'pipe', timeout: 15000 });
    return true;
  } catch {
    return false;
  }
}

function fileState(path) {
  if (!fs.existsSync(path)) return 'missing';
  if (fs.statSync(path).size === 0) return 'zero_byte';
  return 'present';
}

async function queryAssets(pg, sql, params = []) {
  const res = await pg.query(sql, params);
  return res.rows;
}

async function scan(pg) {
  const activeTimeline = await queryAssets(
    pg,
    `SELECT a.id, a."originalPath", a."originalFileName", a.type, a.thumbhash IS NOT NULL AS has_thumb,
            EXISTS (SELECT 1 FROM asset_video av WHERE av."assetId" = a.id) AS has_video_meta
     FROM asset a
     WHERE a.status = 'active' AND a."deletedAt" IS NULL AND a.visibility = 'timeline'`,
  );

  const trashed = await queryAssets(
    pg,
    `SELECT a.id, a."originalPath", a."originalFileName", a.type
     FROM asset a
     WHERE a.status = 'trashed' OR a."deletedAt" IS NOT NULL`,
  );

  const report = {
    activeTimeline: activeTimeline.length,
    missingFile: [],
    zeroByte: [],
    badImage: [],
    badVideo: [],
    fixableVideo: [],
    trashedGood: [],
    trashedBroken: [],
    readyForThumbnails: [],
  };

  for (const row of activeTimeline) {
    const state = fileState(row.originalPath);
    if (state === 'missing') {
      report.missingFile.push(row);
      continue;
    }
    if (state === 'zero_byte') {
      report.zeroByte.push(row);
      continue;
    }
    if (row.type === 'IMAGE' && !row.has_thumb && !vipsOk(row.originalPath)) {
      report.badImage.push(row);
    }
    if (row.type === 'VIDEO') {
      if (!row.has_video_meta) {
        if (ffprobeOk(row.originalPath)) report.fixableVideo.push(row);
        else report.badVideo.push(row);
      } else if (!row.has_thumb) {
        report.readyForThumbnails.push(row);
      }
    }
  }

  for (const row of trashed) {
    const state = fileState(row.originalPath);
    const broken =
      state === 'missing' ||
      state === 'zero_byte' ||
      (row.type === 'IMAGE' && !vipsOk(row.originalPath)) ||
      (row.type === 'VIDEO' && !ffprobeOk(row.originalPath));
    if (broken) report.trashedBroken.push(row);
    else report.trashedGood.push(row);
  }

  return report;
}

function summarize(report) {
  return {
    activeTimeline: report.activeTimeline,
    missingFile: report.missingFile.length,
    zeroByte: report.zeroByte.length,
    badImage: report.badImage.length,
    badVideo: report.badVideo.length,
    fixableVideo: report.fixableVideo.length,
    readyForThumbnails: report.readyForThumbnails.length,
    trashedGood: report.trashedGood.length,
    trashedBroken: report.trashedBroken.length,
  };
}

function printSummary(summary, json) {
  if (json) {
    console.log(JSON.stringify({ summary }, null, 2));
    return;
  }
  process.stdout.write('Immich library scan\n');
  process.stdout.write('-------------------\n');
  for (const [key, value] of Object.entries(summary)) {
    process.stdout.write(`  ${key}: ${value}\n`);
  }
}

async function deleteAssets(pg, rows, label) {
  if (!rows.length) return 0;
  const ids = rows.map((r) => r.id);
  const paths = await queryAssets(pg, 'SELECT id, "originalPath" FROM asset WHERE id = ANY($1::uuid[])', [ids]);
  for (const row of paths) {
    try {
      if (fs.existsSync(row.originalPath)) fs.unlinkSync(row.originalPath);
    } catch (err) {
      process.stdout.write(`warn: could not delete file for ${row.id}: ${err.message}\n`);
    }
  }
  const del = await pg.query('DELETE FROM asset WHERE id = ANY($1::uuid[]) RETURNING id', [ids]);
  process.stdout.write(`deleted ${del.rowCount} ${label} asset(s)\n`);
  return del.rowCount;
}

async function restoreTrashed(pg, rows) {
  if (!rows.length) return 0;
  const ids = rows.map((r) => r.id);
  const res = await pg.query(
    `UPDATE asset SET status = 'active', "deletedAt" = NULL
     WHERE id = ANY($1::uuid[]) RETURNING id`,
    [ids],
  );
  process.stdout.write(`restored ${res.rowCount} trashed asset(s) to the library\n`);
  return res.rowCount;
}

async function queueJobs(queueName, jobName, ids) {
  if (!ids.length) return 0;
  const queue = new Queue(queueName, { connection: REDIS, prefix: BULL_PREFIX });
  const batch = 500;
  for (let i = 0; i < ids.length; i += batch) {
    const chunk = ids.slice(i, i + batch);
    await queue.addBulk(chunk.map((id) => ({ name: jobName, data: { id } })));
  }
  await queue.close();
  process.stdout.write(`queued ${ids.length} ${jobName} job(s) on ${queueName}\n`);
  return ids.length;
}

async function videosNeedingThumbnails(pg) {
  return queryAssets(
    pg,
    `SELECT id FROM asset a
     WHERE a.status = 'active' AND a."deletedAt" IS NULL AND a.visibility = 'timeline'
       AND a.type = 'VIDEO' AND a.thumbhash IS NULL
       AND EXISTS (SELECT 1 FROM asset_video av WHERE av."assetId" = a.id)`,
  );
}

async function countVideosNeedingMetadata(pg) {
  const res = await pg.query(
    `SELECT COUNT(*)::int AS n FROM asset a
     WHERE a.status = 'active' AND a."deletedAt" IS NULL AND a.visibility = 'timeline'
       AND a.type = 'VIDEO'
       AND NOT EXISTS (SELECT 1 FROM asset_video av WHERE av."assetId" = a.id)`,
  );
  return res.rows[0].n;
}

async function waitForMetadata(pg, intervalMs = 30000) {
  while (true) {
    const remaining = await countVideosNeedingMetadata(pg);
    process.stdout.write(`metadata extraction: ${remaining} video(s) still missing metadata\n`);
    if (remaining === 0) break;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}

async function queueAllThumbnails(pg) {
  const rows = await videosNeedingThumbnails(pg);
  const ids = rows.map((r) => r.id);
  if (!ids.length) {
    process.stdout.write('no timeline videos need thumbnails\n');
    return 0;
  }
  return queueJobs('thumbnailGeneration', JOB_GENERATE_THUMBNAILS, ids);
}

async function runFix(pg, report, opts) {
  let deleted = 0;
  let metadataQueued = 0;
  let thumbnailsQueued = 0;

  if (opts.thumbnailsOnly) {
    thumbnailsQueued = await queueAllThumbnails(pg);
    return { deleted, metadataQueued, thumbnailsQueued };
  }

  if (opts.restoreTrashedGood && report.trashedGood.length) {
    await restoreTrashed(pg, report.trashedGood);
  }
  if (opts.emptyTrashedBroken && report.trashedBroken.length) {
    deleted += await deleteAssets(pg, report.trashedBroken, 'broken trashed');
  }

  const toDelete = [
    ...report.missingFile,
    ...report.zeroByte,
    ...report.badImage,
    ...report.badVideo,
  ];
  deleted += await deleteAssets(pg, toDelete, 'broken active');

  const fixableIds = report.fixableVideo.map((r) => r.id);
  if (fixableIds.length) {
    metadataQueued = await queueJobs('metadataExtraction', JOB_EXTRACT_METADATA, fixableIds);
  }

  if (opts.waitMetadata && fixableIds.length) {
    await waitForMetadata(pg);
  }

  if (opts.waitMetadata || !fixableIds.length) {
    thumbnailsQueued = await queueAllThumbnails(pg);
  }

  return { deleted, metadataQueued, thumbnailsQueued };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const pg = new Client({
    host: process.env.DB_HOSTNAME || 'database',
    port: Number(process.env.DB_PORT || 5432),
    user: process.env.DB_USERNAME || 'postgres',
    password: process.env.DB_PASSWORD,
    database: process.env.DB_DATABASE_NAME || 'immich',
  });
  await pg.connect();

  try {
    const report = await scan(pg);
    const summary = summarize(report);

    if (opts.command === 'scan') {
      if (opts.json) {
        console.log(JSON.stringify({ summary, report }, null, 2));
      } else {
        printSummary(summary, false);
      }
      return;
    }

    if (opts.command === 'thumbnails') {
      if (!opts.apply) {
        printSummary(summary, false);
        process.stdout.write('\nDry run. Re-run with: thumbnails --apply\n');
        return;
      }
      await queueAllThumbnails(pg);
      return;
    }

    if (opts.command !== 'fix') {
      throw new Error(`Unknown command: ${opts.command} (use scan, fix, or thumbnails)`);
    }

    printSummary(summary, false);

    if (!opts.apply) {
      process.stdout.write('\nDry run — no changes made. Re-run with: fix --apply\n');
      return;
    }

    process.stdout.write('\nApplying fixes...\n');
    const result = await runFix(pg, report, opts);
    process.stdout.write('\nDone.\n');
    process.stdout.write(`  deleted: ${result.deleted}\n`);
    process.stdout.write(`  metadata jobs queued: ${result.metadataQueued}\n`);
    process.stdout.write(`  thumbnail jobs queued: ${result.thumbnailsQueued}\n`);
    if (result.metadataQueued && !opts.waitMetadata) {
      process.stdout.write('\nMetadata jobs are still running. When finished, queue thumbnails:\n');
      process.stdout.write('  ./fix-library/fix-library.sh thumbnails --apply\n');
    }
  } finally {
    await pg.end();
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = { scan, summarize, parseArgs };
