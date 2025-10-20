// Media browser server with caching, thumbnail generation, and deletion management.
import express from 'express';
import cors from 'cors';
import path from 'path';
import { promises as fs } from 'fs';
import os from 'os';
import ffmpeg from 'fluent-ffmpeg';
import pLimit from 'p-limit';
import { createHash, randomBytes } from 'crypto';
import ngrok from '@ngrok/ngrok';
import 'dotenv/config';

// Configuration options (env vars take precedence over CLI args, then defaults).
const PORT = Number.parseInt(process.env.PORT ?? '3000', 10);
const MEDIA_DIR = path.resolve(process.argv[2] ?? process.env.MEDIA_DIR ?? '/Users/heathcliff/Documents/xmedia');
const CACHE_DIR = path.resolve(process.env.MEDIA_CACHE_DIR ?? path.join(path.dirname(MEDIA_DIR), `${path.basename(MEDIA_DIR)}_cache`));
const THUMBNAILS_DIR = path.join(CACHE_DIR, 'thumbnails');
const SCAN_CACHE_PATH = path.join(CACHE_DIR, 'scan_cache.json');
const DELETION_LIST_PATH = path.join(CACHE_DIR, 'deletion_list.txt');
const ENABLE_NGROK = (process.env.ENABLE_NGROK ?? 'true').toLowerCase() === 'true';

const THUMBNAIL_TIMEOUT_MS = Number.parseInt(process.env.THUMBNAIL_TIMEOUT_MS ?? '30000', 10);
const THUMBNAIL_CONCURRENCY = Math.max(Number.parseInt(process.env.THUMBNAIL_CONCURRENCY ?? '3', 10), 1);
const DIRECTORY_BATCH_SIZE = Math.max(Number.parseInt(process.env.SCAN_BATCH_SIZE ?? '10', 10), 1);
const THUMBNAIL_SIZE = process.env.THUMBNAIL_SIZE ?? '320x?';

const CACHE_DIRECTORY_NAME = path.basename(CACHE_DIR);

const IMAGE_EXTENSIONS = new Set(['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp']);
const VIDEO_EXTENSIONS = new Set(['mp4', 'avi', 'mov', 'wmv', 'flv', 'webm']);
const AUDIO_EXTENSIONS = new Set(['mp3', 'wav', 'ogg', 'm4a']);
const MEDIA_EXTENSIONS = new Set([...IMAGE_EXTENSIONS, ...VIDEO_EXTENSIONS, ...AUDIO_EXTENSIONS]);

function sanitizeMediaCache(rawCache) {
  if (typeof rawCache !== 'object' || !rawCache) {
    return {};
  }

  return Object.entries(rawCache).reduce((acc, [user, entries]) => {
    if (Array.isArray(entries)) {
      acc[user] = entries.filter((item) => item && typeof item === 'object').map(({ fullPath, ...rest }) => rest);
    } else {
      acc[user] = [];
    }
    return acc;
  }, {});
}

function hasNgrokCredentials() {
  return Boolean((process.env.NGROK_AUTHTOKEN && process.env.NGROK_AUTHTOKEN.trim()) || (process.env.NGROK_AUTHTOKEN_FILE && process.env.NGROK_AUTHTOKEN_FILE.trim()) || (process.env.NGROK_CONFIG && process.env.NGROK_CONFIG.trim()));
}

const mediaCacheState = {
  data: null,
  etag: null,
  timestamp: 0,
};

const limit = pLimit(THUMBNAIL_CONCURRENCY);

const app = express();

app.disable('x-powered-by');
app.use(cors());
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true, limit: '1mb' }));

