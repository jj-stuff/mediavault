// Optimized Media Server with Enhanced Features
import express from 'express';
import { promises as fs } from 'fs';
import path from 'path';
import cors from 'cors';
import ffmpeg from 'fluent-ffmpeg';
import { fileURLToPath } from 'url';
import { dirname } from 'path';
import pLimit from 'p-limit';
import { Worker } from 'worker_threads';
import crypto from 'crypto';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3000;
const limit = pLimit(3);

const MEDIA_DIR = process.argv[2] || process.env.MEDIA_DIR || '/Users/heathcliff/Documents/xmedia';
const CACHE_DIR = path.join(MEDIA_DIR, 'media_cache');
const THUMBNAILS_DIR = path.join(CACHE_DIR, 'thumbnails');
const SCAN_CACHE_PATH = path.join(CACHE_DIR, 'scan_cache.json');
const DELETION_LIST_PATH = path.join(CACHE_DIR, 'deletion_list.txt');

let mediaCache = null;
let cacheETag = null;

const MEDIA_EXTENSIONS = new Set(['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.mp4', '.avi', '.mov', '.wmv', '.flv', '.webm', '.mp3', '.wav', '.ogg', '.m4a']);

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Static file serving with cache headers
app.use(
  '/media',
  express.static(MEDIA_DIR, {
    maxAge: '1d',
    etag: true,
    lastModified: true,
    setHeaders: (res, filePath) => {
      const ext = path.extname(filePath).toLowerCase();
      if (['.jpg', '.jpeg', '.png', '.gif', '.webp'].includes(ext)) {
        res.setHeader('Cache-Control', 'public, max-age=86400'); // 1 day
      } else if (['.mp4', '.mov', '.avi', '.webm'].includes(ext)) {
        res.setHeader('Cache-Control', 'public, max-age=3600'); // 1 hour
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

// Utility functions
const isMediaFile = (filename) => {
  const ext = path.extname(filename).toLowerCase();
  return MEDIA_EXTENSIONS.has(ext) && !filename.startsWith('._') && !filename.startsWith('.');
};

async function ensureCacheDirectories() {
  await fs.mkdir(CACHE_DIR, { recursive: true });
  await fs.mkdir(THUMBNAILS_DIR, { recursive: true });
}

// Initialize cache directories
ensureCacheDirectories().catch(console.error);

// Optimized thumbnail generation with better error handling
async function generateThumbnail(videoPath, outputPath) {
  // Check if thumbnail already exists
  try {
    await fs.access(outputPath);
    return outputPath; // Already exists
  } catch {
    // Continue to generate
  }

  return limit(
    () =>
      new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          reject(new Error('Thumbnail generation timeout'));
        }, 30000); // 30 second timeout

        ffmpeg(videoPath)
          .on('end', () => {
            clearTimeout(timeout);
            resolve(outputPath);
          })
          .on('error', (err) => {
            clearTimeout(timeout);
            console.error(`Thumbnail error for ${videoPath}:`, err.message);
            reject(err);
          })
          .screenshots({
            timestamps: ['10%'],
            filename: path.basename(outputPath),
            folder: path.dirname(outputPath),
            size: '320x?', // Keep aspect ratio
          });
      })
  );
}

// Optimized media scanning with parallel processing
async function scanForMedia(dirPath, basePath = '', skipThumbnails = false) {
  const mediaFiles = [];

  try {
    const items = await fs.readdir(dirPath, { withFileTypes: true });

    // Process files in parallel batches
    const batchSize = 10;
    for (let i = 0; i < items.length; i += batchSize) {
      const batch = items.slice(i, i + batchSize);
      const batchResults = await Promise.all(
        batch.map(async (item) => {
          if (item.name === 'media_cache') return null;

          const fullPath = path.join(dirPath, item.name);
          const relativePath = path.join(basePath, item.name);

          if (item.isDirectory()) {
            return scanForMedia(fullPath, relativePath, skipThumbnails);
          } else if (item.isFile() && isMediaFile(item.name)) {
            try {
              const stats = await fs.stat(fullPath);
              const type = path.extname(item.name).slice(1).toLowerCase();

              const mediaItem = {
                name: item.name,
                path: relativePath,
                url: `/media/${encodeURIComponent(relativePath.replace(/\\/g, '/'))}`,
                fullPath: fullPath, // Include full system path for deletion
                size: stats.size,
                modified: stats.mtime,
                type,
              };

              // Generate thumbnail hash for videos
              if (!skipThumbnails && ['mp4', 'avi', 'mov', 'webm'].includes(type)) {
                const hash = crypto.createHash('md5').update(fullPath).digest('hex');
                const thumbnailName = `${hash}_thumb.jpg`;
                const thumbnailPath = path.join(THUMBNAILS_DIR, thumbnailName);
                mediaItem.thumbnail = `/thumbnails/${thumbnailName}`;

                // Queue thumbnail generation asynchronously
                generateThumbnail(fullPath, thumbnailPath).catch(() => {
                  // Silently fail, thumbnail will be generated on demand
                });
              }

              return mediaItem;
            } catch (err) {
              console.error(`Error processing file ${fullPath}:`, err.message);
              return null;
            }
          }
          return null;
        })
      );

      // Flatten results
      for (const result of batchResults) {
        if (Array.isArray(result)) {
          mediaFiles.push(...result);
        } else if (result) {
          mediaFiles.push(result);
        }
      }
    }
  } catch (err) {
    console.error(`Error scanning directory ${dirPath}:`, err.message);
  }

  return mediaFiles;
}

// Cache management with ETags
async function getCachedMedia(forceRefresh = false) {
  try {
    if (!forceRefresh && mediaCache && cacheETag) {
      return { data: mediaCache, etag: cacheETag };
    }

    // Try to load from disk cache
    if (!forceRefresh) {
      try {
        const cachedData = await fs.readFile(SCAN_CACHE_PATH, 'utf8');
        const cache = JSON.parse(cachedData);
        mediaCache = cache.data;
        cacheETag = cache.etag;
        return { data: mediaCache, etag: cacheETag };
      } catch {
        // Cache miss, continue to scan
      }
    }

    // Scan media directories
    const users = await getUsers();
    const newCache = {};

    // Scan users in parallel
    await Promise.all(
      users.map(async (user) => {
        const userPath = path.join(MEDIA_DIR, user);
        newCache[user] = await scanForMedia(userPath, user);
      })
    );

    mediaCache = newCache;
    cacheETag = crypto.randomBytes(16).toString('hex');

    // Save to disk cache
    await fs.writeFile(SCAN_CACHE_PATH, JSON.stringify({ data: mediaCache, etag: cacheETag, timestamp: Date.now() }), 'utf8');

    return { data: mediaCache, etag: cacheETag };
  } catch (err) {
    console.error('Cache error:', err);
    throw err;
  }
}

async function getUsers() {
  try {
    const items = await fs.readdir(MEDIA_DIR, { withFileTypes: true });
    return items
      .filter((i) => i.isDirectory() && i.name !== 'media_cache')
      .map((i) => i.name)
      .sort();
  } catch (err) {
    console.error('Error reading media dir:', err);
    return [];
  }
}

// Routes

app.get('/health', (req, res) => {
  res.json({
    status: 'OK',
    mediaDir: MEDIA_DIR,
    uptime: process.uptime(),
    memory: process.memoryUsage(),
  });
});

app.get('/api/users', async (req, res) => {
  try {
    const users = await getUsers();
    res.json({ success: true, users });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.get('/api/users/:username/media', async (req, res) => {
  try {
    const username = req.params.username;
    const { data, etag } = await getCachedMedia();

    // Check ETag
    if (req.headers['if-none-match'] === etag) {
      return res.status(304).end();
    }

    const userMedia = data[username];
    if (!userMedia) {
      return res.status(404).json({ success: false, error: 'User not found' });
    }

    res.setHeader('ETag', etag);
    res.json({ success: true, count: userMedia.length, media: userMedia });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

app.get('/api/users/:username', async (req, res) => {
  const { username } = req.params;
  const userPath = path.join(MEDIA_DIR, username);

  try {
    await fs.access(userPath);
    const { data } = await getCachedMedia();
    const mediaFiles = data[username] || [];
    const images = mediaFiles.filter((m) => ['jpg', 'jpeg', 'png', 'webp'].includes(m.type));
    const avatar = images.length > 0 ? images[0].url : null;
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
  } catch (error) {
    res.status(404).json({ success: false, error: 'User not found' });
  }
});

app.get('/api/feed/random', async (req, res) => {
  try {
    const { data } = await getCachedMedia();
    const limitNum = Math.min(parseInt(req.query.limit) || 30, 100); // Cap at 100
    const mediaType = req.query.type;

    let allMedia = [];
    for (const [username, mediaList] of Object.entries(data)) {
      for (const file of mediaList) {
        allMedia.push({ ...file, username, userUrl: `/api/users/${username}` });
      }
    }

    // Filter by type if specified
    if (mediaType === 'video') {
      allMedia = allMedia.filter((m) => ['mp4', 'avi', 'mov', 'webm'].includes(m.type));
    } else if (mediaType === 'image') {
      allMedia = allMedia.filter((m) => ['jpg', 'jpeg', 'png', 'gif', 'webp'].includes(m.type));
    }

    // Efficient random selection using Fisher-Yates shuffle
    const shuffled = [];
    const tempArray = [...allMedia];
    const iterations = Math.min(limitNum, tempArray.length);

    for (let i = 0; i < iterations; i++) {
      const randomIndex = Math.floor(Math.random() * tempArray.length);
      shuffled.push(tempArray[randomIndex]);
      tempArray.splice(randomIndex, 1);
    }

    res.json({ success: true, count: shuffled.length, media: shuffled });
  } catch (error) {
    console.error('Feed error:', error);
    res.status(500).json({ success: false, error: 'Failed to generate feed' });
  }
});

app.get('/api/summary', async (req, res) => {
  try {
    const { data } = await getCachedMedia();
    const summary = {};

    for (const [user, mediaList] of Object.entries(data)) {
      const types = {};
      let totalSize = 0;

      for (const file of mediaList) {
        totalSize += file.size;
        types[file.type] = (types[file.type] || 0) + 1;
      }

      summary[user] = {
        totalFiles: mediaList.length,
        totalSize,
        types,
      };
    }

    res.json({ success: true, summary });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Failed to generate summary' });
  }
});

// Enhanced deletion management
app.post('/api/deletion-list', async (req, res) => {
  try {
    const { paths } = req.body;

    if (!Array.isArray(paths)) {
      return res.status(400).json({ success: false, error: 'Paths must be an array' });
    }

    // Write full system paths for easy terminal usage
    const content = paths
      .map((p) => p.trim())
      .filter((p) => p.length > 0)
      .join('\n');

    await fs.writeFile(DELETION_LIST_PATH, content + '\n', 'utf8');

    res.json({
      success: true,
      count: paths.length,
      message: `Deletion list saved to: ${DELETION_LIST_PATH}`,
    });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

app.get('/api/deletion-list', async (req, res) => {
  try {
    const content = await fs.readFile(DELETION_LIST_PATH, 'utf8');
    const paths = content
      .split('\n')
      .map((p) => p.trim())
      .filter((p) => p.length > 0);

    res.json({
      success: true,
      paths,
      count: paths.length,
      location: DELETION_LIST_PATH,
    });
  } catch (error) {
    if (error.code === 'ENOENT') {
      res.json({ success: true, paths: [], count: 0 });
    } else {
      res.status(500).json({ success: false, error: error.message });
    }
  }
});

// Add item to deletion list
app.post('/api/deletion-list/add', async (req, res) => {
  try {
    const { path: itemPath } = req.body;

    if (!itemPath) {
      return res.status(400).json({ success: false, error: 'Path is required' });
    }

    // Read existing list
    let existingPaths = [];
    try {
      const content = await fs.readFile(DELETION_LIST_PATH, 'utf8');
      existingPaths = content.split('\n').filter((p) => p.trim().length > 0);
    } catch (err) {
      // File doesn't exist yet
    }

    // Add new path if not already present
    if (!existingPaths.includes(itemPath)) {
      existingPaths.push(itemPath);
      await fs.writeFile(DELETION_LIST_PATH, existingPaths.join('\n') + '\n', 'utf8');
    }

    res.json({ success: true, count: existingPaths.length });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// Remove item from deletion list
app.post('/api/deletion-list/remove', async (req, res) => {
  try {
    const { path: itemPath } = req.body;

    if (!itemPath) {
      return res.status(400).json({ success: false, error: 'Path is required' });
    }

    // Read existing list
    const content = await fs.readFile(DELETION_LIST_PATH, 'utf8');
    const paths = content.split('\n').filter((p) => p.trim().length > 0);

    // Remove the path
    const filteredPaths = paths.filter((p) => p !== itemPath);

    await fs.writeFile(DELETION_LIST_PATH, filteredPaths.join('\n') + '\n', 'utf8');

    res.json({ success: true, count: filteredPaths.length });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// Clear cache endpoint
app.post('/api/cache/clear', async (req, res) => {
  try {
    mediaCache = null;
    cacheETag = null;
    await fs.unlink(SCAN_CACHE_PATH).catch(() => {});
    res.json({ success: true, message: 'Cache cleared' });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// Force refresh endpoint
app.post('/api/cache/refresh', async (req, res) => {
  try {
    const { data, etag } = await getCachedMedia(true);
    res.json({
      success: true,
      message: 'Cache refreshed',
      userCount: Object.keys(data).length,
      etag,
    });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// Generate thumbnail on demand
app.get('/api/thumbnail/:username/:filename', async (req, res) => {
  const { username, filename } = req.params;
  const videoPath = path.join(MEDIA_DIR, username, decodeURIComponent(filename));
  const hash = crypto.createHash('md5').update(videoPath).digest('hex');
  const thumbnailName = `${hash}_thumb.jpg`;
  const thumbnailPath = path.join(THUMBNAILS_DIR, thumbnailName);

  try {
    // Check if thumbnail exists
    await fs.access(thumbnailPath);
    res.sendFile(thumbnailPath);
  } catch {
    // Generate thumbnail
    try {
      await generateThumbnail(videoPath, thumbnailPath);
      res.sendFile(thumbnailPath);
    } catch (error) {
      console.error('Thumbnail generation failed:', error);
      res.status(500).json({ success: false, error: 'Failed to generate thumbnail' });
    }
  }
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down gracefully');
  server.close(() => {
    console.log('Server closed');
  });
});

const server = app.listen(PORT, () => {
  console.log(`🚀 Media server running on port ${PORT}`);
  console.log(`📁 Serving media from: ${MEDIA_DIR}`);
  console.log(`💾 Cache directory: ${CACHE_DIR}`);
  console.log(`🗑️  Deletion list: ${DELETION_LIST_PATH}`);
});