app.use(
  '/media',
  (req, res, next) => {
    const segments = req.path.split('/').filter(Boolean);
    const decodedSegments = [];

    for (const segment of segments) {
      try {
        decodedSegments.push(decodeURIComponent(segment));
      } catch {
        res.status(400).json({ success: false, error: 'Invalid path encoding' });
        return;
      }
    }

    try {
      const candidatePath = resolveMediaPath(...decodedSegments);
      const relativeToCache = path.relative(CACHE_DIR, candidatePath);
      if (candidatePath === CACHE_DIR || (!relativeToCache.startsWith('..') && !path.isAbsolute(relativeToCache))) {
        res.status(404).json({ success: false, error: 'Not found' });
        return;
      }
    } catch {
      res.status(404).json({ success: false, error: 'Not found' });
      return;
    }

    next();
  },
  express.static(MEDIA_DIR, {
    maxAge: '1d',
    etag: true,
    lastModified: true,
    setHeaders: (res, filePath) => {
      const ext = path.extname(filePath).slice(1).toLowerCase();
      if (IMAGE_EXTENSIONS.has(ext)) {
        res.setHeader('Cache-Control', 'public, max-age=86400');
      } else if (VIDEO_EXTENSIONS.has(ext)) {
        res.setHeader('Cache-Control', 'public, max-age=3600');
      }
    },
  })
);

app.use(
  '/thumbnails',
  express.static(THUMBNAILS_DIR, {
    maxAge: '7d',
    etag: true,
  })
);

const asyncHandler = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function logError(context, error) {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  console.error(`[${new Date().toISOString()}] ${context}: ${message}`);
}

async function ensureDirectories() {
  await fs.mkdir(MEDIA_DIR, { recursive: true });
  await fs.mkdir(CACHE_DIR, { recursive: true });
  await fs.mkdir(THUMBNAILS_DIR, { recursive: true });
}

/**
 * Guards against path traversal by ensuring resolved paths stay under MEDIA_DIR.
 */
function resolveMediaPath(...segments) {
  const resolvedPath = path.resolve(MEDIA_DIR, ...segments);
  if (resolvedPath === MEDIA_DIR) {
    return resolvedPath;
  }

  const relative = path.relative(MEDIA_DIR, resolvedPath);
  if (relative.startsWith('..') || path.isAbsolute(relative) || relative.split(path.sep).filter(Boolean)[0] === CACHE_DIRECTORY_NAME) {
    throw Object.assign(new Error('Resolved path escapes media directory'), { statusCode: 400 });
  }

  return resolvedPath;
}

function createEtag() {
  return randomBytes(16).toString('hex');
}

function encodeRelativePath(relativePath) {
  return relativePath.split(path.sep).map(encodeURIComponent).join('/');
}

function createThumbnailName(filepath) {
  return `${createHash('md5').update(filepath).digest('hex')}_thumb.jpg`;
}

/**
 * Generates a thumbnail for video files with bounded concurrency.
 */
async function generateThumbnail(videoPath, outputPath) {
  try {
    await fs.access(outputPath);
    return outputPath;
  } catch {
    // continue
  }

  return limit(
    () =>
      new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          reject(Object.assign(new Error('Thumbnail generation timeout'), { statusCode: 504 }));
        }, THUMBNAIL_TIMEOUT_MS);

        ffmpeg(videoPath)
          .screenshots({
            timestamps: ['10%'],
            filename: path.basename(outputPath),
            folder: path.dirname(outputPath),
            size: THUMBNAIL_SIZE,
          })
          .on('end', () => {
            clearTimeout(timeout);
            resolve(outputPath);
          })
          .on('error', (err) => {
            clearTimeout(timeout);
            reject(err);
          });
      })
  );
}

/**
 * Recursively scans the provided directory for supported media files.
 */
async function scanForMedia(dirPath, basePath = '', skipThumbnails = false) {
  const collected = [];
  let directoryEntries = [];

  try {
    directoryEntries = await fs.readdir(dirPath, { withFileTypes: true });
  } catch (error) {
    if (error.code === 'ENOENT') {
      return collected;
    }
    throw error;
  }

  for (let index = 0; index < directoryEntries.length; index += DIRECTORY_BATCH_SIZE) {
    const batch = directoryEntries.slice(index, index + DIRECTORY_BATCH_SIZE);

    const batchResults = await Promise.all(
      batch.map(async (entry) => {
        if (entry.name === CACHE_DIRECTORY_NAME) {
          return [];
        }

        const fullPath = path.join(dirPath, entry.name);
        const nextBasePath = basePath ? `${basePath}/${entry.name}` : entry.name;

        if (entry.isDirectory()) {
          return scanForMedia(fullPath, nextBasePath, skipThumbnails);
        }

        if (entry.isFile()) {
          const extension = path.extname(entry.name).slice(1).toLowerCase();

          if (!MEDIA_EXTENSIONS.has(extension)) {
            return [];
          }

          const stats = await fs.stat(fullPath);
          const urlPath = encodeRelativePath(nextBasePath);
          const mediaItem = {
            name: entry.name,
            path: nextBasePath,
            url: `/media/${urlPath}`,
            size: stats.size,
            modified: stats.mtime,
            type: extension,
          };

          if (!skipThumbnails && VIDEO_EXTENSIONS.has(extension)) {
            const thumbnailName = createThumbnailName(fullPath);
            mediaItem.thumbnail = `/thumbnails/${thumbnailName}`;

            generateThumbnail(fullPath, path.join(THUMBNAILS_DIR, thumbnailName)).catch((error) => {
              logError(`Thumbnail generation failed for ${fullPath}`, error);
            });
          }

          return [mediaItem];
        }

        return [];
      })
    );

    batchResults.forEach((results) => {
      collected.push(...results);
    });
  }

  return collected;
}

async function readDiskCache() {
  try {
    const raw = await fs.readFile(SCAN_CACHE_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object') {
      parsed.data = sanitizeMediaCache(parsed.data);
    }
    return parsed;
  } catch (error) {
    if (error.code !== 'ENOENT') {
      logError('Failed to read scan cache', error);
    }
    return null;
  }
}

async function persistCache(data, etag) {
  const payload = {
    data,
    etag,
    timestamp: Date.now(),
  };

  await fs.writeFile(SCAN_CACHE_PATH, JSON.stringify(payload), 'utf8');
}

/**
 * Returns media data from memory, disk cache, or triggers a fresh scan as needed.
 */
async function getCachedMedia(forceRefresh = false) {
  if (!forceRefresh && mediaCacheState.data && mediaCacheState.etag) {
    return { data: mediaCacheState.data, etag: mediaCacheState.etag };
  }

  if (!forceRefresh) {
    const cached = await readDiskCache();
    if (cached?.data) {
      mediaCacheState.data = cached.data;
      mediaCacheState.etag = cached.etag ?? createEtag();
      mediaCacheState.timestamp = cached.timestamp ?? Date.now();
      return { data: mediaCacheState.data, etag: mediaCacheState.etag };
    }
  }

  const users = await getUsers();
  const freshCache = {};

  await Promise.all(
    users.map(async (user) => {
      const userPath = resolveMediaPath(user);
      freshCache[user] = await scanForMedia(userPath, user);
    })
  );

  const etag = createEtag();
  const sanitizedCache = sanitizeMediaCache(freshCache);
  mediaCacheState.data = sanitizedCache;
  mediaCacheState.etag = etag;
  mediaCacheState.timestamp = Date.now();

  await persistCache(sanitizedCache, etag);

  return { data: sanitizedCache, etag };
}

async function getUsers() {
  let entries = [];

  try {
    entries = await fs.readdir(MEDIA_DIR, { withFileTypes: true });
  } catch (error) {
    if (error.code === 'ENOENT') {
      return [];
    }
    throw error;
  }

  return entries
    .filter((entry) => entry.isDirectory() && entry.name !== CACHE_DIRECTORY_NAME)
    .map((entry) => entry.name)
    .sort((a, b) => a.localeCompare(b));
}

async function readDeletionList() {
  try {
    const raw = await fs.readFile(DELETION_LIST_PATH, 'utf8');
    return raw
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean);
  } catch (error) {
    if (error.code === 'ENOENT') {
      return [];
    }
    throw error;
  }
}

async function writeDeletionList(paths) {
  const unique = [...new Set(paths.map((p) => p.trim()).filter(Boolean))];
  const payload = unique.length > 0 ? `${unique.join('\n')}\n` : '';
  await fs.writeFile(DELETION_LIST_PATH, payload, 'utf8');
  return unique;
}

function sampleItems(items, count) {
  const copy = [...items];
  const sampleCount = Math.min(count, copy.length);

  for (let index = copy.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(Math.random() * (index + 1));
    [copy[index], copy[swapIndex]] = [copy[swapIndex], copy[index]];
  }

  return copy.slice(0, sampleCount);
}

function validateUsername(username) {
  if (typeof username !== 'string' || !username.trim()) {
    throw Object.assign(new Error('Username is required'), { statusCode: 400 });
  }

  if (/[\\/]/.test(username)) {
    throw Object.assign(new Error('Username contains invalid characters'), { statusCode: 400 });
  }

  return username.trim();
}

function validateFilename(filename) {
  if (typeof filename !== 'string' || !filename.trim()) {
    throw Object.assign(new Error('Filename is required'), { statusCode: 400 });
  }

  if (/[\\/]/.test(filename)) {
    throw Object.assign(new Error('Filename contains invalid characters'), { statusCode: 400 });
  }

  return filename.trim();
}

function decodeSafe(value, label) {
  try {
    return decodeURIComponent(value);
  } catch {
    throw Object.assign(new Error(`Invalid ${label} encoding`), { statusCode: 400 });
  }
}

// Routes
app.get(
  '/health',
  asyncHandler(async (req, res) => {
    res.json({
      status: 'OK',
      mediaRoot: path.basename(MEDIA_DIR),
      cacheReady: Boolean(mediaCacheState.etag),
      cacheTimestamp: mediaCacheState.timestamp || null,
      uptime: process.uptime(),
      memory: process.memoryUsage(),
    });
  })
);

app.get(
  '/api/users',
  asyncHandler(async (req, res) => {
    const users = await getUsers();
    res.json({ success: true, users });
  })
);

app.get(
  '/api/users/:username/media',
  asyncHandler(async (req, res) => {
    const username = validateUsername(req.params.username);
    const { data, etag } = await getCachedMedia();

    if (req.headers['if-none-match'] === etag) {
      res.status(304).end();
      return;
    }

    const media = data[username];
    if (!media) {
      res.status(404).json({ success: false, error: 'User not found' });
      return;
    }

    res.setHeader('ETag', etag);
    res.json({ success: true, count: media.length, media });
  })
);

app.get(
  '/api/users/:username',
  asyncHandler(async (req, res) => {
    const username = validateUsername(req.params.username);
    const userPath = resolveMediaPath(username);

    try {
      await fs.access(userPath);
    } catch (error) {
      if (error.code === 'ENOENT') {
        res.status(404).json({ success: false, error: 'User not found' });
        return;
      }
      throw error;
    }

    const { data } = await getCachedMedia();
    const mediaFiles = data[username] ?? [];
    const avatar = mediaFiles.find((item) => IMAGE_EXTENSIONS.has(item.type))?.url ?? null;
    const stats = await fs.stat(userPath);

    res.json({
      success: true,
      user: {
        username,
        avatar,
        mediaCount: mediaFiles.length,
        joinDate: stats.birthtime,
      },
    });
  })
);

app.get(
  '/api/feed/random',
  asyncHandler(async (req, res) => {
    const { data } = await getCachedMedia();
    const requestedLimit = Number.parseInt(req.query.limit ?? '30', 10);
    const limitValue = Number.isFinite(requestedLimit) ? Math.min(Math.max(requestedLimit, 1), 100) : 30;
    const mediaType = typeof req.query.type === 'string' ? req.query.type : undefined;

    let aggregated = [];

    for (const [username, mediaList] of Object.entries(data)) {
      aggregated.push(
        ...mediaList.map((file) => ({
          ...file,
          username,
          userUrl: `/api/users/${encodeURIComponent(username)}`,
        }))
      );
    }

    if (mediaType === 'video') {
      aggregated = aggregated.filter((item) => VIDEO_EXTENSIONS.has(item.type));
    } else if (mediaType === 'image') {
      aggregated = aggregated.filter((item) => IMAGE_EXTENSIONS.has(item.type));
    }

    const sampled = sampleItems(aggregated, limitValue);
    res.json({ success: true, count: sampled.length, media: sampled });
  })
);

app.get(
  '/api/summary',
  asyncHandler(async (req, res) => {
    const { data } = await getCachedMedia();
    const summary = {};

    Object.entries(data).forEach(([user, mediaList]) => {
      const types = {};
      let totalSize = 0;

      mediaList.forEach((file) => {
        totalSize += file.size;
        types[file.type] = (types[file.type] ?? 0) + 1;
      });

      summary[user] = {
        totalFiles: mediaList.length,
        totalSize,
        types,
      };
    });

    res.json({ success: true, summary });
  })
);

app.post(
  '/api/deletion-list',
  asyncHandler(async (req, res) => {
    const { paths } = req.body;

    if (!Array.isArray(paths)) {
      res.status(400).json({ success: false, error: 'Paths must be an array' });
      return;
    }

    const stored = await writeDeletionList(paths.map(String));
    res.json({
      success: true,
      count: stored.length,
      message: 'Deletion list saved',
    });
  })
);

app.get(
  '/api/deletion-list',
  asyncHandler(async (req, res) => {
    const paths = await readDeletionList();
    res.json({
      success: true,
      paths,
      count: paths.length,
    });
  })
);

app.post(
  '/api/deletion-list/add',
  asyncHandler(async (req, res) => {
    const rawPath = typeof req.body.path === 'string' ? req.body.path.trim() : '';
    if (!rawPath) {
      res.status(400).json({ success: false, error: 'Path is required' });
      return;
    }

    const existing = await readDeletionList();
    if (!existing.includes(rawPath)) {
      existing.push(rawPath);
    }

    const stored = await writeDeletionList(existing);
    res.json({ success: true, count: stored.length });
  })
);

app.post(
  '/api/deletion-list/remove',
  asyncHandler(async (req, res) => {
    const rawPath = typeof req.body.path === 'string' ? req.body.path.trim() : '';
    if (!rawPath) {
      res.status(400).json({ success: false, error: 'Path is required' });
      return;
    }

    const existing = await readDeletionList();
    const filtered = existing.filter((entry) => entry !== rawPath);
    const stored = await writeDeletionList(filtered);
    res.json({ success: true, count: stored.length });
  })
);

app.post(
  '/api/cache/clear',
  asyncHandler(async (req, res) => {
    mediaCacheState.data = null;
    mediaCacheState.etag = null;
    mediaCacheState.timestamp = 0;

    await fs.unlink(SCAN_CACHE_PATH).catch((error) => {
      if (error.code !== 'ENOENT') {
        throw error;
      }
    });

    res.json({ success: true, message: 'Cache cleared' });
  })
);

app.post(
  '/api/cache/refresh',
  asyncHandler(async (req, res) => {
    const { data, etag } = await getCachedMedia(true);
    res.json({
      success: true,
      message: 'Cache refreshed',
      userCount: Object.keys(data).length,
      etag,
    });
  })
);

app.get(
  '/api/thumbnail/:username/:filename',
  asyncHandler(async (req, res, next) => {
    const username = validateUsername(req.params.username);
    const filename = validateFilename(decodeSafe(req.params.filename, 'filename'));
    const videoPath = resolveMediaPath(username, filename);
    const extension = path.extname(filename).slice(1).toLowerCase();

    if (!VIDEO_EXTENSIONS.has(extension)) {
      res.status(400).json({ success: false, error: 'Thumbnails are only available for video files' });
      return;
    }

    const thumbnailName = createThumbnailName(videoPath);
    const thumbnailPath = path.join(THUMBNAILS_DIR, thumbnailName);

    try {
      await fs.access(thumbnailPath);
    } catch {
      await generateThumbnail(videoPath, thumbnailPath);
    }

    res.type('jpg');
    res.sendFile(thumbnailPath, (error) => {
      if (error) {
        next(error);
      }
    });
  })
);

app.use((req, res) => {
  res.status(404).json({ success: false, error: 'Not found' });
});

app.use((err, req, res, next) => {
  logError('Unhandled request error', err);
  const statusCode = err.statusCode ?? err.status ?? 500;
  const message = statusCode >= 500 ? 'Internal server error' : err.message;
  res.status(statusCode).json({ success: false, error: message });
});

let server;
let ngrokListener;

async function startNgrokTunnel() {
  const options = {
    addr: PORT,
    authtoken_from_env: true,
  };

  if (process.env.NGROK_EDGE) {
    options.edge = process.env.NGROK_EDGE;
  }

  if (process.env.NGROK_DOMAIN) {
    options.domain = process.env.NGROK_DOMAIN;
  }

  if (process.env.NGROK_REGION) {
    options.region = process.env.NGROK_REGION;
  }

  const listener = await ngrok.connect(options);
  console.log(`🌍 ngrok tunnel: ${listener.url()}`);
  return listener;
}

function getLocalIPv4Addresses() {
  const interfaces = os.networkInterfaces();
  const addresses = [];

  for (const key of Object.keys(interfaces)) {
    const entries = interfaces[key] ?? [];
    for (const entry of entries) {
      if (entry && entry.family === 'IPv4' && !entry.internal) {
        addresses.push(entry.address);
      }
    }
  }

  return Array.from(new Set(addresses));
}

async function bootstrap() {
  try {
    await ensureDirectories();
    const { data, etag } = await getCachedMedia();
    if (data && etag) {
      console.log('Media cache warmed from disk');
    }
  } catch (error) {
    logError('Bootstrap failure (continuing without cache)', error);
  }

  server = app.listen(PORT, () => {
    console.log(`🚀 Media server running on port ${PORT}`);
    const ips = getLocalIPv4Addresses();
    if (ips.length > 0) {
      console.log('🔗 Accessible on your network:');
      ips.forEach((ip) => {
        console.log(`   → http://${ip}:${PORT}`);
      });
    } else {
      console.log(`🔗 Accessible at http://localhost:${PORT}`);
    }
    if (ENABLE_NGROK) {
      if (hasNgrokCredentials()) {
        (async () => {
          try {
            ngrokListener = await startNgrokTunnel();
          } catch (error) {
            logError('Failed to start ngrok tunnel', error);
          }
        })();
      } else {
        console.log('⚠️  Skipping ngrok tunnel: set NGROK_AUTHTOKEN to enable ngrok');
      }
    }
    console.log(`📁 Serving media from: ${MEDIA_DIR}`);
    console.log(`💾 Cache directory: ${CACHE_DIR}`);
    console.log(`🗑️  Deletion list: ${DELETION_LIST_PATH}`);
  });
}

bootstrap().catch((error) => {
  logError('Fatal startup error', error);
  process.exit(1);
});

function gracefulShutdown(signal) {
  console.log(`${signal} received, shutting down gracefully`);

  const shutdownTasks = [];

  if (server) {
    shutdownTasks.push(
      new Promise((resolve) => {
        server.close((error) => {
          if (error) {
            logError('Error closing HTTP server', error);
          } else {
            console.log('HTTP server closed');
          }
          resolve();
        });
      })
    );
  }

  if (ngrokListener) {
    shutdownTasks.push(
      ngrokListener
        .close()
        .then(() => {
          console.log('ngrok tunnel closed');
        })
        .catch((error) => {
          logError('Failed to close ngrok tunnel', error);
        })
        .finally(() => {
          ngrokListener = null;
        })
    );
  }

  const forcedExit = setTimeout(() => {
    console.warn('Forced shutdown after timeout');
    process.exit(1);
  }, 5000);
  forcedExit.unref();

  const waitForCleanup = shutdownTasks.length > 0 ? Promise.allSettled(shutdownTasks) : Promise.resolve();

  waitForCleanup.finally(() => {
    clearTimeout(forcedExit);
    process.exit(0);
  });
}

process.on('SIGTERM', gracefulShutdown.bind(null, 'SIGTERM'));
process.on('SIGINT', gracefulShutdown.bind(null, 'SIGINT'));

process.on('unhandledRejection', (reason) => {
  logError('Unhandled promise rejection', reason);
});

process.on('uncaughtException', (error) => {
  logError('Uncaught exception', error);
  process.exit(1);
});
